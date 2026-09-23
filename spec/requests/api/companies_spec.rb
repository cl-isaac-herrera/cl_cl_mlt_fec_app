# frozen_string_literal: true

require 'rails_helper'

# Listado de administración de compañías (/configurations/companies). No confundir
# con `GET /api/profile/companies`, que son las del usuario de la sesión.
RSpec.describe 'GET /api/companies', type: :request do
  let(:user)  { User.create!(email: 'admin@example.com') }
  let(:role)  { Role.create!(name: 'Configurador') }
  let(:sap)   { Connection.create!(name: 'SAP Producción', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme)  { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME') }

  # El bloque del emisor (`EmsrNombre`, `EmsrIdeTipo`, `CodigoActividad`,
  # `EmsrRegistroFiscal8707`) vive en la UDT `@CL_FEC_ISSUERCONFIG`
  # (`Sap::CompanyConfig`), así que `show` y `create` hablan con SAP. Se stubea
  # acá, a nivel de archivo, porque toca a casi todos los ejemplos de `show` y
  # de `POST /api/companies` — cada ejemplo que necesite un valor puntual del
  # emisor sobreescribe `sap_client` con su propio `allow(...).to receive(:get)`.
  let(:sap_client) { instance_double(Clavisco::ServiceLayer::Client) }

  before do
    allow(Sap::CompanyClient).to receive(:for).and_return(sap_client)
    allow(Sap::UserClient).to receive(:for).and_return(sap_client)
    allow(sap_client).to receive(:get).and_return(nil)
    allow(sap_client).to receive(:post)
  end

  # Deja al usuario con los permisos indicados sobre `acme` y abre la sesión con
  # esa compañía activa: require_permission! resuelve contra la de la sesión.
  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  it 'exige Configurations_Companies_ListAccess' do
    sign_in_with

    get '/api/companies'

    expect(response).to have_http_status(:forbidden)
  end

  it 'responde 401 sin sesión' do
    get '/api/companies'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'respeta el contrato ApiResponse' do
    sign_in_with('Configurations_Companies_ListAccess')

    get '/api/companies'

    expect(response).to have_http_status(:ok)
    expect(body.keys).to include('Data', 'Code', 'Message')
    expect(body['Code']).to eq(200)
  end

  # Solo lo que pinta la tabla: nombre, cédula, estado y el id para las acciones.
  # El nombre legal y el comercial no salen de acá.
  it 'expone únicamente el id, el nombre, la cédula y el estado' do
    acme.update!(issuer_id_number: '3101822733')
    sign_in_with('Configurations_Companies_ListAccess')

    get '/api/companies'

    expect(body_data['Items'].first).to eq(
      'Id' => acme.id, 'Name' => 'ACME S.A.', 'Active' => true,
      'EmsrIdeNumero' => '3101822733'
    )
  end

  describe 'alcance' do
    it 'devuelve solo las compañías asignadas al usuario' do
      Company.create!(name: 'Ajena S.A.')   # existe pero no está asignada
      sign_in_with('Configurations_Companies_ListAccess')

      get '/api/companies'

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.'])
    end

    it 'devuelve todas con Configurations_Companies_ViewAllApplicationCompanies' do
      Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_ListAccess',
                   'Configurations_Companies_ViewAllApplicationCompanies')

      get '/api/companies'

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.', 'Ajena S.A.'])
    end

    # Es una pantalla de administración: tiene que poder ver las dadas de baja
    # para reactivarlas (CLAUDE.md §28).
    it 'incluye las compañías inactivas' do
      inactiva = Company.create!(name: 'Cerrada S.A.')
      UsersByCompany.create!(user: user, company: inactiva)
      inactiva.soft_delete!
      sign_in_with('Configurations_Companies_ListAccess')

      get '/api/companies'

      expect(body_data['Items'].map { |c| c.values_at('Name', 'Active') })
        .to contain_exactly(['ACME S.A.', true], ['Cerrada S.A.', false])
    end
  end

  describe 'paginación' do
    before do
      %w[Alfa Beta Gamma].each do |n|
        UsersByCompany.create!(user: user, company: Company.create!(name: n))
      end
      sign_in_with('Configurations_Companies_ListAccess')
    end

    it 'devuelve el total real de la consulta, no el de la página' do
      get '/api/companies', params: { page: 1, per_page: 2 }

      expect(body_data['Items'].size).to eq(2)
      # Lo que el contador de Tabulator necesita para no sobreestimar (§17).
      expect(body_data['Total']).to eq(4)
    end

    it 'devuelve la segunda página, no la primera otra vez' do
      get '/api/companies', params: { page: 2, per_page: 2 }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['Beta', 'Gamma'])
    end

    it 'cae a la primera página con un número inválido' do
      get '/api/companies', params: { page: 0, per_page: 2 }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.', 'Alfa'])
    end

    it 'topa el tamaño de página para que nadie pida la tabla entera' do
      get '/api/companies', params: { per_page: 10_000 }

      expect(body_data['Items'].size).to eq(4)
    end
  end

  describe 'GET /api/companies/:id' do
    # Lo que sigue en `companies`. El resto del bloque del emisor (razón
    # social, tipo de identificación, actividad económica, registro fiscal
    # 8707) sale de SAP — ver `sap_row` más abajo.
    let(:issuer_attrs) do
      {
        issuer_id_number: '3101822733',
        email_cc: 'uno@acme.cr;dos@acme.cr', purchase_invoice_series: 42,
        default_xml_tax_code: 'IVA13', default_warehouse: 'PRIN'
      }
    end

    # Una fila como la devuelve el Service Layer para la UDT
    # `@CL_FEC_ISSUERCONFIG`.
    def sap_row(legal_name: 'ACME Sociedad Anónima', id_type: '02', economic_activity_code: '7020',
                tax_registry_8707: '12345')
      {
        'Code' => '1', 'U_LegalName' => legal_name, 'U_IdType' => id_type,
        'U_EconomicActivityCode' => economic_activity_code, 'U_TaxRegistry8707' => tax_registry_8707,
        'U_UpdatedAt' => nil, 'U_UpdatedBy' => nil
      }
    end

    it 'exige Configurations_Companies_Update, no solo el de la lista' do
      sign_in_with('Configurations_Companies_ListAccess')

      get "/api/companies/#{acme.id}"

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 401 sin sesión' do
      get "/api/companies/#{acme.id}"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'devuelve las columnas de la compañía' do
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}"

      expect(response).to have_http_status(:ok)
      expect(body_data).to include(
        'Id' => acme.id, 'Name' => 'ACME S.A.', 'Active' => true,
        'ConnectionId' => sap.id, 'SapDb' => 'SBO_ACME',
        # Los dos nacen en 1, que es la primera opción de su `<select>`.
        'FreightType' => 1, 'EmailSenderType' => 1
      )
    end

    # Las claves conservan el vocabulario del XML de Hacienda aunque las columnas
    # se llamen en inglés: la traducción la hace `serialize_detail`.
    it 'expone el bloque del emisor con las claves de Hacienda' do
      acme.update!(issuer_attrs)
      allow(sap_client).to receive(:get).and_return(sap_row)
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}"

      expect(body_data).to include(
        'EmsrNombre' => 'ACME Sociedad Anónima',
        # El nombre comercial no tiene columna propia: sale de `name`.
        'EmsrNombreComercial' => 'ACME S.A.',
        'EmsrIdeTipo' => '02', 'EmsrIdeNumero' => '3101822733',
        'CodigoActividad' => '7020', 'EmsrRegistroFiscal8707' => '12345',
        'EmailCC' => 'uno@acme.cr;dos@acme.cr', 'PurchInvSeriesNum' => 42,
        'DefaultXmlTaxCode' => 'IVA13', 'DefaultWarehouse' => 'PRIN'
      )
    end

    # El bloque del emisor volvió a vivir en SAP (`CLAUDE.md` §32, caso
    # `company_config_udt`): `show` SÍ habla con SAP, con las credenciales de
    # LICENCIA de la conexión (`Sap::CompanyClient`, no `Sap::UserClient` —
    # una lectura no se atribuye a nadie).
    it 'lee la configuración del emisor con las credenciales de LICENCIA de la conexión' do
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}"

      expect(Sap::CompanyClient).to have_received(:for).with(acme)
      expect(Sap::UserClient).not_to have_received(:for)
    end

    it 'responde 422 cuando falta configuración de SAP' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'No tiene conexión de SAP asignada.')
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('No tiene conexión de SAP asignada.')
    end

    it 'responde 502 cuando el Service Layer falla' do
      allow(sap_client).to receive(:get)
        .and_raise(Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error'))
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}"

      expect(response).to have_http_status(:bad_gateway)
    end

    it 'responde 404 con un id que no existe' do
      sign_in_with('Configurations_Companies_Update')

      get '/api/companies/999999'

      expect(response).to have_http_status(:not_found)
    end

    # El alcance de `show` es el mismo de `index`: sin el permiso de "ver todas",
    # una compañía ajena no existe para este usuario.
    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{ajena.id}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'filtro por nombre' do
    before do
      UsersByCompany.create!(user: user, company: Company.create!(name: 'Beta Industrial'))
      sign_in_with('Configurations_Companies_ListAccess')
    end

    it 'filtra como "contiene", sin distinguir mayúsculas' do
      get '/api/companies', params: { name: 'beta' }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['Beta Industrial'])
      expect(body_data['Total']).to eq(1)
    end

    it 'en blanco no filtra nada' do
      get '/api/companies', params: { name: '  ' }

      expect(body_data['Total']).to eq(2)
    end
  end

  describe 'filtro por cédula' do
    before do
      acme.update!(issuer_id_number: '3101822733')
      UsersByCompany.create!(
        user: user, company: Company.create!(name: 'Beta Industrial', issuer_id_number: '3105551234')
      )
      sign_in_with('Configurations_Companies_ListAccess')
    end

    it 'filtra como "contiene"' do
      get '/api/companies', params: { issuer_id_number: '822733' }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.'])
      expect(body_data['Total']).to eq(1)
    end

    it 'en blanco no filtra nada' do
      get '/api/companies', params: { issuer_id_number: '  ' }

      expect(body_data['Total']).to eq(2)
    end

    it 'se combina con el filtro por nombre' do
      get '/api/companies', params: { name: 'beta', issuer_id_number: '822733' }

      expect(body_data['Total']).to eq(0)
    end
  end

  # El alta: reemplaza `POST /api/Companies` del .NET. A diferencia de edición
  # (un botón "Actualizar" por sección), el alta tiene un único botón, así que
  # manda "Datos Generales", "Adicional" (`EmailCC`), "Hacienda (ATV)" y
  # "Adjuntos" juntos, en una sola petición multipart — nunca JSON, porque el
  # certificado y los adjuntos pueden venir en la misma petición.
  describe 'POST /api/companies' do
    let!(:files_root) { use_temporary_files_root }

    # Obligatoria desde que el alta exige la bandeja de correo (contexto
    # `:new_company_form` en `Company`): sin ella `general_params` por sí solo
    # ya no alcanza para crear una compañía.
    let(:inbox) { EmailConfig.create!(email: 'facturas@beta.cr', host: 'smtp.beta.cr', port: 587, password: 'x') }

    let(:pin)             { 'clave-del-p12' }
    let(:cert_expires_at) { Time.zone.parse('2029-03-15 10:00:00') }
    let(:p12_bytes)       { build_p12(pin: pin, expires_at: cert_expires_at) }
    let(:logo_bytes)      { "\x89PNG\r\n\x1a\nlogo-de-beta".b }
    let(:format_bytes)    { "CRYSTAL\x1areporte-de-beta".b }

    def cert_upload(filename: '3105551234.p12')
      uploaded_file(p12_bytes, filename: filename, type: 'application/x-pkcs12')
    end

    def logo_upload(filename: 'logo-beta.png')
      uploaded_file(logo_bytes, filename: filename, type: 'image/png')
    end

    def format_upload(filename: 'formato-beta.rpt')
      uploaded_file(format_bytes, filename: filename, type: 'application/x-rpt')
    end

    def files_for(id_number: '3105551234')
      Dir.glob(File.join(files_root, id_number, '*'))
    end

    # Un payload COMPLETO: "Datos Generales" y "Hacienda (ATV)" —certificado y
    # formato de impresión incluidos— son obligatorias para registrar la
    # compañía (un solo botón, sin guardado por sección como en edición). Cada
    # ejemplo negativo parte de acá y le quita SOLO lo que quiere probar
    # (`.except`/`.merge`), para que el mensaje de error no se mezcle con otro
    # campo también faltante.
    let(:general_params) do
      {
        Name: 'Beta Industrial', EmsrNombre: 'Beta Industrial S.A.',
        EmsrIdeTipo: '02', EmsrIdeNumero: '3105551234', CodigoActividad: '620100',
        SapDb: 'SBO_BETA', ConnectionId: sap.id, EmailConfigId: inbox.id,
        EmailSenderType: 1, FreightType: 1, Active: true,
        CertPin: pin, TokenUsr: 'atv@hacienda.go.cr', TokenPass: 'secreto-atv',
        file: cert_upload, PrintFormat: format_upload
      }
    end

    it 'exige Configurations_Companies_Create' do
      sign_in_with

      post '/api/companies', params: general_params

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 401 sin sesión' do
      post '/api/companies', params: general_params

      expect(response).to have_http_status(:unauthorized)
    end

    it 'crea la compañía con los datos generales' do
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params

      expect(response).to have_http_status(:created)
      created = Company.find(body_data['Id'])
      expect(created).to have_attributes(
        name: 'Beta Industrial', issuer_id_number: '3105551234',
        sap_db: 'SBO_BETA', connection_id: sap.id
      )
    end

    # El bloque del emisor ya no es columna de `companies`: se registra en la
    # UDT `@CL_FEC_ISSUERCONFIG`, atribuido a quien crea la compañía
    # (`Sap::UserClient`, no la licencia — mismo criterio que toda escritura de
    # `Api::Companies::ActivityCodesController`).
    it 'registra la configuración del emisor en SAP, atribuida a quien crea la compañía' do
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params

      expect(response).to have_http_status(:created)
      expect(Sap::UserClient).to have_received(:for).with(instance_of(Company), user: user)
      expect(sap_client).to have_received(:post).with(
        'U_CL_FEC_ISSUERCONFIG',
        body: hash_including('U_LegalName' => 'Beta Industrial S.A.', 'U_IdType' => '02',
                              'U_EconomicActivityCode' => '620100',
                              'U_CommercialName' => 'Beta Industrial', 'U_IdNumber' => '3105551234')
      )
    end

    # "Todo o nada": si la UDT no se pudo escribir, ni la fila de `companies` ni
    # los archivos sobreviven — de lo contrario la compañía quedaría creada acá
    # pero con `show` sin poder armar la sección del emisor.
    it 'revierte la fila y los archivos si falla el registro en SAP' do
      allow(sap_client).to receive(:post)
        .and_raise(Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error'))
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:bad_gateway)
      expect(files_for).to be_empty
    end

    it 'revierte todo cuando falta configuración de SAP para la persona que crea' do
      allow(Sap::UserClient).to receive(:for)
        .and_raise(Sap::UserClient::MissingConfiguration, 'no tiene credenciales de SAP configuradas.')
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(files_for).to be_empty
    end

    # Sin esto, quien la crea no tiene `Configurations_Companies_ViewAllApplicationCompanies`
    # y la compañía desaparece de su alcance apenas se guarda (`VisibleCompanies`,
    # CLAUDE.md §28 — "el catálogo y la escritura resuelven el mismo alcance").
    it 'asigna al usuario que la crea' do
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params

      created = Company.find(body_data['Id'])
      expect(UsersByCompany.exists?(user_id: user.id, company_id: created.id)).to be true
    end

    it 'la deja visible en el listado del usuario que la creó' do
      sign_in_with('Configurations_Companies_ListAccess', 'Configurations_Companies_Create')

      post '/api/companies', params: general_params
      get '/api/companies'

      expect(body_data['Items'].map { |c| c['Name'] }).to include('Beta Industrial')
    end

    it 'acepta la bandeja de recepción y "enviar rechazados"' do
      reception = ReceptionMailbox.create!(mail_server: 'imap.beta.cr', email: 'recepcion@beta.cr',
                                           port: 993, password: 'x')
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params.merge(
        ReceptionMailboxId: reception.id, SendRejectedDocuments: true
      )

      created = Company.find(body_data['Id'])
      expect(created).to have_attributes(
        email_config_id: inbox.id, reception_mailbox_id: reception.id,
        send_rejected_documents: true
      )
    end

    it 'responde 422 con datos inválidos, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.merge(Name: '')
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre no puede estar en blanco')
    end

    # Dos compañías con la misma cédula serían la misma compañía facturando por
    # dos lados ante Hacienda. Se verifica ANTES de escribir ningún archivo
    # (`company.valid?(:new_company_form)`, antes de `certificate_attributes`).
    it 'responde 422 si la cédula ya pertenece a otra compañía activa, sin insertar nada ni dejar archivos' do
      create(:company, issuer_id_number: '3105551234')
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq(
        'El número de identificación del emisor ya pertenece a otra compañía registrada (activa o inactiva)'
      )
      expect(files_for).to be_empty
    end

    # El requisito explícito: dar de baja una compañía no libera su cédula.
    it 'responde 422 si la cédula ya pertenece a otra compañía INACTIVA, sin insertar nada' do
      existing = create(:company, issuer_id_number: '3105551234')
      existing.soft_delete!
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq(
        'El número de identificación del emisor ya pertenece a otra compañía registrada (activa o inactiva)'
      )
    end

    # Sin conexión de SAP no hay a qué SAP consultar; sin bandeja de correo la
    # compañía no tiene cómo enviar el correo del comprobante. Las dos son
    # obligatorias SOLO en el alta (`Company` con el contexto
    # `:new_company_form`) — una compañía ya creada se sigue pudiendo editar
    # sin ellas.
    it 'responde 422 sin conexión de SAP, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:ConnectionId)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('La conexión de SAP no puede estar en blanco')
    end

    it 'responde 422 sin bandeja de correo, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:EmailConfigId)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('La bandeja de correo no puede estar en blanco')
    end

    # "Hacienda (ATV)" también es obligatoria en el alta: el formulario no
    # tiene botón "Actualizar" por sección como en edición, así que una
    # compañía sin credenciales del ATV quedaría a medio configurar desde el
    # primer momento.
    it 'responde 422 sin el PIN del certificado, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:CertPin)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El pin del certificado no puede estar en blanco')
    end

    it 'responde 422 sin el token de usuario, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:TokenUsr)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El token de usuario no puede estar en blanco')
    end

    it 'responde 422 sin el token password, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:TokenPass)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El token password no puede estar en blanco')
    end

    # El certificado y el formato de impresión son ARCHIVOS: no son un atributo
    # del modelo hasta que se procesan, así que su ausencia se exige sobre el
    # cuerpo de la petición, antes de intentar escribir nada (`create_params`
    # + `certificate_attributes`/`attachment_attributes` en el controller).
    it 'responde 422 sin el certificado, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:file)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Adjunte el certificado digital para poder registrar la compañía.')
    end

    it 'responde 422 sin el formato de impresión, sin insertar nada' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.except(:PrintFormat)
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Adjunte el formato de impresión para poder registrar la compañía.')
      # El certificado sí vino y es válido: si el controller lo escribiera
      # antes de exigir el formato de impresión, quedaría huérfano en disco.
      expect(files_for).to be_empty
    end

    # Un solo botón, una sola petición: "Adicional", "Hacienda (ATV)" y
    # "Adjuntos" viajan junto con "Datos Generales" — no hay guardado por
    # sección en el alta, a diferencia de edición.
    it 'acepta EmailCC, el certificado y los dos adjuntos en la misma petición' do
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params.merge(EmailCC: 'uno@beta.cr;dos@beta.cr', Logo: logo_upload)

      expect(response).to have_http_status(:created)
      created = Company.find(body_data['Id'])
      expect(created.email_cc).to eq('uno@beta.cr;dos@beta.cr')
      expect(created.token_user).to eq('atv@hacienda.go.cr')
      expect(created.cert_expires_at).to be_within(1.second).of(cert_expires_at)
      expect(File.binread(created.cert_path)).to eq(p12_bytes)
      expect(File.binread(created.logo_path)).to eq(logo_bytes)
      expect(File.binread(created.print_format_path)).to eq(format_bytes)
    end

    it 'no expone los secretos en la respuesta, solo si quedaron guardados' do
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params

      expect(body_data).not_to have_key('CertPin')
      expect(body_data).not_to have_key('TokenPass')
      expect(body_data['HasCertPin']).to be true
      expect(body_data['HasTokenPass']).to be true
    end

    it 'responde 422 si el PIN no abre el certificado, sin crear la compañía ni dejar el archivo' do
      sign_in_with('Configurations_Companies_Create')

      expect do
        post '/api/companies', params: general_params.merge(CertPin: 'pin-equivocado')
      end.not_to change(Company, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(files_for).to be_empty
    end

    it 'no escribe ningún archivo si los datos generales son inválidos' do
      sign_in_with('Configurations_Companies_Create')

      post '/api/companies', params: general_params.merge(Name: '', Logo: logo_upload)

      expect(response).to have_http_status(:unprocessable_content)
      expect(files_for).to be_empty
    end
  end
end

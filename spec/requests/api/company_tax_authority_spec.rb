# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PATCH /api/companies/:company_id/tax_authority', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }
  let(:sap)  { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) do
    Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME',
                    issuer_legal_name: 'ACME Sociedad Anónima', issuer_id_type: '02',
                    issuer_id_number: '3101822733', economic_activity_code: '7020',
                    email_cc: 'copia@acme.cr', purchase_invoice_series: 7,
                    cert_path: File.join(files_root, '3101822733', 'viejo.p12'),
                    cert_pin: '1234',
                    cert_expires_at: Time.zone.parse('2027-05-01 12:00:00'),
                    token_user: 'cpj-3-101-822733@stag.comprobanteselectronicos.go.cr',
                    token_password: 'secreto-atv')
  end

  # Las cinco claves de la sección. Son el contrato entre la lectura
  # (`GET /api/companies/:id`) y este PATCH: si una se agrega en un lado y no en
  # el otro, el formulario muestra un campo que el guardado ignora y el usuario no
  # se entera. Los dos ejemplos de "contrato" de más abajo lo verifican.
  ATV_KEYS = %w[CertFileName CertExpireDate TokenUsr HasCertPin HasTokenPass].freeze

  # Los dos secretos de la sección. No pueden salir por ninguna respuesta.
  SECRET_KEYS = %w[CertPin TokenPass].freeze

  let(:pin)            { 'clave-del-p12' }
  let(:cert_expires_at) { Time.zone.parse('2029-03-15 10:00:00') }
  let(:p12_bytes)      { build_p12(pin: pin, expires_at: cert_expires_at) }

  # La raíz de archivos se apunta a una carpeta descartable ANTES de que se cree
  # la compañía: su `cert_path` de partida tiene que quedar adentro, o el borrado
  # del anterior no aplicaría y el ejemplo probaría otra cosa.
  let!(:files_root) { use_temporary_files_root }

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

  # Multipart: la sección lleva el certificado, así que el cuerpo no es JSON.
  def patch_section(payload)
    patch "/api/companies/#{acme.id}/tax_authority", params: payload
  end

  def stored_path(name, id_number: '3101822733')
    File.join(files_root, id_number, name)
  end

  # El valor tal como quedó en la columna, sin pasar por el modelo: es la única
  # forma de comprobar que lo que se guardó está cifrado y no en texto plano.
  def raw_column(name)
    Company.connection.select_value(
      Company.sanitize_sql_array(["SELECT #{name} FROM companies WHERE id = ?", acme.id])
    )
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      patch "/api/companies/#{acme.id}/tax_authority", params: { TokenUsr: 'x' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Configurations_Companies_Update' do
      sign_in_with('Configurations_Companies_ListAccess')

      patch_section(TokenUsr: 'x')

      expect(response).to have_http_status(:forbidden)
      expect(acme.reload.token_user).to include('stag.comprobanteselectronicos')
    end

    it 'responde 404 con un id que no existe' do
      sign_in_with('Configurations_Companies_Update')

      patch '/api/companies/999999/tax_authority', params: { TokenUsr: 'x' }

      expect(response).to have_http_status(:not_found)
    end

    # El alcance es el mismo de la lectura: sin "ver todas", una compañía ajena no
    # existe para este usuario, y por eso es 404 y no 403.
    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.', token_user: 'ajeno')
      sign_in_with('Configurations_Companies_Update')

      patch "/api/companies/#{ajena.id}/tax_authority", params: { TokenUsr: 'x' }

      expect(response).to have_http_status(:not_found)
      expect(ajena.reload.token_user).to eq('ajeno')
    end
  end

  describe 'credenciales del ATV' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'actualiza el token de usuario y los dos secretos' do
      patch_section(TokenUsr: 'cpj-3-101-822733@prod.comprobanteselectronicos.go.cr',
                    CertPin: '9999', TokenPass: 'nuevo-secreto')

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        token_user:     'cpj-3-101-822733@prod.comprobanteselectronicos.go.cr',
        cert_pin:       '9999',
        token_password: 'nuevo-secreto'
      )
    end

    it 'devuelve la sección como quedó guardada, con el mensaje' do
      patch_section(TokenUsr: '  atv@hacienda.go.cr  ')

      expect(body_data['TokenUsr']).to eq('atv@hacienda.go.cr')
      expect(body_data['HasCertPin']).to be(true)
      expect(body['Message']).to eq('Datos de Hacienda actualizados con éxito.')
    end

    it 'no borra lo que la petición no mencionó' do
      patch_section(TokenUsr: 'atv@hacienda.go.cr')

      expect(acme.reload).to have_attributes(cert_pin: '1234', token_password: 'secreto-atv')
    end

    # Vacío y NULL son la misma cosa para el negocio; tener las dos
    # representaciones obliga a preguntar por ambas en cada consulta.
    it 'guarda un campo de texto vacío como NULL' do
      patch_section(TokenUsr: '   ')

      expect(acme.reload.token_user).to be_nil
    end
  end

  # El campo se le muestra vacío al usuario porque el valor guardado no vuelve
  # nunca. Por eso la clave ausente NO es "borralo": es "dejalo como está".
  describe 'los dos secretos' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'los deja intactos cuando la clave no viene en el cuerpo' do
      patch_section(TokenUsr: 'atv@hacienda.go.cr')

      expect(acme.reload.cert_pin).to eq('1234')
      expect(acme.token_password).to eq('secreto-atv')
    end

    it 'los borra cuando la clave viene vacía' do
      patch_section(CertPin: '', TokenPass: '')

      expect(acme.reload.cert_pin).to be_nil
      expect(acme.token_password).to be_nil
    end

    it 'los guarda cifrados, no en texto plano' do
      patch_section(CertPin: '9999', TokenPass: 'otro-secreto')

      expect(raw_column('cert_pin')).not_to include('9999')
      expect(raw_column('token_password')).not_to include('otro-secreto')
    end

    it 'no los devuelve en la respuesta del PATCH' do
      patch_section(CertPin: '9999', TokenPass: 'otro-secreto')

      expect(body_data.keys).not_to include(*SECRET_KEYS)
      expect(response.body).not_to include('9999')
      expect(response.body).not_to include('otro-secreto')
    end

    it 'no los devuelve al consultar la compañía' do
      get "/api/companies/#{acme.id}"

      expect(body_data.keys).not_to include(*SECRET_KEYS)
      expect(response.body).not_to include('1234')
      expect(response.body).not_to include('secreto-atv')
    end

    # Lo único que se le cuenta al cliente: si hay uno guardado. Con eso el
    # formulario distingue "no hay PIN" de "hay uno y no se muestra".
    it 'informa si hay uno guardado, sin decir cuál' do
      get "/api/companies/#{acme.id}"

      expect(body_data).to include('HasCertPin' => true, 'HasTokenPass' => true)
    end

    it 'informa que no hay ninguno cuando la compañía no los tiene' do
      patch_section(CertPin: '', TokenPass: '')

      expect(body_data).to include('HasCertPin' => false, 'HasTokenPass' => false)
    end
  end

  describe 'carga del certificado' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'guarda el archivo bajo la cédula de la compañía' do
      patch_section(file: uploaded_file(p12_bytes, filename: '3101822733.p12'), CertPin: pin)

      expect(response).to have_http_status(:ok)
      expect(File.binread(stored_path('3101822733.p12'))).to eq(p12_bytes)
    end

    # La columna guarda la ruta absoluta porque es lo que abre el servicio de
    # firma; la pantalla ve solo el nombre.
    it 'apunta cert_path a esa ruta y devuelve solo el nombre' do
      patch_section(file: uploaded_file(p12_bytes, filename: '3101822733.p12'), CertPin: pin)

      expect(acme.reload.cert_path).to eq(stored_path('3101822733.p12'))
      expect(body_data['CertFileName']).to eq('3101822733.p12')
      expect(response.body).not_to include(files_root.tr('\\', '/'))
    end

    # Es la razón de que la fecha ya no viaje en el cuerpo: sale del archivo.
    it 'deriva el vencimiento del propio certificado' do
      patch_section(file: uploaded_file(p12_bytes), CertPin: pin)

      expect(acme.reload.cert_expires_at).to eq(cert_expires_at)
    end

    it 'abre el archivo con el PIN que ya tenía la compañía si no viene uno nuevo' do
      acme.update!(cert_pin: pin)

      patch_section(file: uploaded_file(p12_bytes))

      expect(response).to have_http_status(:ok)
      expect(acme.reload.cert_expires_at).to eq(cert_expires_at)
    end

    it 'borra el certificado anterior cuando el nombre cambia' do
      anterior = stored_path('viejo.p12')
      FileUtils.mkdir_p(File.dirname(anterior))
      File.binwrite(anterior, 'certificado anterior')

      patch_section(file: uploaded_file(p12_bytes, filename: 'nuevo.p12'), CertPin: pin)

      expect(acme.reload.cert_path).to eq(stored_path('nuevo.p12'))
      expect(File.exist?(anterior)).to be(false)
    end

    it 'sobrescribe cuando se vuelve a cargar el mismo nombre' do
      patch_section(file: uploaded_file(p12_bytes, filename: 'viejo.p12'), CertPin: pin)

      expect(response).to have_http_status(:ok)
      expect(File.binread(stored_path('viejo.p12'))).to eq(p12_bytes)
    end

    it 'acepta la extensión .pfx' do
      patch_section(file: uploaded_file(p12_bytes, filename: 'cert.pfx'), CertPin: pin)

      expect(response).to have_http_status(:ok)
      expect(File.exist?(stored_path('cert.pfx'))).to be(true)
    end

    # El certificado anterior de una compañía importada vive en el disco del
    # servidor .NET: esta pantalla no administra esa carpeta y borrar ahí sería
    # destruir el archivo que el firmador está usando.
    it 'no toca el archivo anterior si está fuera de la raíz configurada' do
      ajeno = Tempfile.new(['ajeno', '.p12'])
      ajeno.write('certificado de otro servidor')
      ajeno.close
      acme.update!(cert_path: ajeno.path)

      patch_section(file: uploaded_file(p12_bytes, filename: 'nuevo.p12'), CertPin: pin)

      expect(response).to have_http_status(:ok)
      expect(File.exist?(ajeno.path)).to be(true)
    end
  end

  describe 'cuando el certificado no se puede guardar' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'rechaza un PIN que no abre el archivo, sin escribir nada' do
      patch_section(file: uploaded_file(p12_bytes, filename: 'nuevo.p12'), CertPin: 'otra-clave')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('Verifique que el PIN sea el correcto')
      expect(File.exist?(stored_path('nuevo.p12'))).to be(false)
      expect(acme.reload.cert_path).to eq(stored_path('viejo.p12'))
    end

    it 'pide el PIN cuando no viene ninguno y la compañía tampoco lo tiene' do
      acme.update!(cert_pin: nil)

      patch_section(file: uploaded_file(p12_bytes))

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Ingrese el PIN del certificado para poder guardarlo.')
    end

    it 'rechaza una extensión que no es de certificado' do
      patch_section(file: uploaded_file(p12_bytes, filename: 'cert.txt'), CertPin: pin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('extensión válida')
    end

    # Sin cédula no hay carpeta donde ponerlo: el nombre de la carpeta ES la
    # cédula.
    it 'exige que la compañía tenga número de identificación' do
      acme.update!(issuer_id_number: nil)

      patch_section(file: uploaded_file(p12_bytes), CertPin: pin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('número de identificación')
    end

    # El nombre lo elige quien sube el archivo: si trajera carpetas, escribiría
    # fuera de la raíz.
    it 'descarta las carpetas que traiga el nombre del archivo' do
      patch_section(file: uploaded_file(p12_bytes, filename: '..\\..\\evil.p12'), CertPin: pin)

      expect(response).to have_http_status(:ok)
      expect(acme.reload.cert_path).to eq(stored_path('evil.p12'))
    end
  end

  # Lo que hace que los botones sean independientes de verdad y no solo en la
  # pantalla: este endpoint no puede tocar nada de otra sección, ni siquiera si
  # viene en el cuerpo.
  describe 'aislamiento entre secciones' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'ignora los campos que pertenecen a otras secciones' do
      patch_section(
        TokenUsr: 'atv@hacienda.go.cr',
        # Sección "Datos Generales"
        Name: 'Otra S.A.', SapDb: 'SBO_OTRA', EmsrIdeNumero: '999999999', Active: false,
        # Sección "Adicional"
        EmailCC: 'otro@acme.cr',
        # Sección "Factura a proveedor"
        PurchInvSeriesNum: 99,
        # Ni una columna que no existe
        Uuid: 'reescrito'
      )

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        token_user:              'atv@hacienda.go.cr',
        name:                    'ACME S.A.',
        sap_db:                  'SBO_ACME',
        issuer_id_number:        '3101822733',
        is_active:               true,
        email_cc:                'copia@acme.cr',
        purchase_invoice_series: 7
      )
      expect(acme.uuid).not_to eq('reescrito')
    end

    # Las dos columnas son de esta sección pero no tienen campo en el formulario,
    # así que el endpoint tampoco las acepta: no hay nada que el usuario edite.
    it 'ignora client_id y grant_type, que la pantalla no ofrece' do
      patch_section(TokenUsr: 'atv@hacienda.go.cr', client_id: 'api', grant_type: 'password')

      expect(acme.reload).to have_attributes(client_id: nil, grant_type: nil)
    end
  end

  # Los dos salen del archivo. Aceptarlos del cuerpo permitía posponer la alarma
  # de vencimiento escribiendo una fecha, y —peor— pisar con un nombre pelado la
  # ruta que el servicio de firma abre para firmar los XML.
  describe 'la ruta y el vencimiento no los manda el cliente' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'ignora CertPath aunque venga en el cuerpo' do
      patch_section(TokenUsr: 'atv@hacienda.go.cr', CertPath: 'cualquier-cosa.p12')

      expect(response).to have_http_status(:ok)
      expect(acme.reload.cert_path).to eq(stored_path('viejo.p12'))
    end

    it 'ignora CertExpireDate aunque venga en el cuerpo' do
      patch_section(TokenUsr: 'atv@hacienda.go.cr', CertExpireDate: '2099-01-01 00:00:00')

      expect(response).to have_http_status(:ok)
      expect(acme.reload.cert_expires_at).to eq(Time.zone.parse('2027-05-01 12:00:00'))
    end
  end

  # Los dos endpoints tienen que hablar de los mismos cinco campos. No es
  # automático —la lista de arriba se mantiene a mano— pero deja el contrato en un
  # solo lugar y falla si alguno de los dos lados deja de exponer un campo.
  describe 'contrato con la lectura' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'GET /api/companies/:id devuelve las cinco claves de la sección' do
      get "/api/companies/#{acme.id}"

      expect(body_data.keys).to include(*ATV_KEYS)
    end

    it 'el PATCH devuelve esas mismas cinco claves' do
      patch_section(file: uploaded_file(p12_bytes), CertPin: pin,
                    TokenUsr: 'atv@hacienda.go.cr', TokenPass: 'otro')

      expect(response).to have_http_status(:ok)
      expect(body_data.keys).to match_array(ATV_KEYS)
    end
  end
end

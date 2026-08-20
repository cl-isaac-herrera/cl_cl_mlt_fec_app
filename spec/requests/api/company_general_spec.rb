# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PATCH /api/companies/:company_id/general', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }
  let(:sap)  { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) do
    Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME',
                    issuer_legal_name: 'ACME Sociedad Anónima', issuer_id_type: '02',
                    issuer_id_number: '3101822733', economic_activity_code: '7020',
                    tax_registry_8707: '111', email_cc: 'copia@acme.cr',
                    purchase_invoice_series: 7, default_warehouse: 'PRIN')
  end

  # Las once claves de la sección. Son el contrato entre la lectura
  # (`GET /api/companies/:id`) y este PATCH: si una se agrega en un lado y no en
  # el otro, el formulario muestra un campo que el guardado ignora y el usuario no
  # se entera. Los dos ejemplos de "contrato" de más abajo lo verifican.
  GENERAL_KEYS = %w[
    Name Active ConnectionId SapDb EmailSenderType FreightType
    EmsrNombre EmsrIdeTipo EmsrIdeNumero CodigoActividad EmsrRegistroFiscal8707
  ].freeze

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

  def patch_section(payload)
    patch "/api/companies/#{acme.id}/general", params: payload, as: :json
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      patch "/api/companies/#{acme.id}/general", params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Configurations_Companies_Update' do
      sign_in_with('Configurations_Companies_ListAccess')

      patch_section(Name: 'X')

      expect(response).to have_http_status(:forbidden)
      expect(acme.reload.name).to eq('ACME S.A.')
    end

    it 'responde 404 con un id que no existe' do
      sign_in_with('Configurations_Companies_Update')

      patch '/api/companies/999999/general', params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    # El alcance es el mismo de la lectura: sin "ver todas", una compañía ajena no
    # existe para este usuario, y por eso es 404 y no 403.
    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_Update')

      patch "/api/companies/#{ajena.id}/general", params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(ajena.reload.name).to eq('Ajena S.A.')
    end
  end

  describe 'guardado' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'actualiza los once campos de la sección' do
      otra = Connection.create!(name: 'SAP Prod', sl_url: 'https://prod.test:50000/b1s/v1')

      patch_section(
        Name: 'ACME Global', Active: false, ConnectionId: otra.id, SapDb: 'SBO_NUEVA',
        EmailSenderType: 2, FreightType: 2, EmsrNombre: 'ACME Global S.A.',
        EmsrIdeTipo: '01', EmsrIdeNumero: '123456789', CodigoActividad: '620100',
        EmsrRegistroFiscal8707: '999'
      )

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        name: 'ACME Global', is_active: false, connection_id: otra.id, sap_db: 'SBO_NUEVA',
        email_sender_type: 2, freight_type: 2, issuer_legal_name: 'ACME Global S.A.',
        issuer_id_type: '01', issuer_id_number: '123456789',
        economic_activity_code: '620100', tax_registry_8707: '999'
      )
    end

    it 'devuelve la sección como quedó guardada, con el mensaje' do
      patch_section(Name: '  ACME Global  ')

      expect(body_data['Name']).to eq('ACME Global')
      expect(body['Message']).to eq('Datos generales actualizados con éxito.')
    end

    it 'no borra lo que la petición no mencionó' do
      patch_section(Name: 'ACME Global')

      expect(acme.reload).to have_attributes(
        sap_db: 'SBO_ACME', issuer_id_number: '3101822733', economic_activity_code: '7020'
      )
    end

    # Vacío y NULL son la misma cosa para el negocio; tener las dos
    # representaciones obliga a preguntar por ambas en cada consulta.
    it 'guarda un campo de texto vacío como NULL' do
      patch_section(EmsrRegistroFiscal8707: '   ')

      expect(acme.reload.tax_registry_8707).to be_nil
    end

    it 'acepta desasignar la conexión de SAP' do
      patch_section(ConnectionId: nil)

      expect(acme.reload.connection_id).to be_nil
    end
  end

  # Lo que hace que los botones sean independientes de verdad y no solo en la
  # pantalla: este endpoint no puede tocar nada de otra sección, ni siquiera si
  # viene en el cuerpo.
  describe 'aislamiento entre secciones' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'ignora los campos que pertenecen a otras secciones' do
      patch_section(
        Name: 'ACME Global',
        # Sección "Adicional"
        EmailCC: 'otro@acme.cr',
        # Sección "Hacienda (ATV)"
        CertPin: '9999', TokenUsr: 'atv', CertPath: 'C:\\otro.p12',
        # Sección "Factura a proveedor"
        PurchInvSeriesNum: 99, DefaultWarehouse: 'OTRO',
        # Ni columnas que no expone ninguna sección
        Uuid: 'reescrito', EnvironmentId: 4
      )

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        name: 'ACME Global',
        email_cc: 'copia@acme.cr',
        purchase_invoice_series: 7,
        default_warehouse: 'PRIN',
        cert_pin: nil,
        token_user: nil,
        environment_id: nil
      )
      expect(acme.uuid).to be_present
      expect(acme.uuid).not_to eq('reescrito')
    end
  end

  describe 'validación' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'rechaza el nombre en blanco con 422 y mensaje en español' do
      patch_section(Name: '   ')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre no puede estar en blanco')
      expect(acme.reload.name).to eq('ACME S.A.')
    end

    it 'rechaza un tipo de identificación que Hacienda no define' do
      patch_section(EmsrIdeTipo: '99')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El tipo de identificación del emisor no está incluido en la lista')
    end

    # Sin la validación del modelo esto reventaba contra la llave foránea y
    # llegaba como un 500 en vez de un mensaje.
    it 'rechaza una conexión de SAP que no existe, sin reventar' do
      patch_section(ConnectionId: 999_999)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('La conexión de SAP no corresponde a una conexión existente')
    end

    it 'rechaza una razón social más larga que el límite de la columna' do
      patch_section(EmsrNombre: 'A' * 101)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('es demasiado largo')
    end
  end

  # Los dos endpoints tienen que hablar de los mismos once campos. No es
  # automático —la lista de arriba se mantiene a mano— pero deja el contrato en un
  # solo lugar y falla si alguno de los dos lados deja de exponer un campo.
  describe 'contrato con la lectura' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'GET /api/companies/:id devuelve las once claves de la sección' do
      get "/api/companies/#{acme.id}"

      expect(body_data.keys).to include(*GENERAL_KEYS)
    end

    it 'el PATCH acepta y devuelve esas mismas once claves' do
      payload = {
        'Name' => 'ACME Global', 'Active' => true, 'ConnectionId' => sap.id,
        'SapDb' => 'SBO_NUEVA', 'EmailSenderType' => 2, 'FreightType' => 2,
        'EmsrNombre' => 'ACME Global S.A.', 'EmsrIdeTipo' => '01',
        'EmsrIdeNumero' => '123456789', 'CodigoActividad' => '620100',
        'EmsrRegistroFiscal8707' => '999'
      }
      # El payload de este ejemplo tampoco puede quedarse corto respecto a la lista.
      expect(payload.keys).to match_array(GENERAL_KEYS)

      patch_section(payload)

      expect(response).to have_http_status(:ok)
      expect(body_data.keys).to match_array(GENERAL_KEYS)
    end
  end
end

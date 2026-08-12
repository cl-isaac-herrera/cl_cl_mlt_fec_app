# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Connections', type: :request do
  let(:user)    { User.create!(email: 'conexiones@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  # Deja al usuario con los permisos indicados sobre `company` y abre la sesión
  # con esa compañía activa: require_permission! resuelve contra la de la sesión.
  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def create_connection(name:, sl_url: 'https://sap.test:50000/b1s/v1', sl_type: 'SQL')
    Connection.create!(name: name, sl_url: sl_url, sl_type: sl_type)
  end

  describe 'GET /api/connections' do
    it 'lista las conexiones con el total real, no el de la página' do
      3.times { |i| create_connection(name: "SAP #{i}") }

      sign_in_with('Configurations_Connections_Access')
      get '/api/connections', params: { page: 1, per_page: 2 }

      expect(response).to have_http_status(:ok)
      expect(body_data['Items'].size).to eq(2)
      # El total es de la consulta completa: es lo que el contador de Tabulator
      # necesita para no sobreestimar (CLAUDE.md §17).
      expect(body_data['Total']).to eq(3)
    end

    it 'devuelve la segunda página, no la primera otra vez' do
      %w[Alfa Beta Gamma].each { |n| create_connection(name: n) }

      sign_in_with('Configurations_Connections_Access')
      get '/api/connections', params: { page: 2, per_page: 2 }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['Gamma'])
    end

    it 'filtra por nombre y por URL, sin distinguir mayúsculas' do
      create_connection(name: 'SAP Producción', sl_url: 'https://prod.test:50000/b1s/v1')
      create_connection(name: 'SAP Pruebas',    sl_url: 'https://qa.test:50000/b1s/v1')

      sign_in_with('Configurations_Connections_Access')

      get '/api/connections', params: { name: 'producc' }
      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['SAP Producción'])

      get '/api/connections', params: { sl_url: 'qa.test' }
      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['SAP Pruebas'])
    end

    it 'omite las conexiones desactivadas (soft delete)' do
      create_connection(name: 'Vigente')
      create_connection(name: 'Dada de baja').soft_delete!

      sign_in_with('Configurations_Connections_Access')
      get '/api/connections'

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['Vigente'])
      expect(body_data['Total']).to eq(1)
    end

    it 'expone el contrato ApiResponse con los campos que existen en la tabla' do
      conn = create_connection(name: 'SAP Producción', sl_type: 'HANA')

      sign_in_with('Configurations_Connections_Access')
      get '/api/connections'

      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body_data['Items'].first).to eq(
        'Id' => conn.id, 'Name' => 'SAP Producción',
        'SlUrl' => 'https://sap.test:50000/b1s/v1', 'SlType' => 'HANA'
      )
    end

    it 'acota per_page para que nadie pida la tabla entera de un saque' do
      sign_in_with('Configurations_Connections_Access')
      get '/api/connections', params: { per_page: 5_000 }

      expect(response).to have_http_status(:ok)
      expect(Api::ConnectionsController::MAX_PER_PAGE).to eq(100)
    end

    it 'responde 403 sin el permiso de acceso' do
      sign_in_with # con sesión y compañía, pero sin permisos

      get '/api/connections'

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 401 sin sesión' do
      get '/api/connections'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/connections/:id' do
    it 'devuelve la conexión pedida' do
      conn = create_connection(name: 'SAP Producción')

      sign_in_with('Configurations_Connections_Access')
      get "/api/connections/#{conn.id}"

      expect(response).to have_http_status(:ok)
      expect(body_data).to include('Id' => conn.id, 'Name' => 'SAP Producción')
    end

    it 'responde 404 si no existe' do
      sign_in_with('Configurations_Connections_Access')
      get '/api/connections/999999'

      expect(response).to have_http_status(:not_found)
      expect(body['Message']).to be_present
    end

    # El 403 tiene que ganarle al 404: si no, la respuesta le confirma a quien no
    # tiene permiso cuáles ids existen.
    it 'responde 403 —y no 404— sin permiso, aunque el id no exista' do
      sign_in_with

      get '/api/connections/999999'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /api/connections' do
    it 'crea la conexión con los tres campos de la tabla' do
      sign_in_with('Configurations_Connections_Create')

      post '/api/connections',
           params: { Name: 'SAP Nueva', SlUrl: 'https://nueva.test:50000/b1s/v1', SlType: 'HANA' },
           as: :json

      expect(response).to have_http_status(:created)
      expect(Connection.find_by(name: 'SAP Nueva')).to have_attributes(
        sl_url: 'https://nueva.test:50000/b1s/v1', sl_type: 'HANA'
      )
    end

    # Los mensajes se comparan literales a propósito: `default_locale = :es` sin
    # config/locales devolvía el bloque "Translation missing..." al usuario, y un
    # `be_present` pelado no lo detecta.
    it 'rechaza una URL que no es http(s)' do
      sign_in_with('Configurations_Connections_Create')

      post '/api/connections', params: { Name: 'SAP Mala', SlUrl: 'sap.test:50000' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('La URL del Service Layer debe empezar con http:// o https://')
      expect(Connection.find_by(name: 'SAP Mala')).to be_nil
    end

    it 'rechaza un motor fuera del catálogo' do
      sign_in_with('Configurations_Connections_Create')

      post '/api/connections',
           params: { Name: 'SAP X', SlUrl: 'https://x.test:50000/b1s/v1', SlType: 'ORACLE' },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El motor de base de datos no es un motor válido')
    end

    it 'rechaza un nombre repetido' do
      create_connection(name: 'SAP Producción')
      sign_in_with('Configurations_Connections_Create')

      post '/api/connections',
           params: { Name: 'SAP Producción', SlUrl: 'https://otra.test:50000/b1s/v1' },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre ya está en uso')
    end

    it 'une varios errores con "y", no con "and"' do
      sign_in_with('Configurations_Connections_Create')

      post '/api/connections', params: { Name: '', SlUrl: 'no-es-url' }, as: :json

      expect(body['Message'])
        .to eq('El nombre no puede estar en blanco y La URL del Service Layer debe empezar con http:// o https://')
    end

    it 'registra quién la creó' do
      sign_in_with('Configurations_Connections_Create')

      post '/api/connections',
           params: { Name: 'SAP Auditada', SlUrl: 'https://a.test:50000/b1s/v1' }, as: :json

      expect(Connection.find_by(name: 'SAP Auditada').created_by).to eq(user.email)
    end

    it 'responde 403 con el permiso de solo lectura' do
      sign_in_with('Configurations_Connections_Access')

      post '/api/connections',
           params: { Name: 'SAP Nueva', SlUrl: 'https://n.test:50000/b1s/v1' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Connection.find_by(name: 'SAP Nueva')).to be_nil
    end
  end

  describe 'PATCH /api/connections/:id' do
    it 'actualiza la conexión del path' do
      conn = create_connection(name: 'SAP Vieja')
      sign_in_with('Configurations_Connections_Update')

      patch "/api/connections/#{conn.id}",
            params: { Name: 'SAP Renombrada', SlUrl: 'https://nueva.test:50000/b1s/v1' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(conn.reload).to have_attributes(
        name: 'SAP Renombrada', sl_url: 'https://nueva.test:50000/b1s/v1'
      )
    end

    # El .NET mandaba el id en el cuerpo; acá manda el del path y el del cuerpo
    # se ignora, para que nadie edite otra fila cambiando el JSON.
    it 'ignora el Id que venga en el cuerpo' do
      objetivo = create_connection(name: 'Objetivo')
      ajena    = create_connection(name: 'Ajena')

      sign_in_with('Configurations_Connections_Update')
      patch "/api/connections/#{objetivo.id}",
            params: { Id: ajena.id, Name: 'Modificada' }, as: :json

      expect(objetivo.reload.name).to eq('Modificada')
      expect(ajena.reload.name).to eq('Ajena')
    end

    it 'deja intacto lo que el PATCH no menciona' do
      conn = create_connection(name: 'SAP Producción', sl_type: 'HANA')
      sign_in_with('Configurations_Connections_Update')

      patch "/api/connections/#{conn.id}", params: { Name: 'SAP Prod' }, as: :json

      expect(conn.reload).to have_attributes(
        name: 'SAP Prod', sl_url: 'https://sap.test:50000/b1s/v1', sl_type: 'HANA'
      )
    end

    it 'responde 404 si no existe' do
      sign_in_with('Configurations_Connections_Update')
      patch '/api/connections/999999', params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'responde 403 con el permiso de creación pero no el de actualización' do
      conn = create_connection(name: 'SAP Producción')
      sign_in_with('Configurations_Connections_Create')

      patch "/api/connections/#{conn.id}", params: { Name: 'Modificada' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(conn.reload.name).to eq('SAP Producción')
    end
  end

  describe 'GET /api/connections/assignable' do
    it 'devuelve el catálogo mínimo para el selector de compañías' do
      conn = create_connection(name: 'SAP Producción')

      sign_in(user)
      get '/api/connections/assignable'

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq([{ 'Id' => conn.id, 'Name' => 'SAP Producción' }])
    end

    # Preserva el comportamiento del .NET (`[Authorize]` sin permiso): quien
    # administra compañías necesita el selector aunque no administre conexiones.
    it 'no exige el permiso de conexiones' do
      create_connection(name: 'SAP Producción')

      sign_in(user)
      get '/api/connections/assignable'

      expect(response).to have_http_status(:ok)
    end

    it 'nunca expone la configuración, solo id y nombre' do
      create_connection(name: 'SAP Producción')

      sign_in(user)
      get '/api/connections/assignable'

      expect(body_data.first.keys).to contain_exactly('Id', 'Name')
    end

    it 'responde 401 sin sesión' do
      get '/api/connections/assignable'

      expect(response).to have_http_status(:unauthorized)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::SlResources', type: :request do
  let(:user)    { User.create!(email: 'recursos@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  # Deja al usuario con los permisos indicados y abre la sesión con `company`
  # activa. Los permisos de esta pantalla son `global`, pero se conceden por rol
  # igual que el resto (la vía directa es solo una alternativa, ver §28).
  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name, type: 'global'))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def create_resource(code:, resource: 'view.svc/CL_X_B1SLQuery', query_params: '$select=*',
                      page_size: 999, is_standard: true)
    SlResource.create!(code: code, description: "Consulta #{code}", resource: resource,
                       query_params: query_params, page_size: page_size, is_standard: is_standard)
  end

  describe 'GET /api/sl_resources' do
    it 'lista con el total real de la consulta, no el de la página' do
      3.times { |i| create_resource(code: "GetAlgo#{i}") }

      sign_in_with('Configurations_SlResources_Access')
      get '/api/sl_resources', params: { page: 1, per_page: 2 }

      expect(response).to have_http_status(:ok)
      expect(body_data['Items'].size).to eq(2)
      expect(body_data['Total']).to eq(3)
    end

    it 'filtra por código y por recurso, sin distinguir mayúsculas' do
      create_resource(code: 'GetSuppliers', resource: 'view.svc/CL_SUPPLIERS_B1SLQuery')
      create_resource(code: 'Drafts',       resource: 'Drafts')

      sign_in_with('Configurations_SlResources_Access')

      get '/api/sl_resources', params: { code: 'supp' }
      expect(body_data['Items'].map { |r| r['Code'] }).to eq(['GetSuppliers'])

      get '/api/sl_resources', params: { resource: 'drafts' }
      expect(body_data['Items'].map { |r| r['Code'] }).to eq(['Drafts'])
    end

    # Regresión: `sanitize_sql_like` escapa el `_` (que es comodín de LIKE) con
    # `\`, y sin cláusula `ESCAPE` la base lo trata como un carácter literal → 0
    # resultados. Se nota justo con estos nombres, que son todos guiones bajos.
    it 'encuentra por un fragmento con guiones bajos' do
      create_resource(code: 'GetSuppliers', resource: 'view.svc/CL_D_CL_MLT_SUPPLIERS_B1SLQuery')
      create_resource(code: 'Drafts',       resource: 'Drafts')

      sign_in_with('Configurations_SlResources_Access')
      get '/api/sl_resources', params: { resource: 'CL_D_CL' }

      expect(body_data['Items'].map { |r| r['Code'] }).to eq(['GetSuppliers'])
    end

    it 'trata los comodines de LIKE como texto, no como comodín' do
      create_resource(code: 'GetSuppliers')
      create_resource(code: 'Drafts')

      sign_in_with('Configurations_SlResources_Access')

      # `%` buscaría todo si no se escapara; acá no hay ningún código que lo tenga.
      get '/api/sl_resources', params: { code: '%' }
      expect(body_data['Total']).to eq(0)

      # `_` es "un carácter cualquiera" en LIKE: sin escapar, `D_afts` traería Drafts.
      get '/api/sl_resources', params: { code: 'D_afts' }
      expect(body_data['Total']).to eq(0)
    end

    describe 'filtro de tipo' do
      before do
        create_resource(code: 'Estandar',      is_standard: true)
        create_resource(code: 'Personalizada', is_standard: false)
        sign_in_with('Configurations_SlResources_Access')
      end

      it 'sin el parámetro devuelve las dos' do
        get '/api/sl_resources'
        expect(body_data['Items'].map { |r| r['Code'] }).to contain_exactly('Estandar', 'Personalizada')
      end

      # El caso que se rompe si el filtro se escribe con `present?`: `false` no es
      # "sin filtro". Ver el scope `search` del modelo.
      it 'is_standard=false devuelve SOLO las personalizadas' do
        get '/api/sl_resources', params: { is_standard: 'false' }
        expect(body_data['Items'].map { |r| r['Code'] }).to eq(['Personalizada'])
      end

      it 'is_standard=true devuelve solo las estándar' do
        get '/api/sl_resources', params: { is_standard: 'true' }
        expect(body_data['Items'].map { |r| r['Code'] }).to eq(['Estandar'])
      end

      it 'un valor que no es booleano se ignora en vez de tratarse como false' do
        get '/api/sl_resources', params: { is_standard: 'quizas' }
        expect(body_data['Items'].size).to eq(2)
      end
    end

    it 'expone quién actualizó y cuándo' do
      resource = create_resource(code: 'GetSuppliers')

      sign_in_with('Configurations_SlResources_Access')
      get '/api/sl_resources'

      item = body_data['Items'].first
      expect(item['UpdatedAt']).to eq(resource.reload.updated_at.iso8601)
      # Sembrada, nunca editada: `Auditable` solo llena `updated_by` en un UPDATE.
      expect(item['UpdatedBy']).to be_nil
    end

    it 'rechaza a quien no tiene el permiso de acceso' do
      sign_in_with('Configurations_Connections_Access')
      get '/api/sl_resources'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/sl_resources/:id' do
    it 'actualiza el recurso y la query, y deja la consulta como personalizada' do
      resource = create_resource(code: 'GetSuppliers')

      sign_in_with('Configurations_SlResources_Update')
      patch "/api/sl_resources/#{resource.id}",
            params: { Resource: 'view.svc/CL_OTRO_B1SLQuery',
                      QueryParams: '$filter=(CardCode eq @CardCode)&$top=1' }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(body_data['IsStandard']).to be(false)
      expect(body_data['QueryParams']).to eq('$filter=(CardCode eq @CardCode)&$top=1')

      resource.reload
      expect(resource.resource).to eq('view.svc/CL_OTRO_B1SLQuery')
      expect(resource.is_standard).to be(false)
      # `Auditable` registra el autor en el UPDATE.
      expect(resource.updated_by).to eq(user.email)
    end

    it 'no permite renombrar el código: es la llave con la que la app pide la consulta' do
      resource = create_resource(code: 'GetSuppliers')

      sign_in_with('Configurations_SlResources_Update')
      patch "/api/sl_resources/#{resource.id}",
            params: { Code: 'OtroCodigo', Resource: 'Drafts' }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(resource.reload.code).to eq('GetSuppliers')
    end

    it 'guarda la query en blanco como NULL' do
      resource = create_resource(code: 'GetSuppliers', query_params: '$select=*')

      sign_in_with('Configurations_SlResources_Update')
      patch "/api/sl_resources/#{resource.id}",
            params: { QueryParams: '' }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(resource.reload.query_params).to be_nil
    end

    it 'rechaza un recurso en blanco con el mensaje traducido' do
      resource = create_resource(code: 'GetSuppliers')

      sign_in_with('Configurations_SlResources_Update')
      patch "/api/sl_resources/#{resource.id}",
            params: { Resource: '' }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El recurso no puede estar en blanco')
    end

    it 'exige el permiso de actualización, no alcanza el de acceso' do
      resource = create_resource(code: 'GetSuppliers')

      sign_in_with('Configurations_SlResources_Access')
      patch "/api/sl_resources/#{resource.id}",
            params: { Resource: 'Drafts' }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:forbidden)
      expect(resource.reload.resource).not_to eq('Drafts')
    end

    it 'devuelve 404 cuando la consulta no existe' do
      sign_in_with('Configurations_SlResources_Update')
      patch '/api/sl_resources/999999',
            params: { Resource: 'Drafts' }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:not_found)
    end
  end
end

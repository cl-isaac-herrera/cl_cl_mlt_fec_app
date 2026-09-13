# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Branches', type: :request do
  let(:user)    { User.create!(email: 'sucursales@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def upsert_resource(code, resource:, query_params: nil)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: resource, query_params: query_params, page_size: 0, is_active: true)
    end
  end

  def sap_row(code: 1, number: 1, active: 'Y')
    {
      'Code' => code.to_s, 'U_SucursalNum' => number,
      'U_EmsrUbProvincia' => '1', 'U_EmsrUbCanton' => '01', 'U_EmsrUbDistrito' => '01',
      'U_EmsrUbBarrio' => 'Carmen', 'U_EmsrUbOtrasSenas' => '100 m norte',
      'U_EmsrTlfCodigoPais' => 506, 'U_EmsrTlfNumTelefono' => '22223333',
      'U_EmsrFaxCodigoPais' => 506, 'U_EmsrFaxNumTelefono' => nil,
      'U_EmsrCorreoElectronico' => 'sucursal@acme.cr',
      'U_Active' => active, 'U_Alias' => 'Central'
    }
  end

  def valid_payload(overrides = {})
    {
      SucursalNum: 2, EmsrUbProvincia: '1', EmsrUbCanton: '01', EmsrUbDistrito: '01',
      EmsrUbBarrio: 'Carmen', EmsrUbOtrasSenas: '100 m norte',
      EmsrTlfNumTelefono: '22223333', EmsrFaxNumTelefono: '',
      EmsrCorreoElectronico: 'sucursal@acme.cr', Active: true, Alias: 'Central'
    }.merge(overrides)
  end

  before do
    upsert_resource('getBranches', resource: 'U_CL_FEC_SUCURSALES',
                                   query_params: '$orderby=U_SucursalNum asc')
    upsert_resource('getBranchByCode', resource: 'U_CL_FEC_SUCURSALES(#Code#)')
    upsert_resource('createBranch', resource: 'U_CL_FEC_SUCURSALES')
    upsert_resource('updateBranch', resource: 'U_CL_FEC_SUCURSALES(#Code#)')

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    allow(Sap::UserClient).to receive(:for).and_return(client)
  end

  describe 'GET /api/branches' do
    it 'responde 401 sin sesión' do
      get '/api/branches'

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige S_Sucursal' do
      sign_in_with('Configurations_Branches_Create')
      get '/api/branches'

      expect(response).to have_http_status(:forbidden)
    end

    context 'con permiso' do
      before { sign_in_with('S_Sucursal') }

      it 'devuelve las sucursales que trae SAP, con HasMore en vez de Total' do
        allow(client).to receive(:get).and_return([sap_row(code: 3, number: 1)])

        get '/api/branches'

        expect(response).to have_http_status(:ok)
        expect(body_data['Items'].first).to include(
          'Code' => 3, 'SucursalNum' => 1, 'Alias' => 'Central', 'Active' => true
        )
        expect(body_data['HasMore']).to be(false)
        expect(body_data).not_to have_key('Total')
      end

      # El estado es un filtro más: sin él la pantalla ve activas e inactivas y
      # puede reactivar una sucursal dada de baja.
      it 'devuelve activas e inactivas cuando no se filtra por estado' do
        allow(client).to receive(:get).and_return([sap_row(code: 1, active: 'Y'),
                                                   sap_row(code: 2, active: 'N')])

        get '/api/branches'

        expect(body_data['Items'].map { |b| b['Active'] }).to eq([true, false])
        expect(client).to have_received(:get).with(satisfy { |path| !path.include?('U_Active') })
      end

      it 'traslada los filtros de la pantalla al $filter de SAP' do
        allow(client).to receive(:get).and_return([])

        get '/api/branches', params: { alias: 'Cen', provincia: '1', active: 'false' }

        expect(client).to have_received(:get).with(
          a_string_including("contains(U_Alias,'Cen')", "U_EmsrUbProvincia eq '1'", "U_Active eq 'N'")
        )
      end

      it 'pagina con $top/$skip' do
        allow(client).to receive(:get).and_return([])

        get '/api/branches', params: { page: 2, per_page: 5 }

        expect(client).to have_received(:get).with(a_string_including('$top=6', '$skip=5'))
      end

      it 'responde 422 cuando falta configuración de SAP' do
        allow(Sap::CompanyClient).to receive(:for)
          .and_raise(Sap::CompanyClient::MissingConfiguration, 'No tiene conexión de SAP asignada.')

        get '/api/branches'

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('No tiene conexión de SAP asignada.')
      end

      it 'responde 502 cuando el Service Layer falla' do
        allow(client).to receive(:get)
          .and_raise(Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error'))

        get '/api/branches'

        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end

  describe 'GET /api/branches/:id' do
    before { sign_in_with('S_Sucursal') }

    it 'lee la sucursal por su Code' do
      allow(client).to receive(:get).and_return(sap_row(code: 7, number: 3))

      get '/api/branches/7'

      expect(response).to have_http_status(:ok)
      expect(body_data).to include('Code' => 7, 'SucursalNum' => 3)
    end

    it 'responde 404 cuando el Code no existe' do
      allow(client).to receive(:get).and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('no existe'))

      get '/api/branches/99'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/branches' do
    it 'exige Configurations_Branches_Create' do
      sign_in_with('S_Sucursal')
      post '/api/branches', params: valid_payload

      expect(response).to have_http_status(:forbidden)
    end

    context 'con permiso' do
      before { sign_in_with('Configurations_Branches_Create') }

      it 'crea la sucursal y devuelve el Code que asignó SAP' do
        allow(client).to receive(:get).and_return([])           # el número está libre
        allow(client).to receive(:post).and_return({ 'Code' => '9' })

        post '/api/branches', params: valid_payload

        expect(response).to have_http_status(:created)
        expect(body_data['Code']).to eq(9)
        expect(client).to have_received(:post).with('U_CL_FEC_SUCURSALES', body: hash_including(
          'U_SucursalNum' => 2, 'U_Alias' => 'Central', 'U_Active' => 'Y'
        ))
      end

      # 506 fijo: el formulario no ofrece el país, así que aceptarlo del cuerpo
      # sería aceptar un dato que la pantalla no puede producir.
      it 'pone el código de país del teléfono y del fax, y no lo toma del cuerpo' do
        allow(client).to receive(:get).and_return([])
        allow(client).to receive(:post).and_return({ 'Code' => '9' })

        post '/api/branches', params: valid_payload(EmsrTlfCodigoPais: 1, EmsrFaxCodigoPais: 1)

        expect(client).to have_received(:post).with(anything, body: hash_including(
          'U_EmsrTlfCodigoPais' => 506, 'U_EmsrFaxCodigoPais' => 506
        ))
      end

      it 'responde 422 con el motivo cuando los datos no pasan la validación' do
        allow(client).to receive(:get).and_return([])
        allow(client).to receive(:post)

        post '/api/branches', params: valid_payload(Alias: '')

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('El alias es requerido.')
        expect(client).not_to have_received(:post)
      end

      it 'responde 422 cuando el número de sucursal ya existe' do
        allow(client).to receive(:get).and_return([sap_row(code: 4, number: 2)])
        allow(client).to receive(:post)

        post '/api/branches', params: valid_payload(SucursalNum: 2)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('Ya existe una sucursal con el número 2.')
      end

      # Las escrituras se atribuyen a la persona, no al usuario técnico de la
      # sincronización (ver la cabecera del controller).
      it 'escribe con las credenciales de SAP del usuario en sesión' do
        allow(client).to receive(:get).and_return([])
        allow(client).to receive(:post).and_return({ 'Code' => '9' })

        post '/api/branches', params: valid_payload

        expect(Sap::UserClient).to have_received(:for).with(company, user: user)
      end
    end
  end

  describe 'PATCH /api/branches/:id' do
    it 'exige Configurations_Branches_Update' do
      sign_in_with('Configurations_Branches_Create')
      patch '/api/branches/7', params: valid_payload

      expect(response).to have_http_status(:forbidden)
    end

    context 'con permiso' do
      before { sign_in_with('Configurations_Branches_Update') }

      it 'actualiza la sucursal del path' do
        allow(client).to receive(:get).and_return([])
        allow(client).to receive(:patch)

        patch '/api/branches/7', params: valid_payload(Active: false)

        expect(response).to have_http_status(:ok)
        expect(client).to have_received(:patch).with('U_CL_FEC_SUCURSALES(7)', body: hash_including(
          'U_Active' => 'N'
        ))
      end

      # El Code va en el path; el del cuerpo se ignora (§28).
      it 'ignora el Code que venga en el cuerpo' do
        allow(client).to receive(:get).and_return([])
        allow(client).to receive(:patch)

        patch '/api/branches/7', params: valid_payload(Code: 99)

        expect(client).to have_received(:patch).with('U_CL_FEC_SUCURSALES(7)', any_args)
      end
    end
  end

  describe 'compañía activa' do
    it 'responde 403 si la compañía de la sesión no está asignada al usuario' do
      UserRole.create!(user: user, role: role, company: company)
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: 'S_Sucursal'))
      sign_in(user, company: company)   # sin UsersByCompany

      get '/api/branches'

      expect(response).to have_http_status(:forbidden)
    end
  end
end

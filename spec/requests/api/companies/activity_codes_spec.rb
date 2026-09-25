# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Companies::ActivityCodes', type: :request do
  let(:user)    { User.create!(email: 'admin@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:acme)    { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  def sign_in_with(*permission_names)
    grant_permissions(user, *permission_names, company: acme)
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def upsert_resource(code, resource:, query_params: nil)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: resource, query_params: query_params, page_size: 0, is_active: true)
    end
  end

  def sap_row(code: 1, activity_code: '621004', active: 'Y', description: 'Comercio al por menor')
    {
      'Code' => code.to_s, 'U_ActivityCode' => activity_code, 'U_Description' => description,
      'U_CreatedAt' => '2026-09-01T10:00:00-06:00', 'U_CreatedBy' => 'seed@acme.cr',
      'U_UpdatedAt' => nil, 'U_UpdatedBy' => nil, 'U_Active' => active
    }
  end

  def valid_payload(overrides = {})
    { ActivityCode: '621005', Description: 'Venta de repuestos' }.merge(overrides)
  end

  before do
    upsert_resource('getActivityCodes', resource: 'U_CL_FEC_ACTIVITYCODE',
                                        query_params: '$orderby=U_ActivityCode asc')
    upsert_resource('getActivityCodeByCode', resource: 'U_CL_FEC_ACTIVITYCODE(#Code#)')
    upsert_resource('createActivityCode', resource: 'U_CL_FEC_ACTIVITYCODE')
    upsert_resource('updateActivityCode', resource: 'U_CL_FEC_ACTIVITYCODE(#Code#)')

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    allow(Sap::UserClient).to receive(:for).and_return(client)
  end

  describe 'GET /api/companies/:company_id/activity_codes' do
    it 'responde 401 sin sesión' do
      get "/api/companies/#{acme.id}/activity_codes"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Configurations_Companies_Update' do
      sign_in_with('Configurations_Companies_ListAccess')
      get "/api/companies/#{acme.id}/activity_codes"

      expect(response).to have_http_status(:forbidden)
    end

    # El alcance es el mismo de la lectura del formulario: sin "ver todas", una
    # compañía ajena no existe para este usuario, y por eso es 404 y no 403.
    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{ajena.id}/activity_codes"

      expect(response).to have_http_status(:not_found)
    end

    # Alcanza con el permiso de INSTALACIÓN (docs/PLAN-ROLES-POR-ALCANCE.md), sin
    # rol de compañía — necesita además `ViewAllApplicationCompanies` para que
    # `find_visible_company` encuentre una compañía a la que no está asignado.
    it 'también alcanza con Configurations_Companies_UpdateInAllCompanies (de instalación)' do
      allow(client).to receive(:get).and_return([])
      grant_permissions(user, 'Configurations_Companies_UpdateInAllCompanies',
                       'Configurations_Companies_ViewAllApplicationCompanies')
      sign_in(user, company: acme)

      get "/api/companies/#{acme.id}/activity_codes"

      expect(response).to have_http_status(:ok)
    end

    context 'con permiso' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'devuelve los códigos que trae SAP, con HasMore en vez de Total, y sin Active' do
        allow(client).to receive(:get).and_return([sap_row(code: 3, activity_code: '621004')])

        get "/api/companies/#{acme.id}/activity_codes"

        expect(response).to have_http_status(:ok)
        expect(body_data['Items'].first).to include('Code' => 3, 'ActivityCode' => '621004')
        expect(body_data['Items'].first).not_to have_key('Active')
        expect(body_data['HasMore']).to be(false)
        expect(body_data).not_to have_key('Total')
      end

      # No hay pantalla que muestre inactivos: la lista siempre filtra por
      # activo, no es algo que el request pueda pedir.
      it 'siempre filtra por Active = Y' do
        allow(client).to receive(:get).and_return([])

        get "/api/companies/#{acme.id}/activity_codes"

        expect(client).to have_received(:get).with(a_string_including("U_Active eq 'Y'"))
      end

      it 'lee las credenciales de LICENCIA de la conexión, no las del usuario' do
        allow(client).to receive(:get).and_return([])

        get "/api/companies/#{acme.id}/activity_codes"

        expect(Sap::CompanyClient).to have_received(:for).with(acme)
        expect(Sap::UserClient).not_to have_received(:for)
      end

      it 'responde 422 cuando falta configuración de SAP' do
        allow(Sap::CompanyClient).to receive(:for)
          .and_raise(Sap::CompanyClient::MissingConfiguration, 'No tiene conexión de SAP asignada.')

        get "/api/companies/#{acme.id}/activity_codes"

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('No tiene conexión de SAP asignada.')
      end

      it 'responde 502 cuando el Service Layer falla' do
        allow(client).to receive(:get)
          .and_raise(Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error'))

        get "/api/companies/#{acme.id}/activity_codes"

        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end

  describe 'GET /api/companies/:company_id/activity_codes/:id' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'lee el código por su Code' do
      allow(client).to receive(:get).and_return(sap_row(code: 7, activity_code: '621099'))

      get "/api/companies/#{acme.id}/activity_codes/7"

      expect(response).to have_http_status(:ok)
      expect(body_data).to include('Code' => 7, 'ActivityCode' => '621099')
    end

    it 'responde 404 cuando el Code no existe' do
      allow(client).to receive(:get).and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('no existe'))

      get "/api/companies/#{acme.id}/activity_codes/99"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/companies/:company_id/activity_codes' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'crea el código y devuelve el Code que asignó SAP' do
      allow(client).to receive(:get).and_return([])           # el código no existe, ni activo ni inactivo
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      post "/api/companies/#{acme.id}/activity_codes", params: valid_payload

      expect(response).to have_http_status(:created)
      expect(body_data['Code']).to eq(9)
      expect(client).to have_received(:post).with('U_CL_FEC_ACTIVITYCODE', body: hash_including(
        'U_ActivityCode' => '621005', 'U_Description' => 'Venta de repuestos', 'U_Active' => 'Y'
      ))
    end

    it 'responde 422 con el motivo cuando los datos no pasan la validación' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:post)

      post "/api/companies/#{acme.id}/activity_codes", params: valid_payload(ActivityCode: '')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El código de actividad es requerido.')
      expect(client).not_to have_received(:post)
    end

    it 'responde 422 cuando el código de actividad ya existe activo' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, activity_code: '621005', active: 'Y')])
      allow(client).to receive(:post)

      post "/api/companies/#{acme.id}/activity_codes", params: valid_payload(ActivityCode: '621005')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Ya existe un código de actividad activo con el valor 621005.')
    end

    # El corazón de la regla de negocio: dar de alta un código eliminado antes
    # (inactivo) lo reactiva en vez de crear una fila nueva.
    it 'reactiva un código inactivo con el mismo valor en vez de crear uno nuevo' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, activity_code: '621005', active: 'N')])
      allow(client).to receive(:patch)
      allow(client).to receive(:post)

      post "/api/companies/#{acme.id}/activity_codes",
           params: valid_payload(ActivityCode: '621005', Description: 'Reactivado')

      expect(response).to have_http_status(:created)
      expect(body_data['Code']).to eq(4)
      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(4)', body: hash_including(
        'U_Description' => 'Reactivado', 'U_Active' => 'Y'
      ))
      expect(client).not_to have_received(:post)
    end

    # Las escrituras se atribuyen a la persona, no al usuario técnico de la
    # sincronización (mismo criterio que `Api::BranchesController`).
    it 'escribe con las credenciales de SAP del usuario en sesión' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      post "/api/companies/#{acme.id}/activity_codes", params: valid_payload

      expect(Sap::UserClient).to have_received(:for).with(acme, user: user)
    end
  end

  describe 'PATCH /api/companies/:company_id/activity_codes/:id' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'actualiza el código y la descripción del path' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:patch)

      patch "/api/companies/#{acme.id}/activity_codes/7", params: valid_payload(Description: 'Nueva descripción')

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(7)', body: hash_including(
        'U_Description' => 'Nueva descripción', 'U_Active' => 'Y'
      ))
    end

    # El Code va en el path; el del cuerpo se ignora (§28).
    it 'ignora el Code que venga en el cuerpo' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:patch)

      patch "/api/companies/#{acme.id}/activity_codes/7", params: valid_payload(Code: 99)

      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(7)', any_args)
    end

    it 'responde 404 cuando el Code no existe' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:patch).and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('no existe'))

      patch "/api/companies/#{acme.id}/activity_codes/99", params: valid_payload

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /api/companies/:company_id/activity_codes/:id/deactivate' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'inactiva el código: el "eliminar" de la pantalla' do
      allow(client).to receive(:patch)

      patch "/api/companies/#{acme.id}/activity_codes/7/deactivate"

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(7)', body: hash_including('U_Active' => 'N'))
    end

    it 'responde 404 cuando el Code no existe' do
      allow(client).to receive(:patch).and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('no existe'))

      patch "/api/companies/#{acme.id}/activity_codes/99/deactivate"

      expect(response).to have_http_status(:not_found)
    end

    # Misma atribución que crear/editar: quien hizo el cambio, no el usuario
    # técnico de la sincronización.
    it 'escribe con las credenciales de SAP del usuario en sesión' do
      allow(client).to receive(:patch)

      patch "/api/companies/#{acme.id}/activity_codes/7/deactivate"

      expect(Sap::UserClient).to have_received(:for).with(acme, user: user)
    end
  end
end

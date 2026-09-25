# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Companies::LegalDataController', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }
  let(:sap)  { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) do
    Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME',
                    issuer_id_number: '3101822733')
  end

  # El bloque del emisor (`EmsrNombre`, `EmsrIdeTipo`, `CodigoActividad`,
  # `EmsrRegistroFiscal8707`) vive en la UDT `@CL_FEC_ISSUERCONFIG`
  # (`Sap::CompanyConfig`): el `GET` lo lee con `Sap::CompanyClient` y el
  # `PATCH` lo escribe con `Sap::UserClient` (quien edita, no la licencia) y
  # lo relee con `Sap::CompanyClient` para la respuesta — es la única de las
  # cuatro secciones migradas cuya LECTURA también depende del Service Layer.
  let(:sap_client) { instance_double(Clavisco::ServiceLayer::Client) }

  before do
    allow(Sap::CompanyClient).to receive(:for).and_return(sap_client)
    allow(Sap::UserClient).to receive(:for).and_return(sap_client)
    allow(sap_client).to receive(:get).and_return(nil)
    allow(sap_client).to receive(:patch)
  end

  # Las seis claves de la sección. Son el contrato entre el `GET` y el `PATCH`
  # de este mismo controller: si una se agrega en un lado y no en el otro, el
  # formulario muestra un campo que el guardado ignora y el usuario no se
  # entera.
  LEGAL_DATA_KEYS = %w[
    Name EmsrNombre EmsrIdeTipo EmsrIdeNumero CodigoActividad EmsrRegistroFiscal8707
  ].freeze

  def sign_in_with(*permission_names)
    grant_permissions(user, *permission_names, company: acme)
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def get_section
    get "/api/companies/#{acme.id}/legal_data"
  end

  def patch_section(payload)
    patch "/api/companies/#{acme.id}/legal_data", params: payload, as: :json
  end

  describe 'GET /api/companies/:company_id/legal_data' do
    describe 'autorización' do
      it 'responde 401 sin sesión' do
        get_section

        expect(response).to have_http_status(:unauthorized)
      end

      it 'exige Configurations_Companies_Update' do
        sign_in_with('Configurations_Companies_ListAccess')

        get_section

        expect(response).to have_http_status(:forbidden)
      end

      it 'también alcanza con Configurations_Companies_UpdateInAllCompanies (de instalación)' do
        grant_permissions(user, 'Configurations_Companies_UpdateInAllCompanies',
                         'Configurations_Companies_ViewAllApplicationCompanies')
        sign_in(user, company: acme)

        get_section

        expect(response).to have_http_status(:ok)
      end

      it 'responde 404 con un id que no existe' do
        sign_in_with('Configurations_Companies_Update')

        get '/api/companies/999999/legal_data'

        expect(response).to have_http_status(:not_found)
      end

      it 'responde 404 con una compañía fuera de su alcance' do
        ajena = Company.create!(name: 'Ajena S.A.')
        sign_in_with('Configurations_Companies_Update')

        get "/api/companies/#{ajena.id}/legal_data"

        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'lectura' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'lee el bloque del emisor de SAP con el cliente de la compañía' do
        get_section

        expect(response).to have_http_status(:ok)
        expect(Sap::CompanyClient).to have_received(:for).with(acme)
      end

      it 'devuelve las seis claves de la sección' do
        get_section

        expect(body_data.keys).to match_array(LEGAL_DATA_KEYS)
      end

      it 'devuelve el espejo local (Name, EmsrIdeNumero) junto con el bloque de SAP' do
        get_section

        expect(body_data).to include('Name' => 'ACME S.A.', 'EmsrIdeNumero' => '3101822733')
      end

      # Mismo criterio que `Api::CompaniesController#show`: sin configuración de
      # SAP, 422 en vez de un formulario a medias.
      it 'responde 422 si falta configuración de SAP' do
        allow(Sap::CompanyClient).to receive(:for)
          .and_raise(Sap::CompanyClient::MissingConfiguration, 'La compañía no tiene una conexión de SAP asignada.')

        get_section

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'responde 502 si el Service Layer falla' do
        error = Clavisco::ServiceLayer::Client::ServiceLayerError.new('boom')
        allow(sap_client).to receive(:get).and_raise(error)

        get_section

        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end

  describe 'PATCH /api/companies/:company_id/legal_data' do
    describe 'autorización' do
      it 'responde 401 sin sesión' do
        patch "/api/companies/#{acme.id}/legal_data", params: { Name: 'X' }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'exige Configurations_Companies_Update' do
        sign_in_with('Configurations_Companies_ListAccess')

        patch_section(Name: 'X')

        expect(response).to have_http_status(:forbidden)
        expect(acme.reload.name).to eq('ACME S.A.')
      end

      # Alcanza con el permiso de INSTALACIÓN (docs/PLAN-ROLES-POR-ALCANCE.md), sin
      # que el usuario tenga rol de compañía ni esté asignado a `acme` — de ahí
      # que también necesite `ViewAllApplicationCompanies` para que
      # `find_visible_company` la encuentre.
      it 'también alcanza con Configurations_Companies_UpdateInAllCompanies (de instalación)' do
        grant_permissions(user, 'Configurations_Companies_UpdateInAllCompanies',
                         'Configurations_Companies_ViewAllApplicationCompanies')
        sign_in(user, company: acme)

        patch_section(Name: 'Actualizada por instalación')

        expect(response).to have_http_status(:ok)
        expect(acme.reload.name).to eq('Actualizada por instalación')
      end

      it 'responde 404 con un id que no existe' do
        sign_in_with('Configurations_Companies_Update')

        patch '/api/companies/999999/legal_data', params: { Name: 'X' }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      # El alcance es el mismo de la lectura: sin "ver todas", una compañía ajena no
      # existe para este usuario, y por eso es 404 y no 403.
      it 'responde 404 con una compañía fuera de su alcance' do
        ajena = Company.create!(name: 'Ajena S.A.')
        sign_in_with('Configurations_Companies_Update')

        patch "/api/companies/#{ajena.id}/legal_data", params: { Name: 'X' }, as: :json

        expect(response).to have_http_status(:not_found)
        expect(ajena.reload.name).to eq('Ajena S.A.')
      end
    end

    describe 'guardado' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'actualiza los campos de la sección' do
        patch_section(
          Name: 'ACME Global', EmsrNombre: 'ACME Global S.A.',
          EmsrIdeTipo: '01', EmsrIdeNumero: '123456789', CodigoActividad: '620100',
          EmsrRegistroFiscal8707: '999'
        )

        expect(response).to have_http_status(:ok)
        expect(acme.reload).to have_attributes(name: 'ACME Global', issuer_id_number: '123456789')
      end

      # El bloque del emisor ya no es columna de `companies`: se escribe en la
      # UDT `@CL_FEC_ISSUERCONFIG`, atribuido a quien edita (`Sap::UserClient`).
      it 'escribe el bloque del emisor en SAP, atribuido a quien edita' do
        patch_section(EmsrNombre: 'ACME Global S.A.', EmsrIdeTipo: '01',
                      CodigoActividad: '620100', EmsrRegistroFiscal8707: '999')

        expect(response).to have_http_status(:ok)
        expect(Sap::UserClient).to have_received(:for).with(acme, user: user)
        expect(sap_client).to have_received(:patch).with(
          'U_CL_FEC_ISSUERCONFIG(1)',
          body: hash_including('U_LegalName' => 'ACME Global S.A.', 'U_IdType' => '01',
                                'U_EconomicActivityCode' => '620100', 'U_TaxRegistry8707' => '999')
        )
      end

      it 'devuelve la sección como quedó guardada, con el mensaje' do
        patch_section(Name: '  ACME Global  ')

        expect(body_data['Name']).to eq('ACME Global')
        expect(body['Message']).to eq('Datos legales actualizados con éxito.')
      end

      it 'no borra lo que la petición no mencionó' do
        patch_section(Name: 'ACME Global')

        expect(acme.reload).to have_attributes(issuer_id_number: '3101822733')
        # `Name` es parte del bloque del emisor (la UDT es la fuente, `companies`
        # el espejo): se manda SOLO él, sin pisar en SAP lo que no vino.
        expect(sap_client).to have_received(:patch) do |_path, body:|
          expect(body.keys - %w[U_UpdatedAt U_UpdatedBy]).to eq(%w[U_CommercialName])
          expect(body['U_CommercialName']).to eq('ACME Global')
        end
      end

      it 'no habla con SAP si no vino nada del bloque del emisor' do
        # Ningún campo de esta sección: un PATCH vacío no tiene nada que escribir.
        patch_section({})

        expect(sap_client).not_to have_received(:patch)
      end

      # La UDT es la fuente del nombre comercial y la cédula; `companies` guarda
      # el espejo para el listado, las rutas de disco y el correo entrante.
      it 'escribe el nombre comercial y la cédula en los dos lados' do
        patch_section(Name: 'ACME Global', EmsrIdeNumero: '123456789')

        expect(acme.reload).to have_attributes(name: 'ACME Global', issuer_id_number: '123456789')
        expect(sap_client).to have_received(:patch).with(
          'U_CL_FEC_ISSUERCONFIG(1)',
          body: hash_including('U_CommercialName' => 'ACME Global', 'U_IdNumber' => '123456789')
        )
      end

      # Vacío y NULL son la misma cosa para el negocio; tener las dos
      # representaciones obliga a preguntar por ambas en cada consulta.
      it 'guarda un campo de texto vacío como NULL en SAP' do
        patch_section(EmsrRegistroFiscal8707: '   ')

        expect(sap_client).to have_received(:patch).with(
          'U_CL_FEC_ISSUERCONFIG(1)', body: hash_including('U_TaxRegistry8707' => nil)
        )
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
          # Sección "Datos Generales"
          SapDb: 'SBO_OTRA', ConnectionId: 999_999,
          # Sección "Hacienda (ATV)"
          CertPin: '9999', TokenUsr: 'atv', CertPath: 'C:\\otro.p12',
          # Ni una columna que no existe
          Uuid: 'reescrito'
        )

        expect(response).to have_http_status(:ok)
        expect(acme.reload).to have_attributes(
          name: 'ACME Global',
          sap_db: 'SBO_ACME',
          cert_pin: nil,
          token_user: nil
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

      # `Sap::CompanyConfig` valida el catálogo antes de escribir nada en SAP —
      # `sap_client.patch` no llega a ejecutarse.
      it 'rechaza un tipo de identificación que Hacienda no define' do
        patch_section(EmsrIdeTipo: '99')

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('El tipo de identificación no es válido.')
        expect(sap_client).not_to have_received(:patch)
      end

      it 'rechaza una razón social más larga que el límite de la UDT' do
        patch_section(EmsrNombre: 'A' * 101)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('La razón social no puede tener más de 100 caracteres.')
        expect(sap_client).not_to have_received(:patch)
      end
    end

    # El PATCH acepta y devuelve las mismas seis claves que el `GET`. No es
    # automático —la lista de arriba se mantiene a mano— pero deja el contrato
    # en un solo lugar y falla si alguno de los dos lados deja de exponer un
    # campo (ver también "lectura" en el describe del `GET`, más arriba).
    describe 'contrato con la lectura' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'acepta y devuelve las mismas seis claves que el GET' do
        payload = {
          'Name' => 'ACME Global', 'EmsrNombre' => 'ACME Global S.A.', 'EmsrIdeTipo' => '01',
          'EmsrIdeNumero' => '123456789', 'CodigoActividad' => '620100',
          'EmsrRegistroFiscal8707' => '999'
        }
        # El payload de este ejemplo tampoco puede quedarse corto respecto a la lista.
        expect(payload.keys).to match_array(LEGAL_DATA_KEYS)

        patch_section(payload)

        expect(response).to have_http_status(:ok)
        expect(body_data.keys).to match_array(LEGAL_DATA_KEYS)
      end
    end
  end
end

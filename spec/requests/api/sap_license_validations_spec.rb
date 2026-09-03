# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/sap_license_validations', type: :request do
  let(:user)    { User.create!(email: 'conexiones@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  let(:connection) do
    Connection.create!(name: 'SAP Producción', sl_url: 'https://sap.test:50000/b1s/v1',
                       sap_license: 'licencia', sap_license_password: 'guardada')
  end

  let(:login_url) { 'https://sap.test:50000/b1s/v1/Login' }
  let(:probe_url) { %r{\Ahttps://sap\.test:50000/b1s/v1/BusinessPartners} }

  def body = JSON.parse(response.body)

  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  # El pool de sesiones del Client es un singleton que sobrevive entre ejemplos:
  # sin limpiarlo, el segundo ejemplo reusaría la sesión del primero y no volvería
  # a pedir /Login, que es justamente lo que se está probando.
  before do
    Clavisco::ServiceLayer::LoadBalancer.instance.instance_variable_set(:@sessions, {})

    # El recurso del sondeo sale del catálogo (`sl_resources`), no del código.
    SlResource.create!(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                       query_params: '$top=1&$select=CardCode', page_size: 0, is_standard: true)

    # La sesión del sondeo es desechable y se cierra al terminar. Ver
    # `Sap::CredentialValidator#discard_session!`.
    stub_request(:post, %r{/b1s/v1/Logout\z}).to_return(status: 204)
  end

  def stub_login(user_name:, password:, company_db: 'SBO_ACME')
    stub_request(:post, login_url)
      .with(body: { CompanyDB: company_db, UserName: user_name, Password: password }.to_json)
      .to_return(status: 200, body: { SessionId: 'abc' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def stub_probe
    stub_request(:get, probe_url).to_return(status: 200, body: { value: [] }.to_json,
                                            headers: { 'Content-Type' => 'application/json' })
  end

  # Es el caso del panel de creación: la conexión todavía no existe, así que todo
  # lo que se prueba viene del formulario.
  it 'prueba las credenciales del cuerpo sin necesidad de una conexión guardada' do
    login = stub_login(user_name: 'licencia', password: 'secreto')
    stub_probe

    sign_in_with('Configurations_Connections_Create')
    post '/api/sap_license_validations',
         params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                   SapLicensePassword: 'secreto', CompanyDb: 'SBO_ACME' },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(true)
    expect(login).to have_been_requested
  end

  # Credenciales inválidas no son un error de la petición: 200 con Data false y el
  # motivo de SAP en Message, igual que /api/sap_credential_validations.
  it 'devuelve Data false con el motivo de SAP cuando rechaza el login' do
    stub_request(:post, login_url).to_return(
      status: 401,
      body: { error: { code: -304, message: { lang: 'en-us', value: 'Invalid user or password' } } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    sign_in_with('Configurations_Connections_Create')
    post '/api/sap_license_validations',
         params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                   SapLicensePassword: 'mala', CompanyDb: 'SBO_ACME' },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(false)
    expect(body['Message']).to include('Invalid user or password')
  end

  # El servidor nunca devuelve la contraseña, así que el formulario carga el campo
  # en blanco: exigirla obligaría a reescribirla solo para poder probar la URL.
  it 'usa la contraseña guardada cuando el cuerpo la manda en blanco' do
    login = stub_login(user_name: 'licencia', password: 'guardada')
    stub_probe

    sign_in_with('Configurations_Connections_Update')
    post '/api/sap_license_validations',
         params: { ConnectionId: connection.id, SlUrl: connection.sl_url,
                   SapLicense: 'licencia', SapLicensePassword: '', CompanyDb: 'SBO_ACME' },
         as: :json

    expect(body['Data']).to be(true)
    expect(login).to have_been_requested
  end

  # Lo que se prueba es lo que está en el formulario: si se probara lo guardado,
  # el botón diría "verificadas" sobre una contraseña que no es la que se va a
  # guardar.
  it 'prefiere la contraseña del cuerpo sobre la guardada' do
    nueva = stub_login(user_name: 'licencia', password: 'nueva')
    stub_probe

    sign_in_with('Configurations_Connections_Update')
    post '/api/sap_license_validations',
         params: { ConnectionId: connection.id, SlUrl: connection.sl_url,
                   SapLicense: 'licencia', SapLicensePassword: 'nueva', CompanyDb: 'SBO_ACME' },
         as: :json

    expect(body['Data']).to be(true)
    expect(nueva).to have_been_requested
  end

  describe 'prerequisitos' do
    it 'pide la base de datos sin llamar a SAP' do
      sign_in_with('Configurations_Connections_Create')
      post '/api/sap_license_validations',
           params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                     SapLicensePassword: 'secreto', CompanyDb: '' },
           as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to eq('Indique la base de datos de SAP contra la que probar.')
      expect(a_request(:post, login_url)).not_to have_been_made
    end

    it 'pide la URL apuntando al campo del formulario, no a una compañía' do
      sign_in_with('Configurations_Connections_Create')
      post '/api/sap_license_validations',
           params: { SlUrl: '', SapLicense: 'licencia',
                     SapLicensePassword: 'secreto', CompanyDb: 'SBO_ACME' },
           as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to eq('Ingrese la URL del Service Layer antes de probar.')
    end

    # Al crear no hay contraseña guardada de la que echar mano.
    it 'pide la contraseña cuando no hay conexión ni valor en el cuerpo' do
      sign_in_with('Configurations_Connections_Create')
      post '/api/sap_license_validations',
           params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                     SapLicensePassword: '', CompanyDb: 'SBO_ACME' },
           as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to eq('Ingrese el usuario y la contraseña de SAP.')
    end
  end

  describe 'autorización' do
    # Los dos permisos autorizan por separado: el botón está en el panel de
    # creación y en el de edición.
    it 'acepta el permiso de actualización' do
      stub_login(user_name: 'licencia', password: 'secreto')
      stub_probe

      sign_in_with('Configurations_Connections_Update')
      post '/api/sap_license_validations',
           params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                     SapLicensePassword: 'secreto', CompanyDb: 'SBO_ACME' },
           as: :json

      expect(response).to have_http_status(:ok)
    end

    # El endpoint recibe una contraseña y la manda a un servidor que indica el
    # cuerpo: con solo el permiso de lectura sería un oráculo para probar
    # credenciales contra cualquier host.
    it 'responde 403 con el permiso de solo lectura' do
      sign_in_with('Configurations_Connections_Access')
      post '/api/sap_license_validations',
           params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                     SapLicensePassword: 'secreto', CompanyDb: 'SBO_ACME' },
           as: :json

      expect(response).to have_http_status(:forbidden)
      expect(a_request(:post, login_url)).not_to have_been_made
    end

    it 'responde 401 sin sesión' do
      post '/api/sap_license_validations',
           params: { SlUrl: 'https://sap.test:50000/b1s/v1', SapLicense: 'licencia',
                     SapLicensePassword: 'secreto', CompanyDb: 'SBO_ACME' },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end

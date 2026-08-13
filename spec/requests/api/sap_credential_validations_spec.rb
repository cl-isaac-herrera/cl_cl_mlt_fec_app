# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/sap_credential_validations', type: :request do
  let(:user) { User.create!(email: 'sap@example.com') }
  let(:sap)  { Connection.create!(name: 'SAP Producción', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db_code: 'SBO_ACME') }

  let(:login_url) { 'https://sap.test:50000/b1s/v1/Login' }
  let(:probe_url) { %r{\Ahttps://sap\.test:50000/b1s/v1/BusinessPartners} }

  let(:credentials) { { SapUser: 'manager', SapPass: 'secreto', CompanyId: acme.id } }

  def body = JSON.parse(response.body)

  # El pool de sesiones del Client es un singleton que sobrevive entre ejemplos: sin
  # limpiarlo, el segundo ejemplo reusaría la sesión del primero y no volvería a
  # pedir /Login, que es justamente lo que se está probando.
  before do
    Clavisco::ServiceLayer::LoadBalancer.instance.instance_variable_set(:@sessions, {})
    UsersByCompany.create!(user: user, company: acme)
  end

  def stub_successful_login
    stub_request(:post, login_url)
      .with(body: { CompanyDB: 'SBO_ACME', UserName: 'manager', Password: 'secreto' }.to_json)
      .to_return(status: 200, body: { SessionId: 'abc' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  it 'devuelve Data true cuando el Service Layer acepta el login' do
    stub_successful_login
    stub_request(:get, probe_url).to_return(status: 200, body: { value: [] }.to_json,
                                            headers: { 'Content-Type' => 'application/json' })

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials, as: :json

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(true)
  end

  it 'devuelve Data false con el mensaje de SAP cuando rechaza las credenciales' do
    stub_request(:post, login_url).to_return(
      status: 401,
      body: { error: { code: -304, message: { lang: 'en-us', value: 'Invalid user or password' } } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(false)
    # Sin el prefijo del cliente: al usuario le sirve el motivo de SAP.
    expect(body['Message']).to eq('Invalid user or password')
  end

  # El login es lo único que se está probando. Que el recurso de prueba falle
  # después (permisos del usuario dentro de SAP) no invalida las credenciales.
  it 'devuelve Data true si el login funciona aunque el recurso de prueba falle' do
    stub_successful_login
    stub_request(:get, probe_url).to_return(
      status: 403,
      body: { error: { code: -1, message: { value: 'No authorization' } } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials

    expect(body['Data']).to be(true)
  end

  it 'devuelve Data false cuando el Service Layer no responde, sin reventar' do
    stub_request(:post, login_url).to_timeout

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(false)
    expect(body['Message']).to include('No se pudo contactar')
  end

  it 'no llama a SAP si la compañía no tiene conexión configurada' do
    sin_conexion = Company.create!(name: 'Sin SAP')
    UsersByCompany.create!(user: user, company: sin_conexion)

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials.merge(CompanyId: sin_conexion.id)

    expect(body['Data']).to be(false)
    expect(body['Message']).to include('conexión SAP')
    expect(a_request(:post, login_url)).not_to have_been_made
  end

  it 'responde 403 si la compañía no está asignada al usuario' do
    ajena = Company.create!(name: 'Ajena S.A.', sap_connection: sap, sap_db_code: 'SBO_AJENA')

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials.merge(CompanyId: ajena.id)

    expect(response).to have_http_status(:forbidden)
    expect(a_request(:post, login_url)).not_to have_been_made
  end

  it 'responde 401 sin sesión' do
    post '/api/sap_credential_validations', params: credentials

    expect(response).to have_http_status(:unauthorized)
  end

  # Con `UserId` las credenciales son de OTRO usuario: es la pantalla de usuarios
  # probando las de alguien más, y eso ya es administrar usuarios.
  describe 'probando las credenciales de otro usuario' do
    let(:target) { User.create!(email: 'objetivo@example.com') }
    let(:role)   { Role.create!(name: 'Configurador') }

    def grant(*names)
      UserRole.create!(user: user, role: role, company: acme)
      names.each { |n| RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: n)) }
    end

    it 'exige Configurations_Users_Update' do
      UsersByCompany.create!(user: target, company: acme)
      grant('Configurations_Users_ListAccess')

      sign_in(user, company: acme)
      post '/api/sap_credential_validations', params: credentials.merge(UserId: target.id), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(a_request(:post, login_url)).not_to have_been_made
    end

    it 'valida contra la compañía del usuario objetivo y no la del administrador' do
      UsersByCompany.create!(user: target, company: acme)
      grant('Configurations_Users_Update')
      stub_successful_login
      stub_request(:get, probe_url).to_return(status: 200, body: { value: [] }.to_json,
                                              headers: { 'Content-Type' => 'application/json' })

      sign_in(user, company: acme)
      post '/api/sap_credential_validations', params: credentials.merge(UserId: target.id), as: :json

      expect(response).to have_http_status(:ok)
      expect(body['Data']).to be(true)
    end

    # El administrador sí tiene la compañía asignada, el objetivo no: probar ahí no
    # prueba nada, porque el usuario no va a operar nunca contra esa base.
    it 'rechaza una compañía que el administrador tiene pero el objetivo no' do
      grant('Configurations_Users_Update')

      sign_in(user, company: acme)
      post '/api/sap_credential_validations', params: credentials.merge(UserId: target.id), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(a_request(:post, login_url)).not_to have_been_made
    end

    it 'responde 404 cuando el usuario objetivo no existe' do
      grant('Configurations_Users_Update')

      sign_in(user, company: acme)
      post '/api/sap_credential_validations', params: credentials.merge(UserId: 999_999), as: :json

      expect(response).to have_http_status(:not_found)
    end

    # Mandar el propio id es el mismo caso que no mandarlo: no necesita permiso.
    it 'no exige permiso cuando el UserId es el del propio usuario' do
      stub_successful_login
      stub_request(:get, probe_url).to_return(status: 200, body: { value: [] }.to_json,
                                              headers: { 'Content-Type' => 'application/json' })

      sign_in(user)
      post '/api/sap_credential_validations', params: credentials.merge(UserId: user.id), as: :json

      expect(response).to have_http_status(:ok)
      expect(body['Data']).to be(true)
    end
  end
end

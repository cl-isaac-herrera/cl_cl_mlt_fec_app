# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/sap_credential_validations', type: :request do
  let(:user) { User.create!(email: 'sap@example.com') }
  let(:sap)  { Connection.create!(name: 'SAP Producción', service_layer_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db_code: 'SBO_ACME') }

  let(:login_url)  { 'https://sap.test:50000/b1s/v1/Login' }
  let(:logout_url) { 'https://sap.test:50000/b1s/v1/Logout' }

  let(:credentials) { { SapUser: 'manager', SapPass: 'secreto', CompanyId: acme.id } }

  def body = JSON.parse(response.body)

  before { UsersByCompany.create!(user: user, company: acme) }

  it 'devuelve Data true cuando el Service Layer acepta el login' do
    stub_request(:post, login_url)
      .with(body: { CompanyDB: 'SBO_ACME', UserName: 'manager', Password: 'secreto' }.to_json)
      .to_return(status: 200, body: { SessionId: 'abc' }.to_json, headers: { 'Set-Cookie' => 'B1SESSION=abc' })
    stub_request(:post, logout_url)

    sign_in(user)
    # Cuerpo JSON, tal como lo manda la pantalla.
    post '/api/sap_credential_validations', params: credentials, as: :json

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(true)
  end

  it 'cierra la sesión de SAP que abrió para validar' do
    stub_request(:post, login_url)
      .to_return(status: 200, body: '{}', headers: { 'Set-Cookie' => 'B1SESSION=abc' })
    logout = stub_request(:post, logout_url).with(headers: { 'Cookie' => 'B1SESSION=abc' })

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials

    expect(logout).to have_been_requested
  end

  it 'devuelve Data false con el mensaje OData cuando SAP rechaza las credenciales' do
    stub_request(:post, login_url).to_return(
      status: 401,
      body: { error: { code: -304, message: { lang: 'en-us', value: 'Invalid user or password' } } }.to_json
    )

    sign_in(user)
    post '/api/sap_credential_validations', params: credentials

    expect(response).to have_http_status(:ok)
    expect(body['Data']).to be(false)
    expect(body['Message']).to eq('Invalid user or password')
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
end

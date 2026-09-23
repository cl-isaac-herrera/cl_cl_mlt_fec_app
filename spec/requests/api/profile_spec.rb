# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Profiles', type: :request do
  let(:user) do
    User.create!(email: 'perfil@example.com', name: 'Ana Pérez', sap_user: 'manager',
                 sap_password: 'secreto')
  end

  def body = JSON.parse(response.body)

  describe 'GET /api/profile' do
    it 'devuelve el perfil del usuario de la sesión' do
      sign_in(user)
      get '/api/profile'

      expect(response).to have_http_status(:ok)
      expect(body['Data']).to include(
        'Id' => user.id, 'Name' => 'Ana Pérez', 'Email' => 'perfil@example.com',
        'SapUser' => 'manager'
      )
      expect(body['Data']).not_to have_key('DocNumberPreference')
    end

    it 'nunca expone la contraseña de SAP, solo si existe' do
      sign_in(user)
      get '/api/profile'

      expect(body['Data']).to include('HasSapPassword' => true)
      expect(response.body).not_to include('secreto')
    end

    it 'respeta el contrato ApiResponse' do
      sign_in(user)
      get '/api/profile'

      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body['Code']).to eq(200)
    end

    it 'responde 401 sin sesión' do
      get '/api/profile'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'PATCH /api/profile' do
    # Tal como lo manda la pantalla: cuerpo JSON, no form-encoded.
    it 'actualiza nombre, usuario y contraseña del usuario en sesión' do
      sign_in(user)
      patch '/api/profile',
            params: { Name: '  Ana María Pérez ', SapUser: 'nuevo', SapPass: 'otra-clave' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(
        name: 'Ana María Pérez', sap_user: 'nuevo', sap_password: 'otra-clave'
      )
    end

    it 'no toca el nombre si no viene en el cuerpo' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'nuevo' }, as: :json

      expect(user.reload.name).to eq('Ana Pérez')
    end

    it 'rechaza un nombre que excede el largo de la columna' do
      sign_in(user)
      patch '/api/profile', params: { Name: 'x' * 151 }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.name).to eq('Ana Pérez')
    end

    it 'deja la contraseña intacta cuando llega vacía' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: '' }

      expect(user.reload.sap_password).to eq('secreto')
    end

    it 'guarda la contraseña de SAP cifrada en la base' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: 'otra-clave' }

      raw = User.connection.select_value("SELECT sap_password FROM users WHERE id = #{user.id}")
      expect(raw).not_to include('otra-clave')
      expect(user.reload.sap_password).to eq('otra-clave')
    end

    # El log escribía `"SapPass"=>"@Moises..."` en claro en cada request: cifrar la
    # columna no sirve de nada si el mismo valor queda escrito en log/*.log.
    it 'no deja la contraseña de SAP en los logs' do
      filtered = ActiveSupport::ParameterFilter
                 .new(Rails.application.config.filter_parameters)
                 .filter('SapPass' => 'otra-clave', 'SapUser' => 'manager')

      expect(filtered['SapPass']).to eq('[FILTERED]')
      # El usuario no es secreto: se sigue viendo para poder diagnosticar.
      expect(filtered['SapUser']).to eq('manager')
    end

    it 'ignora cualquier intento de tocar otro usuario: siempre escribe el de la sesión' do
      otro = User.create!(email: 'otro@example.com', sap_user: 'intacto')

      sign_in(user)
      patch '/api/profile', params: { Id: otro.id, SapUser: 'hackeado' }

      expect(otro.reload.sap_user).to eq('intacto')
      expect(user.reload.sap_user).to eq('hackeado')
    end

    it 'rechaza un valor que excede el largo del contrato' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'x' * 76 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to be_present
      expect(user.reload.sap_user).to eq('manager')
    end

    it 'responde 401 sin sesión' do
      patch '/api/profile', params: { SapUser: 'nuevo' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # Guardar ya no exige probar antes: la marca dice si lo GUARDADO coincide con la
  # última prueba exitosa de la sesión, y la decide el servidor.
  describe 'marca de credenciales verificadas' do
    let(:sap)  { Connection.create!(name: 'SAP', sl_url: 'https://sap.test:50000/b1s/v1') }
    let(:acme) { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME') }

    before do
      Clavisco::ServiceLayer::LoadBalancer.instance.instance_variable_set(:@sessions, {})
      UsersByCompany.create!(user: user, company: acme)
      SlResource.create!(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                         query_params: '$top=1&$select=CardCode', page_size: 0, is_standard: true)
      stub_request(:post, %r{/b1s/v1/Logout\z}).to_return(status: 204)
      stub_request(:get, %r{/b1s/v1/BusinessPartners})
        .to_return(status: 200, body: { value: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    def stub_login(user_name, password, ok: true)
      stub_request(:post, 'https://sap.test:50000/b1s/v1/Login')
        .with(body: { CompanyDB: 'SBO_ACME', UserName: user_name, Password: password }.to_json)
        .to_return(status: ok ? 200 : 401,
                   body: (ok ? { SessionId: 'abc' } : { error: { code: -304, message: { value: 'Invalid' } } }).to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    def probar(sap_user, sap_pass)
      post '/api/sap_credential_validations',
           params: { SapUser: sap_user, SapPass: sap_pass, CompanyId: acme.id }, as: :json
    end

    it 'guarda sin probar y deja las credenciales sin verificar' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: 'otra-clave' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.sap_credentials_verified).to be(false)
      expect(body['Data']).to include('SapCredentialsVerified' => false)
    end

    it 'marca verificadas las credenciales guardadas si coinciden con la prueba' do
      stub_login('nuevo', 'otra-clave')

      sign_in(user)
      probar('nuevo', 'otra-clave')
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: 'otra-clave' }, as: :json

      expect(user.reload.sap_credentials_verified).to be(true)
    end

    it 'no marca nada si lo guardado no es lo que se probó' do
      stub_login('nuevo', 'otra-clave')

      sign_in(user)
      probar('nuevo', 'otra-clave')
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: 'distinta' }, as: :json

      expect(user.reload.sap_credentials_verified).to be(false)
    end

    it 'una prueba fallida posterior anula la exitosa' do
      stub_login('nuevo', 'otra-clave')
      stub_login('nuevo', 'mala', ok: false)

      sign_in(user)
      probar('nuevo', 'otra-clave')
      probar('nuevo', 'mala')
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: 'otra-clave' }, as: :json

      expect(user.reload.sap_credentials_verified).to be(false)
    end

    it 'apaga la marca cuando las credenciales cambian sin probarlas' do
      user.update_columns(sap_credentials_verified: true)

      sign_in(user)
      patch '/api/profile', params: { SapUser: 'otro' }, as: :json

      expect(user.reload.sap_credentials_verified).to be(false)
    end

    it 'conserva la marca si solo cambia el nombre' do
      user.update_columns(sap_credentials_verified: true)

      sign_in(user)
      patch '/api/profile', params: { Name: 'Otro nombre', SapUser: 'manager', SapPass: '' }, as: :json

      expect(user.reload.sap_credentials_verified).to be(true)
    end
  end
end

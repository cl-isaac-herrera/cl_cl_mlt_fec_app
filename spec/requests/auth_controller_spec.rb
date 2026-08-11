# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AuthController (login OIDC)', type: :request do
  let(:fake_client) { instance_double(Clavisco::Auth::OidcClient) }

  before do
    stub_oidc_config
    allow(Clavisco::Auth::OidcClient).to receive(:new).and_return(fake_client)
  end

  describe 'GET /auth/login' do
    it 'redirige a la authorization_uri del proveedor OIDC y guarda state/nonce en sesión' do
      allow(fake_client).to receive(:authorization_uri).and_return('https://test.auth0.com/authorize?state=abc')

      get '/auth/login'

      expect(response).to redirect_to('https://test.auth0.com/authorize?state=abc')
      expect(session[:oidc_state]).to be_present
      expect(session[:oidc_nonce]).to be_present
    end

    it '/login es la misma puerta: no renderiza formulario propio, redirige al proveedor' do
      allow(fake_client).to receive(:authorization_uri).and_return('https://test.auth0.com/authorize')

      get '/login'

      expect(response).to redirect_to('https://test.auth0.com/authorize')
    end
  end

  describe 'GET /auth/callback' do
    let!(:user) { User.create!(email: 'foo@example.com') }

    before do
      allow(fake_client).to receive(:authorization_uri).and_return('https://test.auth0.com/authorize')
      allow(fake_client).to receive(:exchange_code).with('abc123')
                                                   .and_return(double(id_token: 'fake-id-token', access_token: 'fake-access-token'))
    end

    # Arranca el login y deja el id_token stubbeado con el nonce real de esta
    # sesión — el controller lo compara y sin él ningún callback prospera.
    # @return [String] el state con el que hay que volver del proveedor
    def start_login(claims = {})
      get '/auth/login'
      allow(fake_client).to receive(:decode_id_token).with('fake-id-token')
                                                     .and_return(claims.merge('nonce' => session[:oidc_nonce]))
      session[:oidc_state]
    end

    it 'crea la sesión cuando el email del id_token coincide con un usuario existente' do
      state = start_login('email' => user.email)

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:user_id]).to eq(user.id)
      expect(response).to redirect_to(root_path)
    end

    it 'enlaza la cuenta guardando el oidc_sub en el primer login' do
      state = start_login('sub' => 'auth0|abc', 'email' => user.email)

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(user.reload.oidc_sub).to eq('auth0|abc')
    end

    it 'en logins posteriores identifica por oidc_sub aunque el correo haya cambiado' do
      user.update!(oidc_sub: 'auth0|abc')
      state = start_login('sub' => 'auth0|abc', 'email' => 'otro@example.com')

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:user_id]).to eq(user.id)
    end

    it 'guarda el token en la session cookie, nunca lo expone al browser' do
      state = start_login('email' => user.email)

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:access_token]).to eq('fake-access-token')
      expect(response.body).not_to include('fake-access-token')
    end

    it 'deja el id_token fuera de la cookie: guarda solo una llave al cache' do
      state = start_login('email' => user.email)

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:id_token]).to be_nil
      expect(session[:id_token_key]).to be_present
      expect(Rails.cache.read("oidc:id_token:#{session[:id_token_key]}")).to eq('fake-id-token')
    end

    it 'no crea sesión si no existe un usuario con ese email (sin auto-provisionar)' do
      state = start_login('email' => 'nadie@example.com')

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:user_id]).to be_nil
      expect(response).to have_http_status(:unauthorized)
    end

    it 'maneja el rechazo del usuario en la pantalla de consentimiento sin reventar' do
      get '/auth/login'

      # Auth0 vuelve con error y SIN code cuando el usuario da Decline.
      get '/auth/callback', params: {
        state: session[:oidc_state], error: 'access_denied',
        error_description: 'User did not authorize the request'
      }

      expect(response).to have_http_status(:unauthorized)
      expect(session[:user_id]).to be_nil
    end

    it 'rechaza una respuesta sin código y sin error' do
      get '/auth/login'

      get '/auth/callback', params: { state: session[:oidc_state] }

      expect(response).to have_http_status(:bad_request)
      expect(session[:user_id]).to be_nil
    end

    it 'rechaza si el state no coincide (protección CSRF del flujo OIDC)' do
      get '/auth/login'

      get '/auth/callback', params: { state: 'estado-falso', code: 'abc123' }

      expect(response).to have_http_status(:bad_request)
      expect(session[:user_id]).to be_nil
    end

    it 'no crea sesión si el nonce del id_token no corresponde a este login (replay)' do
      get '/auth/login'
      allow(fake_client).to receive(:decode_id_token)
        .and_return({ 'email' => user.email, 'nonce' => 'nonce-de-otro-login' })

      get '/auth/callback', params: { state: session[:oidc_state], code: 'abc123' }

      expect(response).to have_http_status(:unauthorized)
      expect(session[:user_id]).to be_nil
    end

    it 'no crea sesión si el id_token no trae nonce' do
      get '/auth/login'
      allow(fake_client).to receive(:decode_id_token).and_return({ 'email' => user.email })

      get '/auth/callback', params: { state: session[:oidc_state], code: 'abc123' }

      expect(response).to have_http_status(:unauthorized)
      expect(session[:user_id]).to be_nil
    end

    it 'consume state y nonce: no quedan disponibles para un segundo callback' do
      state = start_login('email' => user.email)

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:oidc_state]).to be_nil
      expect(session[:oidc_nonce]).to be_nil
    end
  end

  describe 'GET /auth/logout' do
    it 'invalida la sesión completa y redirige al logout del proveedor' do
      allow(fake_client).to receive(:logout_url).and_return('https://test.auth0.com/v2/logout?client_id=cid')
      sign_in(access_token: 'tok')

      get '/auth/logout'

      expect(session[:user_id]).to be_nil
      expect(session[:access_token]).to be_nil
      expect(response).to redirect_to('https://test.auth0.com/v2/logout?client_id=cid')
    end

    context 'con Keycloak' do
      let!(:user) { User.create!(email: 'salir@example.com') }
      let(:base_logout) { 'https://kc.example.com/realms/r/protocol/openid-connect/logout?client_id=cid' }

      before do
        stub_oidc_config(provider: 'keycloak', domain: 'kc.example.com/realms/r')
        allow(fake_client).to receive(:authorization_uri).and_return('https://kc.example.com/authorize')
        allow(fake_client).to receive(:exchange_code)
          .and_return(double(id_token: 'fake-id-token', access_token: 'fake-access-token'))
        allow(fake_client).to receive(:logout_url).and_return(base_logout)
      end

      # Sin id_token_hint Keycloak solo muestra la pantalla de confirmación y deja
      # el SSO vivo — el siguiente login entra sin pedir credenciales.
      it 'agrega el id_token_hint del login para que el proveedor cierre el SSO' do
        get '/auth/login'
        allow(fake_client).to receive(:decode_id_token)
          .and_return({ 'email' => user.email, 'nonce' => session[:oidc_nonce] })
        get '/auth/callback', params: { state: session[:oidc_state], code: 'abc123' }

        get '/auth/logout'

        expect(response).to redirect_to("#{base_logout}&id_token_hint=fake-id-token")
      end

      it 'descarta el id_token del cache al cerrar sesión: no se reutiliza' do
        get '/auth/login'
        allow(fake_client).to receive(:decode_id_token)
          .and_return({ 'email' => user.email, 'nonce' => session[:oidc_nonce] })
        get '/auth/callback', params: { state: session[:oidc_state], code: 'abc123' }
        key = session[:id_token_key]

        get '/auth/logout'

        expect(Rails.cache.read("oidc:id_token:#{key}")).to be_nil
      end

      it 'cierra sesión igual si ya no hay id_token guardado' do
        sign_in

        get '/auth/logout'

        expect(response).to redirect_to(base_logout)
      end
    end
  end

  describe 'sin configuración OIDC' do
    it 'responde 503 en vez de reventar con NoMethodError sobre la config nil' do
      allow(Rails.application.config).to receive(:oidc).and_return(nil)

      get '/login'

      expect(response).to have_http_status(:service_unavailable)
    end
  end
end

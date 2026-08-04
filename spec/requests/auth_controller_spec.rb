# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'AuthController (login OIDC)', type: :request do
  let(:fake_client) { instance_double(Clavisco::Auth::OidcClient) }

  before do
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
  end

  describe 'GET /auth/callback' do
    let!(:user) { User.create!(email: 'foo@example.com') }

    before do
      allow(fake_client).to receive(:authorization_uri).and_return('https://test.auth0.com/authorize')
      allow(fake_client).to receive(:exchange_code).with('abc123').and_return(double(id_token: 'fake-id-token'))
    end

    it 'crea la sesión cuando el email del id_token coincide con un usuario existente' do
      allow(fake_client).to receive(:decode_id_token).with('fake-id-token').and_return({ 'email' => user.email })

      get '/auth/login'
      state = session[:oidc_state]

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:user_id]).to eq(user.id)
      expect(response).to redirect_to(root_path)
    end

    it 'no crea sesión si no existe un usuario con ese email (sin auto-provisionar)' do
      allow(fake_client).to receive(:decode_id_token).with('fake-id-token').and_return({ 'email' => 'nadie@example.com' })

      get '/auth/login'
      state = session[:oidc_state]

      get '/auth/callback', params: { state: state, code: 'abc123' }

      expect(session[:user_id]).to be_nil
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rechaza si el state no coincide (protección CSRF del flujo OIDC)' do
      get '/auth/login'

      get '/auth/callback', params: { state: 'estado-falso', code: 'abc123' }

      expect(response).to have_http_status(:bad_request)
      expect(session[:user_id]).to be_nil
    end
  end
end

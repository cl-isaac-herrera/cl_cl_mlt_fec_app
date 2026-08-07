# frozen_string_literal: true

require 'rails_helper'

# Controller exclusivo de este spec (ver config/routes.rb, montado solo en test).
# La sesión se establece con el helper `sign_in` (spec/support/session_helpers.rb),
# sin recorrer el flujo OIDC real (eso lo cubre spec/requests/auth_controller_spec.rb).
class BaseControllerTestController < Api::BaseController
  def whoami
    render json: {
      user_id:    Current.user&.id,
      email:      Current.user&.email,
      company_id: Current.company_id
    }
  end
end

RSpec.describe Api::BaseController, type: :request do
  let(:user)      { User.create!(email: 'dual@example.com', name: 'Dual', oidc_sub: 'auth0|123') }
  let(:company)   { Company.create!(name: 'ACME') }
  let(:validator) { instance_double(Clavisco::Auth::JwtValidator) }

  before do
    # JwtValidator.new revienta sin OIDC_DOMAIN/OIDC_AUDIENCE configurados, y este
    # spec no debe depender de un proveedor real ni salir a la red por el JWKS.
    allow(Clavisco::Auth::JwtValidator).to receive(:new).and_return(validator)
    allow(validator).to receive(:validate).with('token-valido')
                                          .and_return({ 'sub' => 'auth0|123', 'email' => user.email })
    allow(validator).to receive(:validate).with('token-sin-usuario')
                                          .and_return({ 'sub' => 'auth0|desconocido' })
  end

  describe 'session cookie primero' do
    it 'autentica con la session cookie sin necesidad de un Bearer token' do
      sign_in(user, company: company)

      get '/__test/base/whoami'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['user_id']).to eq(user.id)
      expect(body['email']).to eq(user.email)
    end

    it 'publica el company_id de la sesión en Current (nunca de un header)' do
      sign_in(user, company: company)

      get '/__test/base/whoami'

      expect(JSON.parse(response.body)['company_id']).to eq(company.id)
    end

    it 'deja company_id en nil cuando la sesión no tiene compañía seleccionada' do
      sign_in(user)

      get '/__test/base/whoami'

      expect(JSON.parse(response.body)['company_id']).to be_nil
    end
  end

  describe 'fallback JWT Bearer' do
    it 'autentica por Bearer token cuando no hay sesión, resolviendo el usuario por oidc_sub' do
      get '/__test/base/whoami', headers: { 'Authorization' => 'Bearer token-valido' }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['user_id']).to eq(user.id)
    end

    it 'cae al Bearer token cuando la sesión apunta a un usuario que ya no existe' do
      post '/__test/session', params: { user_id: 999_999 }

      get '/__test/base/whoami', headers: { 'Authorization' => 'Bearer token-valido' }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['user_id']).to eq(user.id)
    end

    it 'rechaza con 401 el token cuyo sub no corresponde a ningún usuario local' do
      get '/__test/base/whoami', headers: { 'Authorization' => 'Bearer token-sin-usuario' }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)['Code']).to eq(401)
    end

    it 'rechaza con 401 al usuario desactivado aunque su token sea válido' do
      user.soft_delete!

      get '/__test/base/whoami', headers: { 'Authorization' => 'Bearer token-valido' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'sin sesión ni token' do
    it 'responde 401 con el contrato ApiResponse' do
      get '/__test/base/whoami'

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body['Code']).to eq(401)
      expect(body['Message']).to be_present
    end
  end
end

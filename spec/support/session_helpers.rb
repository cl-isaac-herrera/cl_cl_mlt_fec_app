# frozen_string_literal: true

# Controller exclusivo de los specs (ver config/routes.rb, montado solo en test).
# Permite establecer la session cookie sin recorrer el flujo OIDC completo, para
# los specs que prueban páginas protegidas y no la autenticación en sí.
class TestSessionController < ActionController::Base
  skip_before_action :verify_authenticity_token

  def create
    session[:user_id]      = params[:user_id].presence&.to_i
    session[:company_id]   = params[:company_id].presence&.to_i
    session[:access_token] = params[:access_token].presence
    head :ok
  end
end

# Helpers de sesión para request specs.
module SessionHelpers
  # Deja la sesión de servidor lista. Devuelve el usuario autenticado.
  def sign_in(user = nil, company: nil, access_token: nil)
    user ||= User.create!(email: "spec-#{SecureRandom.hex(4)}@example.com")

    post '/__test/session', params: {
      user_id: user.id, company_id: company&.id, access_token: access_token
    }

    user
  end

  # Descarta la sesión establecida por sign_in, para probar el comportamiento
  # de un visitante sin autenticar dentro del mismo ejemplo.
  def reset_session_cookie
    post '/__test/session', params: { user_id: nil }
  end

  # Config OIDC falsa — los specs no deben depender de un tenant real.
  def stub_oidc_config(provider: 'auth0', domain: 'test.auth0.com')
    config = OidcConfig.new(
      domain: domain, client_id: 'cid', client_secret: 'secret', audience: '',
      provider: provider,
      authorization_endpoint: "https://#{domain}/authorize",
      token_endpoint: "https://#{domain}/oauth/token"
    )
    allow(Rails.application.config).to receive(:oidc).and_return(config)
    config
  end
end

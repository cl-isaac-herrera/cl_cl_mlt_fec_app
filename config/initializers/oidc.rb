# frozen_string_literal: true

# Config del proveedor OIDC (Auth0 o Keycloak) para Clavisco::Auth::OidcClient.
# Ver vendor/clavisco/auth/lib/clavisco/auth/oidc_client.rb.
#
# Si OIDC_DOMAIN no está configurado (ej. en desarrollo local sin credenciales
# reales todavía), Rails.application.config.oidc queda en nil — el login OIDC
# no se puede usar hasta que se configuren las variables, pero el boot no falla.
OidcConfig = Struct.new(:domain, :client_id, :client_secret, :audience, :provider,
                        :authorization_endpoint, :token_endpoint, keyword_init: true)

Rails.application.config.oidc =
  if ENV['OIDC_DOMAIN'].present?
    domain   = ENV.fetch('OIDC_DOMAIN')
    provider = ENV.fetch('OIDC_PROVIDER', 'auth0')

    authorization_endpoint, token_endpoint =
      case provider
      when 'keycloak'
        ["https://#{domain}/protocol/openid-connect/auth", "https://#{domain}/protocol/openid-connect/token"]
      else
        ["https://#{domain}/authorize", "https://#{domain}/oauth/token"]
      end

    OidcConfig.new(
      domain: domain,
      client_id: ENV.fetch('OIDC_CLIENT_ID'),
      client_secret: ENV.fetch('OIDC_CLIENT_SECRET'),
      audience: ENV.fetch('OIDC_AUDIENCE', ''),
      provider: provider,
      authorization_endpoint: authorization_endpoint,
      token_endpoint: token_endpoint
    )
  end

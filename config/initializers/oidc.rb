# frozen_string_literal: true

# Config del proveedor OIDC (Auth0 o Keycloak) para Clavisco::Auth::OidcClient.
# Ver vendor/clavisco/auth/lib/clavisco/auth/oidc_client.rb.
#
# Los endpoints se derivan acá porque el submódulo no expone un OidcConfig que lo
# haga. CLAVISCO-PLATFORM-STANDARDS §2.3 pide justo lo contrario (derivarlos desde
# Clavisco::Auth::OidcConfig.build) — es una desviación conocida y bloqueada
# aguas arriba: la solución vive en cl-auth-ruby, no en este repo. Ver TODOS.md.
#
# Si OIDC_DOMAIN no está configurado (ej. en desarrollo local sin credenciales
# reales todavía), Rails.application.config.oidc queda en nil — el login OIDC
# no se puede usar hasta que se configuren las variables, pero el boot no falla.
OidcConfig = Struct.new(:domain, :client_id, :client_secret, :audience, :provider,
                        :issuer, :authorization_endpoint, :token_endpoint, :jwks_uri,
                        keyword_init: true)

Rails.application.config.oidc =
  if ENV['OIDC_DOMAIN'].present?
    host     = ENV.fetch('OIDC_DOMAIN')
    provider = ENV.fetch('OIDC_PROVIDER', 'auth0')

    # `domain` es la BASE del proveedor, no solo el host: Clavisco::Auth la concatena
    # tal cual para armar URLs (OidcClient#logout_url, #password_reset,
    # JwtValidator#issuer/JWKS). Keycloak publica todo bajo /realms/<realm>, así que
    # ahí el realm forma parte de la base — es la convención que documenta el README
    # del submódulo (`domain: "keycloak.example.com/realms/myrealm"`).
    domain =
      if provider == 'keycloak'
        realm = ENV['OIDC_REALM'].presence
        raise 'OIDC_REALM es obligatorio cuando OIDC_PROVIDER=keycloak' unless realm

        "#{host}/realms/#{realm}"
      else
        host
      end

    # Endpoints explícitos en vez de discovery: el submódulo construye el cliente con
    # ellos (rack-oauth2 respeta URLs absolutas) y así el boot no depende de una
    # llamada de red al IdP.
    issuer, authorization_endpoint, token_endpoint, jwks_uri =
      case provider
      when 'keycloak'
        # Verificado contra https://<domain>/.well-known/openid-configuration:
        # el issuer de Keycloak NO lleva slash final y el JWKS vive en .../certs.
        ["https://#{domain}",
         "https://#{domain}/protocol/openid-connect/auth",
         "https://#{domain}/protocol/openid-connect/token",
         "https://#{domain}/protocol/openid-connect/certs"]
      else
        ["https://#{domain}/",
         "https://#{domain}/authorize",
         "https://#{domain}/oauth/token",
         "https://#{domain}/.well-known/jwks.json"]
      end

    OidcConfig.new(
      domain: domain,
      client_id: ENV.fetch('OIDC_CLIENT_ID'),
      client_secret: ENV.fetch('OIDC_CLIENT_SECRET'),
      # Keycloak no usa el parámetro `audience` de Auth0 en /authorize; acá el valor
      # sirve para verificar el claim `aud` del Bearer JWT y por eso es el client_id.
      audience: ENV.fetch('OIDC_AUDIENCE', ''),
      provider: provider,
      issuer: issuer,
      authorization_endpoint: authorization_endpoint,
      token_endpoint: token_endpoint,
      jwks_uri: jwks_uri
    )
  end

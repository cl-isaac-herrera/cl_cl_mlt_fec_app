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

  # Concede permisos a un usuario para los request specs, sin que cada archivo
  # tenga que repetir el boilerplate de armar rol + role_permission +
  # users_by_companies (o el rol de instalación del usuario, para los permisos
  # de alcance `installation`). Centralizar esto acá es lo que permitió que la
  # migración a "roles por alcance" (docs/PLAN-ROLES-POR-ALCANCE.md) tocara un
  # solo archivo en vez de los ~25 que declaraban su propio `sign_in_with`.
  #
  # @param user [User] a quien se le conceden los permisos.
  # @param names [Array<String>] nombres de permiso (`Permission#name`).
  # @param company [Company, nil] requerida para permisos `company`; ignorada
  #   (no hace falta) para permisos `installation`, que no dependen de compañía.
  #
  # ⚠️ Un usuario tiene UN SOLO rol de instalación y UN SOLO rol por compañía
  # (`UsersByCompany`/`User#installation_role_id` — no son tablas de unión como
  # el viejo `user_roles`), así que varios permisos del mismo alcance para el
  # mismo usuario (y, si aplica, la misma compañía) se acumulan en EL MISMO
  # rol de prueba en vez de crear uno nuevo por permiso — dos llamadas
  # separadas no se pisan, se suman.
  #
  # ⚠️ El alcance de un permiso NUEVO (que el spec no haya creado ya con un
  # `scope` explícito) lo decide si esta llamada trae `company:` o no — pasarlo
  # es la señal de que el nombre es un permiso de compañía; omitirlo, de que es
  # de instalación. Un permiso que el spec ya creó antes (con su propio `scope`)
  # conserva el que tenga: `find_or_create_by!` con bloque solo corre en el alta.
  def grant_permissions(user, *names, company: nil)
    names.flatten.each do |name|
      permission = Permission.find_or_create_by!(name: name) { |p| p.scope = company ? 'company' : 'installation' }

      if permission.scope == 'installation'
        role = Role.find_or_create_by!(name: "Rol de prueba (instalación) — usuario #{user.id}",
                                       scope: 'installation')
        RolePermission.find_or_create_by!(role: role, permission: permission)
        user.update!(installation_role: role) unless user.installation_role_id == role.id
      else
        raise ArgumentError, "grant_permissions: falta `company:` para el permiso de compañía #{name.inspect}" if company.nil?

        role = Role.find_or_create_by!(
          name: "Rol de prueba (compañía) — usuario #{user.id} en compañía #{company.id}", scope: 'company'
        )
        RolePermission.find_or_create_by!(role: role, permission: permission)

        assignment = UsersByCompany.find_or_initialize_by(user: user, company: company)
        assignment.role      = role unless assignment.role_id == role.id
        assignment.is_active = true
        assignment.save!
      end
    end
  end

  # Config OIDC falsa — los specs no deben depender de un tenant real.
  def stub_oidc_config(provider: 'auth0', domain: 'test.auth0.com')
    config = OidcConfig.new(
      domain: domain, client_id: 'cid', client_secret: 'secret', audience: '',
      provider: provider,
      issuer: "https://#{domain}/",
      authorization_endpoint: "https://#{domain}/authorize",
      token_endpoint: "https://#{domain}/oauth/token",
      jwks_uri: "https://#{domain}/.well-known/jwks.json"
    )
    allow(Rails.application.config).to receive(:oidc).and_return(config)
    config
  end
end

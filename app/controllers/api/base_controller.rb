# frozen_string_literal: true

# Api::BaseController — punto de entrada de todo controller de API.
#
# Dual auth (CLAVISCO-PLATFORM-STANDARDS §2.3): la session cookie de Rails se
# verifica primero (cero I/O de red — un find por id) y el JWT Bearer queda como
# fallback para clientes externos que no usan cookies.
#
# El proveedor OIDC solo autentica: dice QUIÉN es el usuario. Roles y permisos
# viven siempre en la base del producto — ver Api::AuthorizedController.
class Api::BaseController < ActionController::API
  include Clavisco::Auth::Authenticatable

  # Dónde se publica el usuario autenticado. Explícito aunque el concern también
  # caiga en `Current` por default.
  #
  # La resolución del usuario NO se sobreescribe: se usa el default del submódulo,
  # `User.find_by(oidc_sub: claims["sub"])`. Los usuarios inactivos quedan fuera por
  # el default_scope de SoftDeletable.
  self.context_store = Current

  before_action :authenticate_from_session_or_token!

  private

  # Session cookie primero; si no hay sesión válida, cae al JWT Bearer.
  def authenticate_from_session_or_token!
    return if authenticate_from_session

    authenticate_user! # fallback JWT Bearer (Authenticatable)
  end

  # @return [Boolean] true si la session cookie identificó al usuario.
  def authenticate_from_session
    user_id = request.session[:user_id]
    return false if user_id.blank?

    user = User.find_by(id: user_id)
    unless user
      # Sesión que apunta a un usuario inexistente o desactivado: se limpia y se
      # deja que el JWT decida, en vez de dar por autenticado a nadie.
      request.session.delete(:user_id)
      return false
    end

    Current.user = user
    # company_id vive en la session cookie, nunca en un header (§2.4). Sin
    # compañía en sesión queda nil y require_permission! no concede nada.
    Current.company_id = request.session[:company_id]
    true
  end
end

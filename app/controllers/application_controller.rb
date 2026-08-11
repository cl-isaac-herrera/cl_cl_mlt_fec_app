# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Protección CSRF estándar
  protect_from_forgery with: :exception

  # Toda página exige sesión de servidor. Reemplaza al gate client-side que leía
  # localStorage: la decisión se toma antes de renderizar, no después de pintar.
  # Las excepciones se declaran con `skip_before_action :require_session` en el
  # controller correspondiente (AuthController, AccountVerificationsController,
  # ProxyController) y están justificadas caso por caso.
  before_action :require_session

  helper_method :current_user

  private

  # Usuario de la sesión de servidor. Es lo que reemplaza a la llave `Session` de
  # localStorage que leía el JS antes del cutover a OIDC: la cookie es httpOnly, así
  # que los datos del usuario los tiene que poner el servidor al renderizar.
  # Privado a propósito: los métodos públicos de un controller son actions.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end

  def require_session
    return if session[:user_id].present?

    request.format.html? ? redirect_to(login_path) : render(json: { error: 'No autorizado' }, status: :unauthorized)
  end

  # Renderiza 403 si el usuario actual no tiene el permiso dado para la compañía actual.
  # Uso: before_action { require_view_permission!("Module_Resource_Action") }
  def require_view_permission!(name)
    render 'errors/forbidden', status: :forbidden unless view_permission_granted?(name)
  end

  # Un solo EXISTS query — lee user_id y company_id de la sesión.
  def view_permission_granted?(name)
    user_id    = session[:user_id]
    company_id = session[:company_id]
    return false unless user_id && company_id

    RolePermission
      .joins(:permission, :role)
      .joins('INNER JOIN user_roles ON user_roles.role_id = roles.id')
      .where(
        user_roles:       { user_id: user_id, company_id: company_id, is_active: true },
        permissions:      { name: name, is_active: true },
        role_permissions: { is_active: true }
      ).exists?
  end
end

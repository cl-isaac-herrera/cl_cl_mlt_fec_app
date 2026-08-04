# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Protección CSRF estándar
  protect_from_forgery with: :exception

  # NOTA — convivencia con la autenticación 100% client-side actual:
  # Las 26 páginas existentes de este proyecto dependen hoy de un token en
  # localStorage (sin sesión de servidor). `require_session`/`require_view_permission!`
  # quedan disponibles como base para el login OIDC nuevo, pero NO se activan acá
  # como before_action global — eso rompería todas las páginas actuales, que todavía
  # no tienen ningún flujo que popule session[:user_id]. Cada controller nuevo que
  # migre a sesión de servidor los adopta explícitamente cuando le toque.

  private

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

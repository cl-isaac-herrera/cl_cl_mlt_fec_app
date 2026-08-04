# frozen_string_literal: true

class Api::AuthorizedController < Api::BaseController
  after_action :verify_permission_checked

  private

  # Un solo EXISTS query sobre user_roles/role_permissions/permissions.
  # Nunca cargar los permisos del usuario completos y filtrar en Ruby.
  def require_permission!(name)
    @permission_checked = true

    granted = RolePermission
      .joins(:permission, :role)
      .joins("INNER JOIN user_roles ON user_roles.role_id = roles.id")
      .where(
        user_roles:       { user_id: Current.user&.id, company_id: Current.company_id, is_active: true },
        permissions:      { name: name, is_active: true },
        role_permissions: { is_active: true }
      ).exists?

    render json: ApiResponse.forbidden.to_h, status: :forbidden unless granted
  end

  # Usar cuando una acción deliberadamente no requiere ningún permiso puntual
  # (ej. un endpoint que solo devuelve los datos del propio usuario autenticado).
  def skip_permission_check!(reason = nil)
    @permission_checked = true
  end

  # Safety net: si una acción no llamó require_permission! ni skip_permission_check!,
  # revienta en desarrollo en vez de quedar silenciosamente sin proteger.
  def verify_permission_checked
    return if @permission_checked || !Rails.env.development?

    raise "#{self.class}##{action_name} no llamó require_permission! ni skip_permission_check!"
  end
end

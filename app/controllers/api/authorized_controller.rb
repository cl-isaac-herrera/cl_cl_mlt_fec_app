# frozen_string_literal: true

class Api::AuthorizedController < Api::BaseController
  after_action :verify_permission_checked

  private

  # Un solo EXISTS query sobre user_roles/role_permissions/permissions.
  # Nunca cargar los permisos del usuario completos y filtrar en Ruby.
  def require_permission!(name)
    require_any_permission!(name)
  end

  # Cuando un mismo endpoint sirve a dos pantallas con permisos distintos y
  # cualquiera de los dos habilita legítimamente la lectura (ej. las compañías de
  # un usuario: las pide el panel de edición para probar credenciales y el tab de
  # asignación para armar la lista dual). Exigir uno solo dejaría sin datos a la
  # otra pantalla.
  #
  # No es un relajamiento: cada nombre por separado ya autoriza esa acción. Si un
  # permiso no alcanzara por sí solo, esto NO es la herramienta.
  def require_any_permission!(*names)
    @permission_checked = true
    return if names.any? { |name| permission?(name) }

    render json: ApiResponse.forbidden.to_h, status: :forbidden
  end

  # Predicado: responde si el usuario tiene el permiso, sin cortar la respuesta.
  # Para decidir el ALCANCE de una acción que ya pasó su propio `require_permission!`
  # (ej. si la lista de usuarios se limita a la compañía activa o abarca todo el
  # producto). No marca la acción como verificada a propósito: preguntar no es
  # autorizar, y el safety net tiene que seguir exigiendo el check explícito.
  #
  # Hay DOS vías de concesión y el permiso vale si cualquiera lo otorga:
  #   1. por rol en la compañía activa — el caso normal, y el que se evalúa primero
  #      porque cubre la enorme mayoría de las verificaciones;
  #   2. concedido directo al usuario, solo para permisos `global` (§ UserPermission).
  # La segunda consulta solo corre si la primera no concedió nada.
  def permission?(name)
    granted_by_role?(name) || UserPermission.granting?(user_id: Current.user&.id, name: name)
  end

  # Un solo EXISTS query sobre user_roles/role_permissions/permissions.
  def granted_by_role?(name)
    RolePermission
      .joins(:permission, :role)
      .joins("INNER JOIN user_roles ON user_roles.role_id = roles.id")
      .where(
        user_roles:       { user_id: Current.user&.id, company_id: Current.company_id, is_active: true },
        permissions:      { name: name, is_active: true },
        role_permissions: { is_active: true }
      ).exists?
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

# frozen_string_literal: true

class Api::AuthorizedController < Api::BaseController
  after_action :verify_permission_checked

  private

  # Un solo EXISTS query sobre role_permissions/permissions (por rol de
  # instalación o de compañía, ver `permission?`). Nunca cargar los permisos
  # del usuario completos y filtrar en Ruby.
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
  # Roles por alcance (docs/PLAN-ROLES-POR-ALCANCE.md): el permiso vale si
  # cualquiera de estas vías lo otorga —
  #   1. el rol de INSTALACIÓN del usuario (`users.installation_role_id`), que
  #      no depende de ninguna compañía activa;
  #   2. el rol de COMPAÑÍA de la asignación activa (`users_by_companies`,
  #      usuario + compañía activa) — sin compañía activa, no aplica.
  # Por invariante, un permiso de instalación nunca debería quedar en el rol de
  # compañía de nadie (`RolePermission#scope_matches_role`) — pero esa
  # validación no corre en las escrituras en lote (`insert_all`/`update_all`,
  # §1.6), así que cada vía filtra ADEMÁS por `permissions.scope` acá: defensa
  # en profundidad (§26), no solo confiar en que la fila nunca debió existir.
  def permission?(name)
    granted_by_installation_role?(name) || granted_by_company_role?(name)
  end

  # Un solo EXISTS query sobre role_permissions/permissions, contra el rol de
  # instalación del usuario.
  def granted_by_installation_role?(name)
    RolePermission
      .joins(:permission)
      .where(role_id: Current.user&.installation_role_id, is_active: true)
      .where(permissions: { name: name, is_active: true, scope: 'installation' })
      .exists?
  end

  # Un solo EXISTS query sobre users_by_companies/role_permissions/permissions,
  # acotado a la compañía activa.
  def granted_by_company_role?(name)
    return false unless Current.company_id

    RolePermission
      .joins(:permission, :role)
      .joins('INNER JOIN users_by_companies ON users_by_companies.role_id = roles.id')
      .where(
        users_by_companies: { user_id: Current.user&.id, company_id: Current.company_id, is_active: true },
        permissions:        { name: name, is_active: true, scope: 'company' },
        role_permissions:   { is_active: true }
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

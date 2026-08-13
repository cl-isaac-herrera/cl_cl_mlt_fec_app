# frozen_string_literal: true

module Api
  # Permisos efectivos del usuario autenticado en la compañía activa.
  #
  # Reemplaza `GET /api/Permission/GetPermsByUser?companyId=N` del API .NET. El
  # companyId ya no viaja como parámetro: la compañía activa vive en la session
  # cookie (§2.4), así que el cliente no puede pedir los permisos de otra.
  class PermissionsController < AuthorizedController
    # GET /api/permissions
    def index
      # skip_permission_check! — cualquier usuario autenticado puede consultar sus
      # propios permisos; exigir un permiso para leerlos sería circular.
      skip_permission_check!

      render json: ApiResponse.success(effective_permissions).to_h
    end

    # GET /api/permissions/catalog
    #
    # Catálogo completo de permisos que existen en el producto — lo que la
    # pantalla de seguridad pinta como checkboxes al asignar permisos a un rol.
    # Reemplaza `GET /api/Permission/GetPermissions`.
    #
    # ⚠️ Vive en una subcolección y no en `index` porque `GET /api/permissions`
    # ya estaba tomado por los permisos EFECTIVOS del usuario de la sesión, que
    # es otro recurso. El nombre correcto para el catálogo sería el `index`; ver
    # `TODOS.md` → Seguridad para el intercambio pendiente.
    #
    # `?type=global` lo recorta a los permisos de aplicación, y reemplaza al
    # endpoint aparte `GET /api/Permission/global-permissions` del .NET: es el
    # mismo recurso con un filtro, no otro distinto.
    def catalog
      # El permiso depende de para qué se pide: el catálogo completo lo consume la
      # asignación de permisos por rol; el global, el panel de accesos por usuario,
      # que se gatea con su propio permiso. Exigir el de roles ahí dejaría sin
      # catálogo a quien solo administra permisos globales.
      require_permission!(global_only? ? 'Configurations_Permissions_GlobalAccess'
                                       : 'Configurations_Permissions_Access')
      return if performed?

      permissions = global_only? ? Permission.global.order(:name) : Permission.order(:name)

      render json: ApiResponse.success(permissions.map { |p| serialize(p) }).to_h
    end

    private

    def global_only?
      params[:type].to_s == 'global'
    end

    # Unión de las dos vías de concesión, en el mismo formato `[{ Name: ... }]`
    # que ya consumen el menú y el auth-guard:
    #
    #   - por rol en la compañía activa → `AuthorizationService` del submódulo;
    #   - concedidos directo al usuario  → solo `global`, sin compañía de por medio.
    #
    # La unión se arma acá y no dentro del servicio porque el servicio vive en un
    # submódulo y no se toca (`CLAUDE.md` §27): es el patrón adaptador, el producto
    # se acomoda. Anotado en `TODOS.md` → Submódulos.
    def effective_permissions
      by_role = if Current.company_id
                  Clavisco::Auth::AuthorizationService.new(
                    Current.user,
                    Current.company_id,
                    models: { roles_by_user: UserRole, perms_by_role: RolePermission, permission: Permission }
                  ).permissions
                else
                  []
                end

      # Sin compañía activa los globales igual aplican: es lo que los hace globales.
      global = UserPermission.global_names_for(Current.user.id).map { |name| { Name: name } }

      (by_role + global).uniq { |p| p[:Name] || p['Name'] }
    end

    def serialize(permission)
      {
        Id:          permission.id,
        Name:        permission.name,
        Description: permission.description,
        Type:        permission.type
      }
    end
  end
end

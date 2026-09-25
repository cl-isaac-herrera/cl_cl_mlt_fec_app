# frozen_string_literal: true

module Api
  # Permisos efectivos del usuario autenticado: los de su rol de instalación
  # más los de su rol en la compañía activa, si hay una
  # (docs/PLAN-ROLES-POR-ALCANCE.md).
  #
  # Reemplaza `GET /api/Permission/GetPermsByUser?companyId=N` del API .NET. El
  # companyId ya no viaja como parámetro: la compañía activa vive en la session
  # cookie (§2.4), así que el cliente no puede pedir los permisos de otra.
  class PermissionsController < AuthorizedController
    # GET /api/permissions
    #
    # Se pide SIEMPRE, haya o no compañía activa: los permisos de instalación
    # (los que gatean Usuarios, Seguridad, Conexiones…) no dependen de una.
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
    # `?scope=installation|company` lo recorta a los permisos de ese alcance —
    # un rol solo puede contener los del suyo (`RolePermission`), así que la
    # pantalla pide el catálogo filtrado según qué rol está editando.
    def catalog
      require_permission!('Configurations_Permissions_Access')
      return if performed?

      permissions = scope_filter ? Permission.where(scope: scope_filter).order(:name) : Permission.order(:name)

      render json: ApiResponse.success(permissions.map { |p| serialize(p) }).to_h
    end

    private

    def scope_filter
      value = params[:scope].to_s
      value if Permission::SCOPES.include?(value)
    end

    # Unión de las dos vías de concesión, en el mismo formato `[{ Name: ... }]`
    # que ya consumen el menú y el auth-guard:
    #
    #   - rol de instalación (`users.installation_role_id`) → aplica siempre;
    #   - rol de compañía (`users_by_companies.role_id`) → solo con compañía
    #     activa, vía `AuthorizationService` del submódulo.
    #
    # La unión se arma acá y no dentro del servicio porque el servicio vive en un
    # submódulo y no se toca (`CLAUDE.md` §27): es el patrón adaptador, el producto
    # se acomoda. Anotado en `TODOS.md` → Submódulos.
    def effective_permissions
      installation_role = Current.user.installation_role
      installation = if installation_role
                       installation_role.permissions.where(is_active: true).order(:name)
                                        .pluck(:name).map { |name| { Name: name } }
                     else
                       []
                     end

      by_company = if Current.company_id
                     Clavisco::Auth::AuthorizationService.new(
                       Current.user,
                       Current.company_id,
                       models: { roles_by_user: UsersByCompany, perms_by_role: RolePermission, permission: Permission }
                     ).permissions
                   else
                     []
                   end

      (installation + by_company).uniq { |p| p[:Name] || p['Name'] }
    end

    def serialize(permission)
      {
        Id:          permission.id,
        Name:        permission.name,
        Description: permission.description,
        Scope:       permission.scope
      }
    end
  end
end

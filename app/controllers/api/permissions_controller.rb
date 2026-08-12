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

      permissions = if Current.company_id
                      Clavisco::Auth::AuthorizationService.new(
                        Current.user,
                        Current.company_id,
                        models: { roles_by_user: UserRole, perms_by_role: RolePermission, permission: Permission }
                      ).permissions
                    else
                      []
                    end

      render json: ApiResponse.success(permissions).to_h
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
    def catalog
      require_permission!('Configurations_Permissions_Access')
      return if performed?

      permissions = Permission.order(:name)

      render json: ApiResponse.success(permissions.map { |p| serialize(p) }).to_h
    end

    private

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

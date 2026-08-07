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
  end
end

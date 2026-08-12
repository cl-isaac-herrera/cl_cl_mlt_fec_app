# frozen_string_literal: true

module Api
  module Roles
    # Permisos asignados a un rol (panel "Permisos del rol" de
    # /configurations/security).
    #
    # Reemplaza `GET /api/Permission/GetPermissionsByRol?idRol=N` y
    # `POST /api/Permission/AssignPermByRol`. El rol deja de viajar como
    # parámetro suelto: es el recurso padre del path (`CLAUDE.md` §28).
    #
    # Se declara con `resource` (singular): el conjunto de permisos de un rol es
    # uno solo, así que no lleva id propio y se reemplaza entero con PUT.
    class PermissionsController < AuthorizedController
      before_action :authorize_action
      before_action :load_role

      PERMISSION = 'Configurations_Permissions_Access'

      # GET /api/roles/:role_id/permissions
      def show
        render json: ApiResponse.success(@role.permissions.order(:name).map { |p| serialize(p) }).to_h
      end

      # PUT /api/roles/:role_id/permissions
      #
      # Reemplazo completo: lo que no venga en `PermissionIds` queda revocado.
      # Es PUT y no POST porque mandar dos veces la misma lista deja al rol igual
      # — el .NET lo hacía con un POST que igual reemplazaba todo.
      def update
        if @role.protected_name?
          return render json: ApiResponse.forbidden('Este rol administra todos los permisos y no es editable.').to_h,
                        status: :forbidden
        end

        ids     = Array(params[:PermissionIds]).map(&:to_i).uniq
        unknown = ids - Permission.where(id: ids).pluck(:id)
        if unknown.any?
          return render json: ApiResponse.error("Permisos inexistentes: #{unknown.join(', ')}").to_h,
                        status: :unprocessable_content
        end

        replace_assignments(ids)

        render json: ApiResponse.success(@role.permissions.reload.order(:name).map { |p| serialize(p) },
                                         message: 'Permisos asignados con éxito.').to_h
      end

      private

      def authorize_action
        require_permission!(PERMISSION)
      end

      def load_role
        @role = Role.find_by(id: params[:role_id])
        return if @role

        render json: ApiResponse.not_found('El rol no existe.').to_h, status: :not_found
      end

      # Reasigna en LOTE: tres sentencias como mucho (un INSERT y dos UPDATE),
      # nunca una por checkbox. §1.6 del estándar nombra este caso exacto —
      # "un formulario de permisos que guarda cada checkbox con su propio
      # find_or_initialize_by + save!" — como el equivalente del N+1 al escribir.
      #
      # Se consulta con `unscoped` porque `role_permissions` tiene soft delete: si
      # se mirara solo lo activo, volver a conceder un permiso revocado insertaría
      # una fila nueva y dejaría la vieja inactiva acumulándose.
      #
      # `insert_all`/`update_all` no disparan callbacks, así que las columnas de
      # auditoría que normalmente pone `Auditable` se escriben a mano acá. Es el
      # precio de la escritura en lote y no puede olvidarse: §2.2 las exige.
      def replace_assignments(ids)
        now   = Time.current
        actor = Current.user&.email || 'system'

        RolePermission.transaction do
          existing   = RolePermission.unscoped.where(role_id: @role.id).pluck(:permission_id, :is_active).to_h
          to_insert  = ids - existing.keys
          to_enable  = ids.select { |id| existing[id] == false }
          to_disable = existing.select { |id, active| active && ids.exclude?(id) }.keys

          if to_insert.any?
            RolePermission.insert_all(
              to_insert.map do |permission_id|
                { role_id: @role.id, permission_id: permission_id, is_active: true,
                  created_at: now, updated_at: now, created_by: actor, updated_by: actor }
              end
            )
          end

          scope = RolePermission.unscoped.where(role_id: @role.id)
          scope.where(permission_id: to_enable).update_all(is_active: true, updated_at: now, updated_by: actor)  if to_enable.any?
          scope.where(permission_id: to_disable).update_all(is_active: false, updated_at: now, updated_by: actor) if to_disable.any?
        end
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
end

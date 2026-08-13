# frozen_string_literal: true

module Api
  module Users
    # Permisos globales concedidos directamente a un usuario (sub-tab "Permisos
    # globales" del panel "Gestionar accesos" de /configurations/users).
    #
    # Reemplaza `GET /api/User/global-permissions?userId=N` y el par
    # `POST|DELETE /api/Permission/bulk-global-permissions`, que obligaba al
    # cliente a calcular el delta y mandar DOS peticiones —una de altas y otra de
    # bajas— que podían quedar a medias si la segunda fallaba. Acá el cuerpo lleva
    # el conjunto final y el servidor resuelve el delta en una transacción.
    #
    # Se declara con `resource` (singular): el conjunto de permisos de un usuario
    # es uno solo, así que no lleva id propio y se reemplaza entero con PUT.
    #
    # ⚠️ Solo acepta permisos `global`. Un permiso por compañía se concede con un
    # rol; permitirlo acá abriría una vía de concesión que se saltea la compañía.
    class PermissionsController < AuthorizedController
      before_action :authorize_action
      before_action :load_user

      PERMISSION = 'Configurations_Permissions_GlobalAccess'

      # GET /api/users/:user_id/permissions
      def show
        render json: ApiResponse.success(assigned.map { |p| serialize(p) }).to_h
      end

      # PUT /api/users/:user_id/permissions
      #
      # Reemplazo completo: lo que no venga en `PermissionIds` queda revocado.
      def update
        ids     = Array(params[:PermissionIds]).map(&:to_i).uniq
        globals = Permission.global.where(id: ids).pluck(:id)
        rejected = ids - globals

        if rejected.any?
          return render json: ApiResponse.error(
            "Solo se pueden asignar permisos globales. Rechazados: #{rejected.join(', ')}"
          ).to_h, status: :unprocessable_content
        end

        replace_assignments(globals)

        render json: ApiResponse.success(assigned.map { |p| serialize(p) },
                                         message: 'Permisos globales actualizados con éxito.').to_h
      end

      private

      def authorize_action
        require_permission!(PERMISSION)
      end

      # `unscoped`: también se gestionan los accesos de un usuario dado de baja.
      def load_user
        @user = User.unscoped.find_by(id: params[:user_id])
        return if @user

        render json: ApiResponse.not_found('El usuario no existe.').to_h, status: :not_found
      end

      def assigned
        Permission.where(id: UserPermission.where(user_id: @user.id).select(:permission_id))
                  .order(:name)
      end

      # Reasigna en LOTE: tres sentencias como mucho (un INSERT y dos UPDATE),
      # nunca una por checkbox — §1.6 del estándar nombra este caso exacto como el
      # equivalente del N+1 al escribir.
      #
      # Se consulta con `unscoped` porque la tabla tiene soft delete: si se mirara
      # solo lo activo, volver a conceder un permiso revocado chocaría contra el
      # índice único en vez de reactivar la fila que ya está.
      #
      # `insert_all`/`update_all` no disparan callbacks, así que las columnas de
      # auditoría que normalmente pone `Auditable` se escriben a mano acá (§2.2).
      # Tampoco disparan validaciones — por eso el filtro de `global` se hace
      # arriba contra `Permission.global`, y no se delega en el modelo.
      def replace_assignments(ids)
        now   = Time.current
        actor = Current.user&.email || 'system'

        UserPermission.transaction do
          existing   = UserPermission.unscoped.where(user_id: @user.id)
                                     .pluck(:permission_id, :is_active).to_h
          to_insert  = ids - existing.keys
          to_enable  = ids.select { |id| existing[id] == false }
          to_disable = existing.select { |id, active| active && ids.exclude?(id) }.keys

          if to_insert.any?
            UserPermission.insert_all(
              to_insert.map do |permission_id|
                { user_id: @user.id, permission_id: permission_id, is_active: true,
                  created_at: now, updated_at: now, created_by: actor, updated_by: actor }
              end
            )
          end

          scope = UserPermission.unscoped.where(user_id: @user.id)
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

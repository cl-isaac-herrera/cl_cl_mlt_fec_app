# frozen_string_literal: true

module Api
  module Users
    # El rol de INSTALACIÓN de un usuario (docs/PLAN-ROLES-POR-ALCANCE.md).
    #
    # Es `resource` singular y no `resources`: un usuario tiene UN rol de
    # instalación (o ninguno), no una colección — por eso no lleva id propio y
    # se reemplaza entero con PUT (`CLAUDE.md` §28). No depende de ninguna
    # compañía activa: vive en `users.installation_role_id`, no en una tabla de
    # asignación.
    #
    # Reemplaza al viejo `GET|PUT /api/users/:id/role` para el alcance de
    # instalación — ese endpoint asignaba el rol EN LA COMPAÑÍA ACTIVA y hoy
    # ese caso lo cubre `PUT /api/users/:id/companies` (rol por compañía).
    # ⚠️ Nombre PLURAL a propósito, aunque el recurso sea singular
    # (`resource :installation_role`): Rails busca el controller de un
    # `resource` singular en plural (`resource :profile` → `ProfilesController`,
    # CLAUDE.md §28) — `InstallationRoleController` (singular) no resuelve.
    class InstallationRolesController < AuthorizedController
      before_action :authorize_action
      before_action :load_user

      PERMISSION = 'Configurations_Users_ManageAccess'

      # GET /api/users/:user_id/installation_role
      def show
        role = @user.installation_role
        render json: ApiResponse.success(role ? serialize(role) : nil).to_h
      end

      # PUT /api/users/:user_id/installation_role
      #
      # `{ "RoleId": null }` (o sin la llave) remueve el rol de instalación.
      def update
        role_id = params[:RoleId]

        if role_id.nil?
          @user.update!(installation_role_id: nil)
          return render json: ApiResponse.success(nil, message: 'Rol de instalación removido.').to_h
        end

        role = Role.installation.find_by(id: role_id)
        unless role
          return render json: ApiResponse.error('El rol no existe.').to_h,
                        status: :unprocessable_content
        end

        @user.update!(installation_role: role)
        render json: ApiResponse.success(serialize(role), message: 'Asignación realizada correctamente.').to_h
      end

      private

      def authorize_action
        require_permission!(PERMISSION)
      end

      # `unscoped`: se pueden gestionar los accesos de un usuario dado de baja.
      def load_user
        @user = User.unscoped.find_by(id: params[:user_id])
        return if @user

        render json: ApiResponse.not_found('El usuario no existe.').to_h, status: :not_found
      end

      def serialize(role)
        { RoleId: role.id, RoleName: role.name }
      end
    end
  end
end

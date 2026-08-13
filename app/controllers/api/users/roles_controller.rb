# frozen_string_literal: true

module Api
  module Users
    # El rol de un usuario en la compañía activa.
    #
    # Es `resource` singular y no `resources`: un usuario tiene un rol por
    # compañía, no una colección — por eso no lleva id propio y se reemplaza
    # entero con PUT (`CLAUDE.md` §28).
    #
    # Reemplaza `GET /api/Rol/GetRolUserCompAssign?rolId=0&companyId=N`, que
    # devolvía las asignaciones de TODOS los usuarios de la compañía para que el
    # cliente buscara la suya, y `POST /api/Rol/AssignRolByUserComp`, que exigía
    # mandar el id de la asignación existente (`RolByUser`) para distinguir alta
    # de edición. Acá eso lo resuelve el servidor.
    #
    # La compañía sale de la sesión, nunca del cuerpo: nadie puede asignar roles
    # en una compañía que no tiene activa.
    class RolesController < AuthorizedController
      before_action :authorize_action
      before_action :require_active_company
      before_action :load_user

      PERMISSION = 'Configurations_Users_ManageAccess'

      # GET /api/users/:user_id/role
      def show
        assignment = current_assignment

        render json: ApiResponse.success(
          assignment ? { RoleId: assignment.role_id, RoleName: assignment.role.name } : nil
        ).to_h
      end

      # PUT /api/users/:user_id/role
      def update
        role = Role.find_by(id: params[:RoleId])
        unless role
          return render json: ApiResponse.error('El rol no existe.').to_h,
                        status: :unprocessable_content
        end

        assign(role)

        render json: ApiResponse.success({ RoleId: role.id, RoleName: role.name },
                                         message: 'Asignación realizada correctamente.').to_h
      end

      private

      def authorize_action
        require_permission!(PERMISSION)
      end

      def require_active_company
        return if Current.company_id

        render json: ApiResponse.error('Seleccione una compañía antes de asignar roles.').to_h,
               status: :unprocessable_content
      end

      # `unscoped`: se pueden gestionar los accesos de un usuario dado de baja.
      def load_user
        @user = User.unscoped.find_by(id: params[:user_id])
        return if @user

        render json: ApiResponse.not_found('El usuario no existe.').to_h, status: :not_found
      end

      def current_assignment
        UserRole.includes(:role).find_by(user_id: @user.id, company_id: Current.company_id)
      end

      # Un rol por usuario y compañía: se revoca lo que hubiera y se concede el
      # nuevo. Se consulta con `unscoped` para reactivar la fila revocada en vez
      # de insertar otra al lado — sin eso, asignar y desasignar el mismo rol
      # varias veces deja basura acumulada en `user_roles`.
      def assign(role)
        UserRole.transaction do
          UserRole.unscoped
                  .where(user_id: @user.id, company_id: Current.company_id, is_active: true)
                  .where.not(role_id: role.id)
                  .update_all(is_active: false, updated_at: Time.current, updated_by: actor)

          existing = UserRole.unscoped.find_by(user_id: @user.id, company_id: Current.company_id,
                                               role_id: role.id)
          if existing
            existing.update!(is_active: true)
          else
            UserRole.create!(user: @user, role: role, company_id: Current.company_id)
          end
        end
      end

      # `update_all` no dispara callbacks, así que las columnas de auditoría que
      # llena `Auditable` hay que escribirlas a mano (§4.5 del estándar).
      def actor
        Current.user&.email || 'system'
      end
    end
  end
end

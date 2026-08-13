# frozen_string_literal: true

module Api
  module Users
    # Compañías asignadas a un usuario (`users_by_companies`). Definen qué puede
    # elegir en el selector del toolbar y, por lo tanto, sobre qué opera.
    #
    # Sirve a dos pantallas del mismo módulo:
    #   - panel de edición → llena el selector "Compañía para probar credenciales";
    #   - tab "Asignación de compañías" → es la lista de la derecha (asignadas).
    #
    # Reemplaza `GET /api/User/companies?userId=N`, `GET /api/User/assigned-companies?userId=N`
    # y el par `POST /api/User/bulk-assign-companies` + `POST /api/User/bulk-unassign-companies`.
    # El .NET obligaba al cliente a calcular el delta y mandar DOS peticiones —altas
    # y bajas— que podían quedar a medias; acá el cuerpo lleva el conjunto final.
    #
    # Se declara con `resource` (singular): el conjunto de compañías de un usuario
    # es uno solo, así que no lleva id propio y se reemplaza entero con PUT.
    class CompaniesController < AuthorizedController
      include AssignableCompanies

      before_action :authorize_action
      before_action :load_user

      # Leer: cualquiera de las dos pantallas. Escribir: solo la de asignación.
      READ_PERMISSIONS = %w[Configurations_Users_Update
                            Configurations_Users_CompanyAssignment].freeze
      WRITE_PERMISSION = 'Configurations_Users_CompanyAssignment'

      # GET /api/users/:user_id/companies
      def show
        render json: ApiResponse.success(assigned.map { |c| serialize(c) }).to_h
      end

      # PUT /api/users/:user_id/companies
      #
      # Reemplazo completo, pero SOLO dentro del alcance de quien guarda: lo que
      # no venga en `CompanyIds` queda desasignado **si el solicitante podía
      # asignarlo**. Ver la nota de `replace_assignments`.
      def update
        ids     = Array(params[:CompanyIds]).map(&:to_i).uniq
        unknown = ids - Company.where(id: ids).pluck(:id)

        if unknown.any?
          return render json: ApiResponse.error("Compañías inexistentes: #{unknown.join(', ')}").to_h,
                        status: :unprocessable_content
        end

        manageable = assignable_companies.pluck(:id)
        outside    = ids - manageable

        # Se rechaza en vez de ignorarse en silencio: si el cliente mandó algo
        # fuera de alcance, su idea del estado final y la del servidor difieren, y
        # aplicar "casi todo" es peor que no aplicar nada.
        if outside.any?
          return render json: ApiResponse.forbidden(
            "No puede asignar compañías fuera de su alcance: #{outside.join(', ')}"
          ).to_h, status: :forbidden
        end

        replace_assignments(ids, manageable)

        render json: ApiResponse.success(assigned.map { |c| serialize(c) },
                                         message: 'Cambios aplicados exitosamente.').to_h
      end

      private

      def authorize_action
        if action_name == 'update'
          require_permission!(WRITE_PERMISSION)
        else
          require_any_permission!(*READ_PERMISSIONS)
        end
      end

      # `unscoped`: también se administran las compañías de un usuario dado de baja.
      def load_user
        @user = User.unscoped.find_by(id: params[:user_id])
        return if @user

        render json: ApiResponse.not_found('El usuario no existe.').to_h, status: :not_found
      end

      def assigned
        Company.assigned_to(@user.id).order(:name)
      end

      # Reasigna en LOTE: tres sentencias como mucho (un INSERT y dos UPDATE), nunca
      # una por compañía movida — §1.6 del estándar nombra este caso como el
      # equivalente del N+1 al escribir.
      #
      # Se consulta con `unscoped` porque `users_by_companies` tiene soft delete y su
      # índice único NO excluye a las inactivas: sin eso, volver a asignar una
      # compañía desasignada chocaría contra el índice en vez de reactivar la fila.
      #
      # `insert_all`/`update_all` no disparan callbacks, así que las columnas de
      # auditoría que normalmente pone `Auditable` se escriben a mano acá (§2.2).
      #
      # ⚠️ `manageable` acota QUÉ se puede revocar, y no es un detalle: una compañía
      # que el usuario tiene asignada pero que el solicitante no administra nunca
      # aparece en el panel, así que tampoco viaja en `CompanyIds`. Sin este filtro,
      # el reemplazo completo se la revocaría en silencio — el administrador de una
      # sociedad le sacaría al usuario el acceso a otra sin enterarse.
      def replace_assignments(ids, manageable)
        now   = Time.current
        actor = Current.user&.email || 'system'

        UsersByCompany.transaction do
          existing   = UsersByCompany.unscoped.where(user_id: @user.id)
                                     .pluck(:company_id, :is_active).to_h
          to_insert  = ids - existing.keys
          to_enable  = ids.select { |id| existing[id] == false }
          to_disable = existing.select do |id, active|
            active && ids.exclude?(id) && manageable.include?(id)
          end.keys

          if to_insert.any?
            UsersByCompany.insert_all(
              to_insert.map do |company_id|
                { user_id: @user.id, company_id: company_id, is_active: true,
                  created_at: now, updated_at: now, created_by: actor, updated_by: actor }
              end
            )
          end

          scope = UsersByCompany.unscoped.where(user_id: @user.id)
          scope.where(company_id: to_enable).update_all(is_active: true, updated_at: now, updated_by: actor)  if to_enable.any?
          scope.where(company_id: to_disable).update_all(is_active: false, updated_at: now, updated_by: actor) if to_disable.any?
        end
      end

      def serialize(company)
        { Id: company.id, Name: company.name }
      end
    end
  end
end

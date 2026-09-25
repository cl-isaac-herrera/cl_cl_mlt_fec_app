# frozen_string_literal: true

module Api
  module Users
    # Compañías asignadas a un usuario, CON el rol de compañía que tiene en cada
    # una (`users_by_companies.role_id` — docs/PLAN-ROLES-POR-ALCANCE.md: una
    # fila da el acceso y el rol a la vez).
    #
    # Sirve a dos pantallas del mismo módulo:
    #   - panel de edición → llena el selector "Compañía para probar credenciales";
    #   - tab "Compañías" del panel "Gestionar accesos" → lista con su rol por fila.
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
        render json: ApiResponse.success(assigned.map { |a| serialize(a) }).to_h
      end

      # PUT /api/users/:user_id/companies
      #
      # Cuerpo: `{ Assignments: [{ CompanyId, RoleId }, ...] }`. Reemplazo
      # completo, pero SOLO dentro del alcance de quien guarda: lo que no venga
      # queda desasignado **si el solicitante podía asignarlo**. Ver la nota de
      # `replace_assignments`.
      def update
        assignments = parse_assignments
        return if performed?

        ids     = assignments.keys
        unknown = ids - Company.where(id: ids).pluck(:id)
        if unknown.any?
          return render json: ApiResponse.error("Compañías inexistentes: #{unknown.join(', ')}").to_h,
                        status: :unprocessable_content
        end

        invalid_roles = assignments.values.uniq - Role.company.where(id: assignments.values.uniq).pluck(:id)
        if invalid_roles.any?
          return render json: ApiResponse.error("Roles de compañía inexistentes: #{invalid_roles.join(', ')}").to_h,
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

        replace_assignments(assignments, manageable)

        render json: ApiResponse.success(assigned.map { |a| serialize(a) },
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

      # `{ CompanyId => RoleId }`. Cada compañía necesita su rol: no hay
      # default implícito, para no adivinar con qué permisos queda un acceso
      # nuevo.
      def parse_assignments
        rows = Array(params[:Assignments])
        result = {}
        rows.each do |row|
          company_id = (row[:CompanyId] || row['CompanyId']).to_i
          role_id    = row[:RoleId] || row['RoleId']
          if role_id.nil?
            render json: ApiResponse.error("Falta el rol de compañía para CompanyId=#{company_id}").to_h,
                   status: :unprocessable_content
            return {}
          end
          result[company_id] = role_id.to_i
        end
        result
      end

      def assigned
        UsersByCompany.where(user_id: @user.id, is_active: true)
                      .includes(:company, :role)
                      .joins(:company)
                      .order('companies.name')
      end

      # Reasigna en LOTE: como mucho un INSERT, un UPDATE de bajas y un UPDATE
      # por cada rol de compañía distinto entre las reactivaciones/cambios de
      # rol — nunca una escritura por checkbox (§1.6 del estándar).
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
      # aparece en el panel, así que tampoco viaja en `Assignments`. Sin este filtro,
      # el reemplazo completo se la revocaría en silencio — el administrador de una
      # sociedad le sacaría al usuario el acceso a otra sin enterarse.
      def replace_assignments(role_by_company_id, manageable)
        now   = Time.current
        actor = Current.user&.email || 'system'
        ids   = role_by_company_id.keys

        UsersByCompany.transaction do
          existing = UsersByCompany.unscoped.where(user_id: @user.id)
                                   .pluck(:company_id, :is_active, :role_id)
                                   .each_with_object({}) { |(cid, active, rid), h| h[cid] = [active, rid] }

          to_insert  = ids - existing.keys
          to_disable = existing.select { |id, (active, _)| active && ids.exclude?(id) && manageable.include?(id) }.keys

          if to_insert.any?
            UsersByCompany.insert_all(
              to_insert.map do |company_id|
                { user_id: @user.id, company_id: company_id, role_id: role_by_company_id[company_id],
                  is_active: true, created_at: now, updated_at: now, created_by: actor, updated_by: actor }
              end
            )
          end

          scope = UsersByCompany.unscoped.where(user_id: @user.id)
          scope.where(company_id: to_disable).update_all(is_active: false, updated_at: now, updated_by: actor) if to_disable.any?

          # Lo que ya existía y sigue en la lista: reactivar y/o cambiar de rol,
          # agrupado por rol destino para que sea un UPDATE por rol distinto y
          # no uno por compañía.
          to_touch = ids.select do |id|
            existing.key?(id) && (existing[id][0] == false || existing[id][1] != role_by_company_id[id])
          end
          to_touch.group_by { |id| role_by_company_id[id] }.each do |role_id, company_ids|
            scope.where(company_id: company_ids)
                 .update_all(is_active: true, role_id: role_id, updated_at: now, updated_by: actor)
          end
        end
      end

      def serialize(assignment)
        { Id: assignment.company.id, Name: assignment.company.name,
          RoleId: assignment.role_id, RoleName: assignment.role.name }
      end
    end
  end
end

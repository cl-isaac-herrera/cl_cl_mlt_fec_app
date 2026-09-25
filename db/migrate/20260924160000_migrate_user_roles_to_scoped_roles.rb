# frozen_string_literal: true

# Tercer paso del modelo de roles por alcance (docs/PLAN-ROLES-POR-ALCANCE.md,
# Fase 2). Traduce el estado de `user_roles` a `users_by_companies.role_id`
# (que pasa a NOT NULL acá) y deja `role_permissions` sin alcances cruzados.
#
# Clases locales mínimas y no los modelos de la app: los modelos ya conocen el
# esquema NUEVO (`Role#scope`, etc.) y esta migración necesita leer el estado
# TAL COMO QUEDÓ tras la migración anterior + el `db:seed` que la sigue, sin el
# `default_scope` de `SoftDeletable` escondiendo justo las filas que hay que
# tocar (CLAUDE.md §28).
class MigrateUserRolesToScopedRoles < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = 'users'
  end

  class MigrationRole < ActiveRecord::Base
    self.table_name = 'roles'
  end

  class MigrationUserRole < ActiveRecord::Base
    self.table_name = 'user_roles'
  end

  class MigrationUserPermission < ActiveRecord::Base
    self.table_name = 'user_permissions'
  end

  class MigrationRolePermission < ActiveRecord::Base
    self.table_name = 'role_permissions'
  end

  class MigrationUsersByCompany < ActiveRecord::Base
    self.table_name = 'users_by_companies'
  end

  SYS_EMAIL = 'sys@clavisco.com'
  ADMIN_ROLE_NAME = 'Administrador'

  def up
    sys = MigrationUser.find_by(email: SYS_EMAIL)
    company_admin_role = MigrationRole.find_by(name: ADMIN_ROLE_NAME, scope: 'company')

    migrate_users_by_companies(sys, company_admin_role)
    change_column_null :users_by_companies, :role_id, false

    warn_about_stray_global_grants(sys)
    deactivate_cross_scope_role_permissions
  end

  def down
    change_column_null :users_by_companies, :role_id, true
  end

  private

  # `users_by_companies.role_id` ← el `user_role` activo más reciente para el
  # mismo (user_id, company_id). `user_roles` nunca tuvo índice único sobre ese
  # par, así que puede haber más de uno: gana el más reciente.
  def migrate_users_by_companies(sys, company_admin_role)
    MigrationUsersByCompany.where(is_active: true).find_each do |assignment|
      candidates = MigrationUserRole
                   .where(user_id: assignment.user_id, company_id: assignment.company_id, is_active: true)
                   .order(updated_at: :desc, id: :desc)
      user_role = candidates.first

      if candidates.size > 1
        warn_migration("user_id=#{assignment.user_id} company_id=#{assignment.company_id} " \
                        "tenía #{candidates.size} user_roles activos — se usó el más reciente " \
                        "(role_id=#{user_role.role_id}).")
      end

      if user_role
        assignment.update!(role_id: user_role.role_id)
      elsif sys && assignment.user_id == sys.id && company_admin_role
        warn_migration("user_id=#{assignment.user_id} (sys) company_id=#{assignment.company_id} " \
                        'no tenía user_role — se le asignó el rol de compañía Administrador.')
        assignment.update!(role_id: company_admin_role.id)
      else
        warn_migration("user_id=#{assignment.user_id} company_id=#{assignment.company_id} " \
                        'no tenía user_role y no es sys — el acceso se dio de baja.')
        assignment.update!(is_active: false)
      end
    end
  end

  # Sin importador real todavía (Fase 0, decisión 1): cualquier permiso de
  # instalación concedido directo a otro usuario que no sea sys queda como
  # deuda manual — se avisa, no se inventa un rol de instalación para él.
  def warn_about_stray_global_grants(sys)
    scope = MigrationUserPermission.where(is_active: true)
    scope = scope.where.not(user_id: sys.id) if sys
    stray_user_ids = scope.distinct.pluck(:user_id)
    return if stray_user_ids.empty?

    warn_migration("usuarios con permisos de instalación directos fuera de sys: #{stray_user_ids.join(', ')}. " \
                    'Asignarles un rol de instalación a mano.')
  end

  # `role_permissions` activos cuyo permiso cambió de alcance en el commit
  # anterior (de `company` a `installation`) quedan mezclados con el rol: el
  # upsert de `db/seeds.rb` solo agrega, nunca revoca lo que dejó de
  # corresponder.
  def deactivate_cross_scope_role_permissions
    count = MigrationRolePermission
            .joins('INNER JOIN roles ON roles.id = role_permissions.role_id')
            .joins('INNER JOIN permissions ON permissions.id = role_permissions.permission_id')
            .where(role_permissions: { is_active: true })
            .where('roles.scope != permissions.scope')
            .update_all(is_active: false)
    warn_migration("role_permissions dados de baja por alcance cruzado: #{count}") if count.positive?
  end

  def warn_migration(message)
    Rails.logger.warn("[roles-por-alcance] #{message}")
    puts "[roles-por-alcance] #{message}"
  end
end

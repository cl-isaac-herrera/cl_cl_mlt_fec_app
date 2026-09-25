# frozen_string_literal: true

# Reemplaza `permissions.type` (normal/global) por `permissions.scope`
# (company/installation) y agrega `roles.scope`. Ver docs/PLAN-ROLES-POR-ALCANCE.md.
#
# El backfill de acá solo traduce 1 a 1 el valor que ya tenía cada permiso
# (normal→company, global→installation): la reclasificación real del catálogo
# (mover a `installation` permisos que hoy son `normal`, como los de Usuarios o
# Conexiones) la aplica `db/seeds.rb` al correr `db:seed` después de esta
# migración — es un cambio de catálogo, no de estructura (CLAUDE.md §28).
class AddScopeToPermissionsAndRoles < ActiveRecord::Migration[8.1]
  class MigrationPermission < ActiveRecord::Base
    self.table_name = 'permissions'
  end

  def up
    add_column :permissions, :scope, :string
    add_column :roles, :scope, :string, null: false, default: 'company'

    MigrationPermission.reset_column_information
    MigrationPermission.where(type: 'normal').update_all(scope: 'company')
    MigrationPermission.where(type: 'global').update_all(scope: 'installation')

    change_column_default :permissions, :scope, from: nil, to: 'company'
    change_column_null :permissions, :scope, false
    remove_column :permissions, :type
  end

  def down
    add_column :permissions, :type, :string, null: false, default: 'normal'

    MigrationPermission.reset_column_information
    MigrationPermission.where(scope: 'company').update_all(type: 'normal')
    MigrationPermission.where(scope: 'installation').update_all(type: 'global')

    remove_column :permissions, :scope
    remove_column :roles, :scope
  end
end

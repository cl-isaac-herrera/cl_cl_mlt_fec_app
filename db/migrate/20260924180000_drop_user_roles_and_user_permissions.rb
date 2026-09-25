# frozen_string_literal: true

# Última pieza del modelo de roles por alcance (docs/PLAN-ROLES-POR-ALCANCE.md,
# Fase 6): `user_roles` y `user_permissions` quedaron sin ningún lector desde
# que `Api::AuthorizedController#permission?` pasó a resolver todo contra
# `users.installation_role_id` y `users_by_companies.role_id`
# (`20260924160000_migrate_user_roles_to_scoped_roles.rb` ya tradujo los datos
# vigentes a esas dos columnas).
#
# No hace falta preservar los datos de estas dos tablas: lo que importaba de
# ellas ya vive en su destino nuevo. `drop_table` con `force: :cascade` porque
# ambas tienen `add_foreign_key` desde su creación.
class DropUserRolesAndUserPermissions < ActiveRecord::Migration[8.1]
  def up
    drop_table :user_roles, force: :cascade
    drop_table :user_permissions, force: :cascade
  end

  def down
    create_table :user_roles do |t|
      t.references :user,    null: false, foreign_key: true
      t.references :role,    null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.boolean :is_active, default: true, null: false
      t.string :created_by
      t.string :updated_by
      t.timestamps
    end

    create_table :user_permissions do |t|
      t.references :user,       null: false, foreign_key: true
      t.references :permission, null: false, foreign_key: true
      t.boolean :is_active, default: true, null: false
      t.string :created_by
      t.string :updated_by
      t.timestamps
    end
    add_index :user_permissions, %i[user_id permission_id], unique: true
  end
end

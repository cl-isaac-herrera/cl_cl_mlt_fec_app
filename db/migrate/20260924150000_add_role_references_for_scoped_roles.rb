# frozen_string_literal: true

# Segundo paso del modelo de roles por alcance (docs/PLAN-ROLES-POR-ALCANCE.md):
# el rol de instalación del usuario, y el rol de compañía en la fila que ya da
# el acceso (`users_by_companies`). Las dos nacen NULLABLE — la migración de
# datos siguiente (`20260924160000`) las llena antes de que
# `users_by_companies.role_id` pase a NOT NULL.
class AddRoleReferencesForScopedRoles < ActiveRecord::Migration[8.1]
  def change
    add_reference :users_by_companies, :role, foreign_key: true
    add_reference :users, :installation_role, foreign_key: { to_table: :roles }
  end
end

# frozen_string_literal: true

# Asignación usuario ↔ compañía: define qué compañías puede seleccionar cada usuario.
# Reemplaza a `CompanyByUser` del .NET.
#
# Las llaves foráneas apuntan al `id` interno de cada tabla (no al uuid), que es lo
# que hace eficientes los joins. `is_active` habilita el borrado lógico: nunca se
# hace DELETE físico (§2.2).
class CreateUsersByCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :users_by_companies do |t|
      t.references :user,    null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true

      t.boolean :is_active, default: true, null: false
      t.string  :created_by
      t.string  :updated_by

      t.timestamps
    end

    # Un usuario no puede estar asignado dos veces a la misma compañía.
    add_index :users_by_companies, %i[user_id company_id], unique: true
  end
end

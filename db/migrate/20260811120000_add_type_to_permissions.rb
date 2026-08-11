# frozen_string_literal: true

# Tipo de permiso: 'normal' (se concede por compañía) o 'global' (aplica a nivel
# de aplicación, sin depender de la compañía activa).
#
# ⚠️ `type` es el nombre que ActiveRecord usa por convención como discriminador de
# Single Table Inheritance. Para que la columna se comporte como un campo normal,
# el modelo `Permission` declara `self.inheritance_column = nil`. Sin eso, leer
# cualquier fila revienta con `ActiveRecord::SubclassNotFound: The single-table
# inheritance mechanism failed to locate the subclass: 'normal'`.
#
# El valor válido se valida en el modelo (`Permission::TYPES`) y no con un CHECK
# constraint, para no meter SQL específico del motor.
class AddTypeToPermissions < ActiveRecord::Migration[8.1]
  def change
    add_column :permissions, :type, :string, null: false, default: 'normal'
  end
end

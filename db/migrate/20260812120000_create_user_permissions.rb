# frozen_string_literal: true

# Concesión directa de un permiso a un usuario, sin pasar por un rol.
#
# Es la segunda —y última— vía de concesión del producto, y existe solo para los
# permisos `global`: los que no dependen de la compañía activa (ver
# `Permission::TYPES`). Los `normal` se siguen concediendo únicamente por rol.
#
# ⚠️ NO lleva `company_id`, y es la razón de ser de la tabla. `user_roles` ata la
# concesión a una compañía; un permiso global aplica a nivel de aplicación, así
# que atarlo a una compañía obligaría a repetir la misma fila por cada una y a
# mantenerlas sincronizadas a mano.
#
# CLAVISCO-PLATFORM-STANDARDS §4.1 no la lista entre las tablas obligatorias
# porque describe el mínimo (permisos por rol). Reemplaza a `PermissionByUser`
# del API .NET, que alimentaba `/api/Permission/bulk-global-permissions`.
class CreateUserPermissions < ActiveRecord::Migration[8.1]
  def change
    create_table :user_permissions do |t|
      t.references :user,       null: false, foreign_key: true
      t.references :permission, null: false, foreign_key: true

      t.boolean :is_active, default: true, null: false
      t.string  :created_by
      t.string  :updated_by

      t.timestamps
    end

    # Un permiso no se le puede conceder dos veces al mismo usuario. El índice NO
    # excluye a las filas inactivas a propósito: revocar deja la fila (soft delete)
    # y volver a conceder tiene que reactivar esa misma, no insertar otra al lado.
    add_index :user_permissions, %i[user_id permission_id], unique: true
  end
end

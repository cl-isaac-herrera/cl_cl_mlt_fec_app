# frozen_string_literal: true

# Renombra los tres permisos de la pantalla de compañías a la convención
# `{Módulo}_{Recurso}_{Acción}` (CLAVISCO-PLATFORM-STANDARDS §4.4), al migrar sus
# endpoints a Rails (`CLAUDE.md` §28).
#
#   S_Company       → Configurations_Companies_ListAccess
#   F_CreateCompany → Configurations_Companies_Create
#   F_ModifyCompany → Configurations_Companies_Update
#
# Los nombres viejos vienen de los ítems de submenú del Angular ("Acceso a
# SubMenu de Compañías"): dicen dónde estaba el botón, no qué autorizan.
#
# La equivalencia con el nombre de origen vive en `db/permission_name_map.yml`,
# que la importación desde SQL Server tiene que leer: allá las filas de
# `PermissionByRol` siguen apuntando al nombre viejo y, sin traducir, los roles
# reales perderían el acceso en silencio.
#
# Va como migración y no solo como cambio de `db/seeds.rb` porque el seed borra y
# recrea el catálogo entero, lo que en una base viva se lleva puestas las
# asignaciones de `role_permissions` y `user_permissions` (`CLAUDE.md` §28).
class RenameCompanyPermissions < ActiveRecord::Migration[8.1]
  RENAME = {
    'S_Company'       => 'Configurations_Companies_ListAccess',
    'F_CreateCompany' => 'Configurations_Companies_Create',
    'F_ModifyCompany' => 'Configurations_Companies_Update'
  }.freeze

  # Clase mínima y local: la migración no debe depender del modelo de la app, que
  # cambia con el tiempo (y cuyo `default_scope` escondería justo lo que se quiere
  # tocar). `inheritance_column = nil` porque `type` acá es el tipo de permiso del
  # negocio, no STI.
  class MigrationPermission < ActiveRecord::Base
    self.table_name = 'permissions'
    self.inheritance_column = nil
  end

  def up
    RENAME.each do |old_name, new_name|
      # Si el destino ya existe (base sembrada de cero con el nombre nuevo), no
      # hay nada que renombrar: hacerlo dejaría dos filas con el mismo nombre.
      next if MigrationPermission.exists?(name: new_name)

      MigrationPermission.where(name: old_name)
                         .update_all(name: new_name, updated_at: Time.current)
    end
  end

  def down
    RENAME.each do |old_name, new_name|
      next if MigrationPermission.exists?(name: old_name)

      MigrationPermission.where(name: new_name)
                         .update_all(name: old_name, updated_at: Time.current)
    end
  end
end

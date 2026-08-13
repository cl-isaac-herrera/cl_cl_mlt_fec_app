# frozen_string_literal: true

# Aplica sobre la tabla `permissions` los cambios que hasta ahora solo vivían en
# `db/seeds.rb`.
#
# Hacía falta porque el seed **borra y recrea el catálogo entero**
# (`Permission.unscoped.delete_all`): sirve para levantar un ambiente de cero, no
# para una base con datos reales, donde borrar los permisos se lleva puestas las
# asignaciones de `role_permissions` y `user_permissions`. Un cambio de catálogo
# en una base viva es una migración, no un re-seed.
#
# Dos operaciones:
#   1. Renombrar `S_AsigUser` → `Configurations_Users_CompanyAssignment` (§4.4).
#      La equivalencia con el nombre de origen vive en
#      `db/permission_name_map.yml`, que la importación desde SQL Server tiene que
#      leer.
#   2. Dar de baja los permisos que quedaron sin ningún consumidor.
#
# ⚠️ Baja LÓGICA, no `DELETE`. Por tres razones:
#   · §2.2 del estándar prohíbe el borrado físico;
#   · las filas de `role_permissions` / `user_permissions` que los referencien
#     harían fallar la FK, y borrarlas en cascada destruiría la asignación real de
#     un rol sin dejar rastro;
#   · con `is_active = false` alcanza: `require_permission!`,
#     `AuthorizationService` y el catálogo filtran por `is_active`, así que un
#     permiso inactivo no concede nada y desaparece de la UI.
class ApplyPermissionCatalogChanges < ActiveRecord::Migration[8.1]
  RENAME = { 'S_AsigUser' => 'Configurations_Users_CompanyAssignment' }.freeze

  # Solo los que tienen CERO referencias en la app. Verificado con grep sobre
  # `app/` y `config/` antes de escribir esta lista.
  #
  # NO se incluyen a propósito, aunque el negocio ya no los use:
  #   · `S_Groups` y los seis `Configurations_Groups_*`: los sigue evaluando
  #     `group_controller.js` y `S_Groups` gatea el nodo de menú. Se dan de baja
  #     cuando se borre la pantalla de grupos, no antes — si no, la pantalla
  #     quedaría inalcanzable sin que nadie lo haya decidido.
  #   · `S_RegUser`: hay una decisión pendiente sobre él en el map (los dos
  #     nombres existen en el catálogo de origen, no es un rename puro).
  #   · `Configurations_Companies_ViewGroupCompanies`: SÍ tiene consumidor — es la
  #     vía de escape del alcance de asignación de compañías
  #     (`AssignableCompanies::SEE_ALL_COMPANIES`).
  DEACTIVATE = %w[
    S_CompUser
    Configurations_Users_ViewGroupUsers
    Configurations_Companies_ChangeGroup
    Configurations_Groups_ViewAllApplicationGroups
  ].freeze

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

    MigrationPermission.where(name: DEACTIVATE, is_active: true)
                       .update_all(is_active: false, updated_at: Time.current)
  end

  def down
    MigrationPermission.where(name: DEACTIVATE, is_active: false)
                       .update_all(is_active: true, updated_at: Time.current)

    RENAME.each do |old_name, new_name|
      next if MigrationPermission.exists?(name: old_name)

      MigrationPermission.where(name: new_name)
                         .update_all(name: old_name, updated_at: Time.current)
    end
  end
end

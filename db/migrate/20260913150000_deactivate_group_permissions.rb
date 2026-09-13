# frozen_string_literal: true

# Da de baja los seis permisos que quedaban de la pantalla `/configurations/group`,
# borrada en este mismo cambio.
#
# No hay grupos de compañías en esta versión (CLAUDE.md §31): el aislamiento entre
# clientes lo da el despliegue —una instancia por cliente— y no una columna. La
# pantalla era lo único que todavía evaluaba estos permisos, así que hasta ahora no
# se podían dar de baja sin dejarla inalcanzable; con la pantalla borrada ya no
# tienen ningún consumidor. Verificado con grep sobre `app/` y `config/`.
#
# `S_Groups` gateaba el nodo de menú; los otros cinco los leía `group_controller.js`
# para habilitar sus botones.
#
# ⚠️ Migración y no `db:seed`: el seed borra y recrea el catálogo entero
# (`Permission.unscoped.delete_all`), lo que en una base con datos reales se lleva
# puestas las asignaciones de `role_permissions` y `user_permissions` (CLAUDE.md §28).
# La lista tiene que quedar igual a la de `DEACTIVATED` en `db/seeds.rb`: esta
# migración es para la base que ya existe, el seed para la que se crea de cero, y las
# dos deben dejar el mismo estado final.
#
# ⚠️ Baja LÓGICA, no `DELETE`: §2.2 del estándar lo prohíbe, y borrar la fila
# arrastraría las de `role_permissions` / `user_permissions` que la referencien —
# destruyendo la asignación real de un rol sin dejar rastro. Con `is_active = false`
# alcanza: `require_permission!`, `AuthorizationService` y el catálogo filtran por
# `is_active`.
class DeactivateGroupPermissions < ActiveRecord::Migration[8.1]
  # ⚠️ `Configurations_Companies_ViewGroupCompanies` NO va acá, aunque tenga "Group"
  # en el nombre: es la vía de escape del alcance de asignación de compañías
  # (`AssignableCompanies::SEE_ALL_COMPANIES`) y sigue en uso.
  DEACTIVATE = %w[
    S_Groups
    Configurations_Groups_Create
    Configurations_Groups_Update
    Configurations_Groups_UpdateAllInApplication
    Configurations_Groups_DownloadFEPrintFormat
    Configurations_Groups_DownloadFEPrintFormatInAllGroups
  ].freeze

  # Clase mínima y local: la migración no debe depender del modelo de la app, que
  # cambia con el tiempo (y cuyo `default_scope` de `SoftDeletable` escondería justo
  # las filas que se quieren tocar). `inheritance_column = nil` porque `type` acá es
  # el tipo de permiso del negocio, no STI.
  class MigrationPermission < ActiveRecord::Base
    self.table_name = 'permissions'
    self.inheritance_column = nil
  end

  def up
    MigrationPermission.where(name: DEACTIVATE, is_active: true)
                       .update_all(is_active: false, updated_at: Time.current)
  end

  def down
    MigrationPermission.where(name: DEACTIVATE, is_active: false)
                       .update_all(is_active: true, updated_at: Time.current)
  end
end

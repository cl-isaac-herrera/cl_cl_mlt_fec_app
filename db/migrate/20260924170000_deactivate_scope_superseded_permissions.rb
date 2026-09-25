# frozen_string_literal: true

# Da de baja tres permisos que el modelo de roles por alcance dejó sin
# consumidor (docs/PLAN-ROLES-POR-ALCANCE.md, Fase 0 decisiones 3 y 5, y Fase 5):
#
# - `Configurations_Users_ViewAllApplicationUsers` ampliaba "los usuarios de mi
#   compañía" a "todos". Administrar usuarios pasó a ser un permiso de
#   INSTALACIÓN (`Api::UsersController#visible_users`), así que ya no hay un
#   alcance más chico del que ampliarse: siempre se ven todos.
# - `Configurations_Companies_ViewGroupCompanies` era la vía de escape de
#   `AssignableCompanies` para "ver todas las compañías". La reemplazó
#   `Configurations_Companies_ViewAllApplicationCompanies` (que ya cubría el
#   mismo caso y no dependía del concepto de "grupo", inexistente en esta
#   versión — CLAUDE.md §31).
# - `Configurations_Users_Access` gateaba el nodo de menú "Usuarios" (§ Fase 5,
#   "arreglo de paso"), duplicando a `Configurations_Users_ListAccess` — que es
#   el que de verdad exige `Api::UsersController#index`. El menú se unificó
#   para pedir este último, así que el primero queda sin ningún consumidor.
#
# ⚠️ Migración y no solo `db:seed`: el seed nunca borra ni reconstruye
# `role_permissions` (CLAUDE.md §28), así que una base que ya tenía alguno de
# estos tres concedido por rol se queda con la fila activa hasta que algo la
# toque explícitamente. La lista tiene que coincidir con `DEACTIVATED` en
# `db/seeds.rb`: esta migración es para la base que ya existe, el seed para la
# que se crea de cero.
#
# ⚠️ Baja LÓGICA, no `DELETE` (§2.2): con `is_active = false` alcanza, el
# catálogo y `permission?` ya filtran por ahí.
class DeactivateScopeSupersededPermissions < ActiveRecord::Migration[8.1]
  DEACTIVATE = %w[
    Configurations_Users_ViewAllApplicationUsers
    Configurations_Companies_ViewGroupCompanies
    Configurations_Users_Access
  ].freeze

  # Clase mínima y local: no depende del modelo de la app, cuyo
  # `default_scope` de `SoftDeletable` escondería justo las filas a tocar.
  class MigrationPermission < ActiveRecord::Base
    self.table_name = 'permissions'
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

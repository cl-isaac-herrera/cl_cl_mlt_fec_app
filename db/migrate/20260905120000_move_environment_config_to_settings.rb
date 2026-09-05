# frozen_string_literal: true

# Mueve la configuración de `environments` a `settings` y elimina la tabla.
#
# ── Por qué se elimina y no se deja como catálogo aparte ─────────────────────
# `environments` agrupaba lo que compartían todas las compañías de un mismo
# ambiente de Hacienda: las tres URIs y el número/fecha de resolución. Pero el
# despliegue de este producto es **una instancia por cliente** (`CLAUDE.md`
# §31, la misma razón por la que no existe `groups`): una instalación entera
# apunta a un solo ambiente, así que "el ambiente" no es una entidad con muchas
# filas — es una configuración de la instalación, exactamente lo que ya
# resuelve `settings` (§36). La tabla nunca se sembró en ninguna instalación
# real: por eso esta migración puede eliminarla sin dato que preservar, más
# allá del respaldo defensivo de `#migrate_existing_values` por si alguna la
# llegó a llenar a mano.
#
# ── Qué se descarta a propósito ───────────────────────────────────────────────
# · Las columnas de auditoría (`created_at`, `updated_at`, `created_by`,
#   `updated_by`, `is_active`) — `settings` ya las tiene nativas via
#   `Auditable` + `SoftDeletable`.
# · `is_prod` — decisión de producto (2026-09-05): con una instancia por
#   cliente ya no hay "dos ambientes" que un booleano tenga que distinguir.
#   Se pierde, no se migra a ningún lado.
#
# ── La FK en `companies` ──────────────────────────────────────────────────────
# `companies.environment_id` no tenía NINGÚN consumidor: ni formulario, ni
# controller, ni serializer (confirmado con grep sobre `app/` y `config/`
# antes de escribir esta migración). El único rastro eran los specs de
# aislamiento entre secciones, que se corrigieron en el mismo cambio.
class MoveEnvironmentConfigToSettings < ActiveRecord::Migration[8.1]
  GROUP = 'HACIENDA_FE'

  # code                               description                                                is_visible
  SETTINGS = [
    ['HACIENDA_FE_URI_TOKEN',         'URL de Hacienda para obtener el token de autenticación', true],
    ['HACIENDA_FE_URI_SEND',          'URL de Hacienda para enviar el documento electrónico',   true],
    ['HACIENDA_FE_URI_CHECK',         'URL de Hacienda para consultar el estado del documento', true],
    ['HACIENDA_FE_RESOLUTION_NUMBER', 'Número de resolución de facturación electrónica',        true],
    ['HACIENDA_FE_RESOLUTION_DATE',   'Fecha de la resolución de facturación electrónica',      true]
  ].freeze

  # Modelo mínimo y propio, y no `Environment`/`Setting` de la app: los dos
  # cambian con el tiempo (este mismo cambio borra el primero) y el
  # `default_scope` de `Setting` escondería justo las filas que hay que crear.
  class MigrationEnvironment < ActiveRecord::Base
    self.table_name = 'environments'
  end

  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information
    create_settings
    migrate_existing_values

    remove_reference :companies, :environment, foreign_key: true
    drop_table :environments
  end

  # Irreversible a propósito: revertirla recrearía `environments` vacía y
  # dejaría los valores reales solo en `settings`, sin ninguna forma de saber
  # cuáles "pertenecían" a la tabla vieja.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Upsert por `code`, igual que `db/seeds.rb`: si esta migración corre dos
  # veces (o si el ajuste ya lo trajo un seed posterior), no duplica la fila.
  def create_settings
    SETTINGS.each do |code, description, is_visible|
      record = MigrationSetting.unscoped.find_or_initialize_by(code: code)
      record.group_code  = GROUP
      record.description = description
      record.is_visible  = is_visible
      record.is_active   = true
      record.save!
    end
  end

  # Defensivo: la tabla se confirmó vacía en las instalaciones revisadas, pero
  # nada impide que alguna otra la haya llenado a mano. Se toma la primera fila
  # activa — nunca hubo más de un ambiente por instalación real.
  def migrate_existing_values
    env = MigrationEnvironment.where(is_active: true).order(:id).first
    return unless env

    write_setting('HACIENDA_FE_URI_TOKEN', env.uri_token)
    write_setting('HACIENDA_FE_URI_SEND', env.uri_send)
    write_setting('HACIENDA_FE_URI_CHECK', env.uri_check)
    write_setting('HACIENDA_FE_RESOLUTION_NUMBER', env.resolution_number)
    write_setting('HACIENDA_FE_RESOLUTION_DATE', env.resolution_date&.to_s)
  end

  def write_setting(code, value)
    return if value.blank?

    MigrationSetting.find_by!(code: code).update!(value: value)
  end
end

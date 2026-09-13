# frozen_string_literal: true

# Agrega el grupo de ajustes `HACIENDA_XSD` al catálogo de `settings`: los nueve
# esquemas XSD con los que se valida un comprobante contra el esquema de
# Hacienda antes de mandarlo.
#
# Reemplazan los nueve `appSettings` del .NET (`CLVS_FE.API/Web.config`:
# `FEXSDPath`, `NCXSDPath`, … `ACCEPTXSDMailParser`), que eran rutas absolutas al
# disco de aquel servidor y que `Validations.cs` pasaba tal cual a
# `settings.Schemas.Add(null, SchemaPath)`.
#
# ── Qué guarda el `value` ───────────────────────────────────────────────────
# NO el XSD ni una ruta del disco: la ruta del blob en Azure
# (`xsd/{CODE}/{digest}/{nombre}.xsd`), que escribe `Hacienda::SchemaUpload`
# cuando el operador sube el archivo desde Configuraciones → Generales. Por eso
# los nueve nacen **en blanco** y con `is_visible: true` — una ruta de blob no es
# un secreto, y la pantalla la necesita para mostrar qué archivo está cargado.
#
# ── Por qué son NUEVE y no diez ─────────────────────────────────────────────
# Los tres mensajes de receptor (`05`, `06`, `07`) comparten esquema: el legacy
# los valida a los tres con el mismo archivo y elige la variante por el ORIGEN
# del mensaje, no por su código (`Validations.cs` L248-256, el parámetro
# `fromMailParser`). De ahí `MENSAJE_RECEPTOR` y `MENSAJE_RECEPTOR_MAIL_PARSER`
# en lugar de `_05`, `_06` y `_07`.
#
# ── Por qué una migración y no `db:seed` ────────────────────────────────────
# El mismo motivo que `20260907120000_add_azure_storage_settings.rb`: el
# catálogo se declara en `db/seeds.rb` (§36) y ese archivo hace upsert sin tocar
# los valores, pero correrlo entero contra una base viva arranca con
# `Permission.unscoped.delete_all` y se lleva las asignaciones de roles. Con esta
# migración, una base migrada termina idéntica a una sembrada de cero.
#
# Las nueve filas se escriben acá LITERALES y no derivadas de
# `Hacienda::SchemaStore::SCHEMAS`, por la misma razón por la que no se usa el
# modelo `Setting` (§28): una migración documenta lo que se aplicó el día que se
# corrió, y esa constante puede cambiar. `MigrationSetting` declara `encrypts`
# porque la columna va cifrada — sin eso el valor quedaría en claro y, con
# `support_unencrypted_data = false`, leerlo después levantaría.
class AddHaciendaXsdSettings < ActiveRecord::Migration[8.1]
  GROUP = 'HACIENDA_XSD'

  # code                                       description                                                is_visible
  SETTINGS = [
    ['HACIENDA_XSD_01', 'Esquema XSD de Hacienda para factura electrónica', true],
    ['HACIENDA_XSD_02', 'Esquema XSD de Hacienda para nota de débito electrónica', true],
    ['HACIENDA_XSD_03', 'Esquema XSD de Hacienda para nota de crédito electrónica', true],
    ['HACIENDA_XSD_04', 'Esquema XSD de Hacienda para tiquete electrónico', true],
    ['HACIENDA_XSD_08', 'Esquema XSD de Hacienda para factura electrónica de compra', true],
    ['HACIENDA_XSD_09', 'Esquema XSD de Hacienda para factura electrónica de exportación', true],
    ['HACIENDA_XSD_10', 'Esquema XSD de Hacienda para recibo electrónico de pago', true],
    ['HACIENDA_XSD_MENSAJE_RECEPTOR', 'Esquema XSD de Hacienda para mensaje de receptor', true],
    ['HACIENDA_XSD_MENSAJE_RECEPTOR_MAIL_PARSER',
     'Esquema XSD de Hacienda para mensaje de receptor obtenido del correo', true]
  ].freeze

  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information

    SETTINGS.each do |code, description, is_visible|
      # `unscoped`: un ajuste dado de baja se reactiva, no se duplica — el índice
      # único de `code` no excluye a las filas inactivas (§36).
      record = MigrationSetting.unscoped.find_or_initialize_by(code: code)
      record.group_code  = GROUP
      record.description = description
      record.is_visible  = is_visible
      record.is_active   = true
      record.save!
    end
  end

  # Borra las filas del catálogo, no los blobs: un `rollback` no tiene por qué
  # destruir los archivos que el operador subió a Azure, y volver a migrar deja
  # los ajustes en blanco apuntando a nada. Si hay que limpiar el contenedor, es
  # una tarea aparte y deliberada.
  def down
    MigrationSetting.unscoped.where(code: SETTINGS.map(&:first)).delete_all
  end
end

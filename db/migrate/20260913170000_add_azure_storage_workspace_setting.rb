# frozen_string_literal: true

# Agrega `AZURE_STORAGE_WORKSPACE` al grupo `AZURE_STORAGE`, con "fec".
#
# Es la carpeta de PRIMER nivel dentro del contenedor, y con ella la ruta de todo
# blob de este producto pasa a ser:
#
#   <contenedor>/<workspace>/<uuid de la compañía>/xmls/<clave>.xml
#   <contenedor>/<workspace>/xsd/<CODE>/<digest>/<archivo>.xsd
#
# La cuenta de Azure es compartida entre productos de Clavisco: sin el workspace,
# `xsd/` y las carpetas por compañía cuelgan de la raíz del contenedor y se
# mezclan con las de otro producto.
#
# ── Es un DEFAULT, no un valor fijo ─────────────────────────────────────────
# "fec" es el nombre de este producto, pero una instalación puede necesitar otro
# —un ambiente de QA conviviendo con producción en la misma cuenta—, y el campo
# es editable en Configuraciones → Generales. Por eso esta migración solo escribe
# el valor cuando NO hay uno guardado, y `db/seeds.rb` lo declara con
# `default_value` en vez de `fixed_value` (que se reafirma en cada corrida y
# revertiría el cambio del operador).
#
# ── Lo que NO hace ──────────────────────────────────────────────────────────
# No mueve ningún blob ni reescribe ninguna ruta ya guardada. Los XML archivados
# hasta hoy se siguen leyendo igual: su ruta sale de la URL que quedó en SAP
# (`Documents::XmlArchive.fetch`), no se recompone. Lo mismo con los XSD, cuya
# ruta completa vive en el `value` de su propio ajuste. El workspace solo cambia
# dónde se ESCRIBE de ahora en adelante.
class AddAzureStorageWorkspaceSetting < ActiveRecord::Migration[8.1]
  CODE = 'AZURE_STORAGE_WORKSPACE'
  DEFAULT_VALUE = 'fec'

  # Modelo propio y mínimo, no `Setting`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería la fila si estuviera
  # dada de baja — que es justo la que habría que reactivar.
  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information

    record = MigrationSetting.unscoped.find_or_initialize_by(code: CODE)
    record.group_code  = 'AZURE_STORAGE'
    record.description = 'Carpeta del producto dentro del contenedor'
    record.is_visible  = true
    record.is_active   = true
    # Solo si no hay ninguno: correr esta migración dos veces no puede devolver
    # el workspace a "fec" después de que alguien lo cambió.
    record.value       = DEFAULT_VALUE if record.value.blank?
    record.save!
  end

  def down
    MigrationSetting.where(code: CODE).delete_all
  end
end

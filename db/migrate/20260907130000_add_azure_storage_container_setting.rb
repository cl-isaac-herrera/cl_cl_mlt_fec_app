# frozen_string_literal: true

# Agrega `AZURE_STORAGE_CONTAINER` al grupo `AZURE_STORAGE`.
#
# El contenedor era una constante (`Documents::XmlArchive::CONTAINER`, "clvsfe",
# igual que el legacy) y pasa a vivir en `settings` para poder corregirlo desde
# la UI sin deploy si Hacienda alguna vez pidiera otro. No lo elige el
# operador: por eso, igual que `HACIENDA_FE_GRANT_TYPE` y
# `HACIENDA_XADES_SETTINGS`, esta migración también le asigna el `value` — el
# único ajuste de esta migración cuyo valor SÍ se toca acá (ver
# `20260907120000_add_azure_storage_settings.rb`, que deja `value` en blanco
# para que lo escriba el operador).
#
# Mismo motivo que esa migración para no usar el modelo `Setting`: su
# `default_scope` escondería la fila si estuviera dada de baja.
class AddAzureStorageContainerSetting < ActiveRecord::Migration[8.1]
  CODE = 'AZURE_STORAGE_CONTAINER'
  FIXED_VALUE = 'clvsfe'

  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information

    record = MigrationSetting.unscoped.find_or_initialize_by(code: CODE)
    record.group_code  = 'AZURE_STORAGE'
    record.description = 'Contenedor de Azure Storage donde se guardan los XML'
    record.is_visible  = true
    record.is_active   = true
    record.value       = FIXED_VALUE
    record.save!
  end

  def down
    MigrationSetting.where(code: CODE).delete_all
  end
end

# frozen_string_literal: true

# Agrega el grupo de ajustes `AZURE_STORAGE` al catálogo de `settings`.
#
# Son las credenciales de la cuenta de Azure Storage donde `Documents::XmlArchive`
# guarda el XML firmado que se envía a Hacienda y el XML de respuesta que
# Hacienda devuelve (`U_CL_FEC_XmlSentUrl` / `U_CL_FEC_XmlResponseUrl` en SAP).
# El contenedor va aparte, en `20260907130000_add_azure_storage_container_setting.rb`:
# también es un ajuste de este grupo, pero con un `value` sembrado ("clvsfe",
# igual que el legacy) en vez de en blanco.
#
# ── Por qué una migración y no `db:seed` ─────────────────────────────────────
# El catálogo se declara en `db/seeds.rb` (§36), y ese archivo hace upsert de
# los ajustes sin tocar sus valores, así que correrlo sería seguro **para este
# grupo**. Lo que no es seguro es correr `seeds.rb` entero contra una base
# viva: empieza con `Permission.unscoped.delete_all` y se lleva puestas todas
# las asignaciones de roles. Por eso las filas también se insertan acá, y una
# base migrada termina idéntica a una sembrada de cero.
#
# No usa el modelo `Setting` a propósito (§28): cambia con el tiempo y su
# `default_scope` escondería justo las filas que hay que tocar. Sí declara
# `encrypts :value`, porque el valor va cifrado y sin eso quedaría en claro —y
# con `support_unencrypted_data = false`, leerlo después levanta.
class AddAzureStorageSettings < ActiveRecord::Migration[8.1]
  GROUP = 'AZURE_STORAGE'

  # code                          description                                    is_visible
  SETTINGS = [
    ['AZURE_STORAGE_ACCOUNT_NAME', 'Nombre de la cuenta de Azure Storage', true],
    ['AZURE_STORAGE_ACCOUNT_KEY',  'Clave de acceso de la cuenta de Azure Storage', false]
  ].freeze

  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information

    SETTINGS.each do |code, description, is_visible|
      record = MigrationSetting.unscoped.find_or_initialize_by(code: code)
      record.group_code  = GROUP
      record.description = description
      record.is_visible  = is_visible
      record.is_active   = true
      record.save!
    end
  end

  def down
    MigrationSetting.where(code: SETTINGS.map(&:first)).delete_all
  end
end

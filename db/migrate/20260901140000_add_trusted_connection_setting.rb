# frozen_string_literal: true

# Agrega el ajuste `DOCS_DB_ODBC_TRUSTED` al catálogo de `settings`.
#
# Con él en `true`, la conexión a la base de documentos se autentica con la
# identidad de Windows del proceso —`Trusted_Connection=Yes` en la cadena ODBC—
# y `DOCS_DB_ODBC_USER` / `_PASSWORD` dejan de ser obligatorios.
#
# ── Por qué una migración y no `db:seed` ─────────────────────────────────────
# El catálogo se declara en `db/seeds.rb` (§36), y ese archivo hace upsert de los
# ajustes sin tocar sus valores, así que correrlo sería seguro **para este
# grupo**. Lo que no es seguro es correr `seeds.rb` entero contra una base viva:
# empieza con `Permission.unscoped.delete_all` y se lleva puestas todas las
# asignaciones de roles. Por eso la fila también se inserta acá, y una base
# migrada termina idéntica a una sembrada de cero.
#
# ── Se preserva la instalación que YA venía usando autenticación integrada ───
# Antes de que existiera este ajuste, la única forma de activarla era escribir
# `Trusted_Connection=…` a mano en EXTRA_PARAMS. Esas instalaciones están
# conectando así hoy: si el ajuste naciera en `false`, la próxima lectura armaría
# la cadena con `UID`/`PWD` y la conexión se caería. Entonces se hereda el estado
# —el ajuste nace en `true`— y la clave se quita de EXTRA_PARAMS, para que no
# queden dos fuentes de verdad y desactivar el ajuste desactive de verdad.
#
# No usa el modelo `Setting` a propósito (§28): cambia con el tiempo y su
# `default_scope` escondería justo las filas que hay que tocar. Sí declara
# `encrypts :value`, porque el valor va cifrado y sin eso quedaría en claro —y
# con `support_unencrypted_data = false`, leerlo después levanta.
class AddTrustedConnectionSetting < ActiveRecord::Migration[8.1]
  CODE        = 'DOCS_DB_ODBC_TRUSTED'
  GROUP       = 'DOCS_DB_ODBC'
  DESCRIPTION = 'Autenticación integrada de Windows (solo SQL Server)'
  EXTRA_CODE  = 'DOCS_DB_ODBC_EXTRA_PARAMS'

  # `Trusted_Connection=<lo que sea>`, con o sin punto y coma detrás.
  TRUSTED_IN_EXTRA = /Trusted_Connection\s*=\s*[^;]*;?/i

  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information
    return if MigrationSetting.exists?(code: CODE)

    extra    = MigrationSetting.find_by(code: EXTRA_CODE)
    inherits = extra&.value.to_s.match?(TRUSTED_IN_EXTRA)

    MigrationSetting.create!(
      code: CODE, group_code: GROUP, description: DESCRIPTION,
      is_visible: true, is_active: true, value: inherits ? 'true' : 'false'
    )

    strip_from_extra_params(extra) if inherits
  end

  def down
    MigrationSetting.where(code: CODE).delete_all
  end

  private

  # La clave sale de EXTRA_PARAMS: ya la representa el ajuste nuevo.
  def strip_from_extra_params(extra)
    cleaned = extra.value.to_s.gsub(TRUSTED_IN_EXTRA, '').squeeze(';').delete_prefix(';')

    extra.update!(value: cleaned.presence)
    say("#{EXTRA_CODE}: se quitó Trusted_Connection y #{CODE} nace en true.")
  end
end

# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las dos filas de la UDT
# `@CL_FEC_DOCSYNCATTMP` (`config/sap_schemas/doc_sync_attempts_udt.json`): la
# escritura de un intento de sincronización y la lectura del historial de un
# documento. Las consume `Sap::DocSyncAttempts`.
#
# ── Qué reemplazan ──────────────────────────────────────────────────────────
# La tabla `DocumentAttemptDetails` de la base de la cola, que insertaban los SP
# `CL_D_CL_MLT_FEC_UPT_DOCUMENT` y `…UPT_REPROCESSDOCUMENT`, y que leía
# `CL_D_CL_MLT_FEC_SLT_DOCUMENTATTEMPS`. Los tres perdieron esa lógica: la cola
# externa se queda solo con CUÁNDO reintentar (`StatusCode` + `Attempts`) y el
# detalle de cada intento pasa a SAP, junto al documento, para que el operador
# lo vea desde ahí. Mismo reparto que ya tenía el correo de recepción entre
# `Documents::MailQueue` (cola) y `Sap::MailQueue` (UDT).
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del mismo
# seed (`CLAUDE.md` §36 y `TODOS.md` → Deploy), así que el catálogo se completa
# acá para que una base migrada quede idéntica a una sembrada de cero.
#
# ⚠️ Esto NO crea la UDT en SAP: eso lo hace `rake sap:schema:sync` con el
# schema declarado (`CLAUDE.md` §32). Sin ese paso las dos consultas resuelven
# un entity set que todavía no existe.
class AddDocSyncAttemptsSlResources < ActiveRecord::Migration[8.1]
  RESOURCE = 'U_CL_FEC_DOCSYNCATTMP'

  # code                     description                                                          query_params
  ROWS = [
    ['createDocSyncAttempt',
     'Registra un intento de sincronización de un documento (UDT)',
     nil],
    ['getDocSyncAttempts',
     'Historial de intentos de sincronización de un documento (UDT)',
     '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=U_CreatedAt desc']
  ].freeze

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    ROWS.each do |code, description, query_params|
      record = MigrationSlResource.find_or_initialize_by(code: code)
      record.description  = description
      record.resource     = RESOURCE
      record.query_params = query_params
      record.page_size    = 0
      record.is_standard  = true
      record.is_active    = true
      record.save!
    end
  end

  def down
    MigrationSlResource.where(code: ROWS.map(&:first)).delete_all
  end
end

# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` la consulta que alimenta el panel
# "Correos" del listado de documentos emitidos: el HISTORIAL completo de correos
# de un documento en la UDT `@CL_FEC_MAILSDETAILS`
# (`config/sap_schemas/outgoing_mails_udt.json`). La consume `Sap::MailQueue#list`.
#
# ── Qué reemplaza ───────────────────────────────────────────────────────────
# `GET /api/Email/GetOutgoingMails?docId=N` del .NET, que ejecutaba
# `spGetOutgoingMails` contra la tabla `OutgoingMails` de la base propia de la
# app. Ese detalle ya no vive ahí: lo escribe `Sap::MailQueue` en la UDT, junto
# al documento, igual que el historial de intentos pasó a `@CL_FEC_DOCSYNCATTMP`
# (`20260910160000`).
#
# ── Por qué NO alcanza con `getMailInformation` ─────────────────────────────
# (hoy `getPendingDocumentMail`; lo renombró `20260912110000`, después de esta)
# Esa consulta es para el ENVÍO: su `$filter` excluye `U_Status` 4 (Enviado) y 5
# (Omitido) justamente para devolver a lo sumo la fila que todavía falta mandar.
# El panel necesita lo contrario —todas las filas, sobre todo las ya enviadas—,
# así que es una fila aparte del catálogo y no una variante de aquella.
#
# ── El orden es por `Code` ──────────────────────────────────────────────────
# `Code` es la llave que SAP autoincrementa en la UDT (`bott_NoObjectAutoIncrement`),
# así que ordenar por él es ordenar por el orden en que se registraron los
# correos, sin depender de `U_CreatedAt`, que es texto (`db_Alpha(25)`). `desc`
# para que el correo más reciente quede arriba, como hacía el `ORDER BY
# Om.CreateDate desc` del SP que reemplaza.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del mismo
# seed (`CLAUDE.md` §36), así que el catálogo se completa acá para que una base
# migrada quede idéntica a una sembrada de cero.
class AddDocumentMailsSlResource < ActiveRecord::Migration[8.1]
  CODE        = 'getDocumentMails'
  DESCRIPTION = 'Historial de correos de recepción electrónica de un documento (UDT)'
  RESOURCE    = 'U_CL_FEC_MAILSDETAILS'
  QUERY       = '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=Code desc'

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    record = MigrationSlResource.find_or_initialize_by(code: CODE)
    record.description  = DESCRIPTION
    record.resource     = RESOURCE
    record.query_params = QUERY
    record.page_size    = 0
    record.is_standard  = true
    record.is_active    = true
    record.save!
  end

  def down
    MigrationSlResource.where(code: CODE).delete_all
  end
end

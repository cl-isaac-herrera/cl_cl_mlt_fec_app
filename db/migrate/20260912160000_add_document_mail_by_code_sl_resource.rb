# frozen_string_literal: true

# Agrega al catálogo `getDocumentMailByCode`: la fila de la UDT
# `@CL_FEC_MAILSDETAILS` leída por su llave (`Sap::MailQueue#fetch`).
#
# ── Para qué ────────────────────────────────────────────────────────────────
# Es como `SendElectronicReceiptJob` resuelve QUÉ correo mandar. Antes buscaba
# "el correo pendiente de este documento" (`getPendingDocumentMail`), que dejó
# de ser una pregunta con una sola respuesta: desde que el panel "Correos"
# permite reenviar, un documento puede tener varias filas vivas a la vez, cada
# una con sus propios destinatarios.
#
# Ahora el enlace es explícito: la fila de la cola externa guarda el `Code` de
# su fila de la UDT (`OutgoingMailsQueue.UdtCode`) y el job lee esa, por llave.
#
# `getPendingDocumentMail` NO se da de baja: sigue haciendo falta al ENCOLAR.
# `CheckSentDocumentsJob` registra la fila de la cola en una corrida distinta de
# la que creó la fila de la UDT, así que lo único que tiene para encontrar el
# `Code` es el documento — y en ese momento hay una sola fila pendiente.
#
# ── La llave va SIN comillas ────────────────────────────────────────────────
# `(#Code#)` y no `('#Code#')`: la UDT es `bott_NoObjectAutoIncrement`, así que
# su `Code` es numérico y citarlo hace fallar la petición. Mismo criterio que
# `updateDocumentMail`, que apunta al mismo path con otro verbo.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del mismo
# seed (`CLAUDE.md` §36), así que el catálogo se completa acá para que una base
# migrada quede idéntica a una sembrada de cero.
class AddDocumentMailByCodeSlResource < ActiveRecord::Migration[8.1]
  CODE        = 'getDocumentMailByCode'
  DESCRIPTION = 'Correo de recepción electrónica de un documento, por su Code (UDT)'
  RESOURCE    = 'U_CL_FEC_MAILSDETAILS(#Code#)'

  # Modelo propio y mínimo, no `SlResource`: el `default_scope` de
  # `SoftDeletable` escondería la fila si estuviera dada de baja.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    record = MigrationSlResource.find_or_initialize_by(code: CODE)
    record.description  = DESCRIPTION
    record.resource     = RESOURCE
    record.query_params = nil
    record.page_size    = 0
    record.is_standard  = true
    record.is_active    = true
    record.save!
  end

  def down
    MigrationSlResource.where(code: CODE).delete_all
  end
end

# frozen_string_literal: true

# Renombra los tres `code` del catálogo que todavía decían "MailQueue". La UDT
# dejó de ser una cola en `20260911150000_rename_mail_udt_sl_resources.rb`
# (`@CL_FEC_MAILSQUEUE` → `@CL_FEC_MAILSDETAILS`): lo que guarda es el DETALLE
# del correo —destinatarios, remitente, estado visible en SAP—, y cuándo
# reintentar el envío lo decide la cola externa (`Documents::MailQueue`,
# `CLAUDE.md` §37). Aquella migración corrigió el `resource`; los `code`
# quedaron nombrando algo que esa tabla ya no es.
#
#   getMailInformation  → getPendingDocumentMail
#   createMailQueue     → createDocumentMail
#   updateMailQueue     → updateDocumentMail
#
# `getMailInformation` además no decía QUÉ información: su `$filter` excluye
# `U_Status` 4 (Enviado) y 5 (Omitido), así que devuelve a lo sumo el correo que
# todavía falta mandar. El nombre nuevo lo dice, y lo separa de
# `getDocumentMails` (`20260912100000`), que trae el historial completo para el
# panel "Correos" del listado de emitidos.
#
# ── Por qué se renombra EN EL LUGAR y no se borra + inserta ─────────────────
# Mismo motivo que `20260907162000_rename_mail_queue_sl_resource.rb`: la fila
# conserva su `id` y su `query_params`, que el cliente puede haber ajustado
# desde la pantalla de mantenimiento de recursos. Un delete + insert le borraría
# ese ajuste sin avisarle.
#
# ── Por qué una migración y no alcanza con `db/seeds.rb` ────────────────────
# El seed se saltea las consultas personalizadas (`is_standard = false`): en esa
# instalación la fila se quedaría con el `code` viejo y `Sap::MailQueue` —que ya
# busca el nuevo— levantaría `UnknownResource` en el primer envío. El `code` es
# infraestructura, no algo que el cliente haya ajustado, así que se corrige acá
# sin filtrar por `is_standard` — mismo criterio que la migración del `resource`.
class RenameMailQueueSlResourceCodes < ActiveRecord::Migration[8.1]
  RENAMES = {
    'getMailInformation' => 'getPendingDocumentMail',
    'createMailQueue' => 'createDocumentMail',
    'updateMailQueue' => 'updateDocumentMail'
  }.freeze

  # La descripción también hablaba de "la cola de correos". Va junto con el
  # `code` para que la pantalla de mantenimiento no siga mostrando el nombre
  # viejo del concepto.
  DESCRIPTIONS = {
    'getPendingDocumentMail' => 'Correo de recepción electrónica pendiente de envío de un documento (UDT)',
    'createDocumentMail' => 'Registra el correo de recepción electrónica de un documento (UDT)',
    'updateDocumentMail' => 'Actualiza el estado del correo de recepción electrónica de un documento (UDT)'
  }.freeze

  # Modelo propio y mínimo, no `SlResource`: el `default_scope` de
  # `SoftDeletable` escondería la fila si estuviera dada de baja, que es
  # justamente una de las que hay que renombrar.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    RENAMES.each { |from, to| rename(from, to) }
  end

  def down
    RENAMES.each { |from, to| rename(to, from) }
  end

  private

  # Idempotente: una instalación sembrada de cero ya trae el nombre de destino, y
  # renombrar ahí dejaría dos filas con el mismo `code` (el índice único lo
  # rechazaría). La descripción se escribe solo cuando hay una para ese nombre —
  # al revertir se conserva la que haya, que es lo mismo que hacía el rename del
  # `resource`.
  def rename(from, to)
    return if MigrationSlResource.exists?(code: to)

    record = MigrationSlResource.find_by(code: from)
    return if record.nil?

    record.code = to
    record.description = DESCRIPTIONS[to] if DESCRIPTIONS.key?(to)
    record.save!
  end
end

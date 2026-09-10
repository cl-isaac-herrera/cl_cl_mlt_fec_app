# frozen_string_literal: true

# Corrige el `resource` de las tres consultas de la cola de correos: el Service
# Layer expone los DATOS de una UDT con el prefijo `U_`, no con el `@` del
# nombre SQL/DI-API.
#
# ── Qué se rompía ───────────────────────────────────────────────────────────
# Con `@CL_FEC_MAILSQUEUE` el Service Layer contesta `Service Not Found`. El
# efecto era silencioso para el documento —`SyncIssuedDocumentsJob
# #queue_receipt_mail` no deja que un fallo del correo tumbe el desenlace de la
# emisión— así que los comprobantes se emitían, quedaban aceptados y nadie se
# enteraba de que en SAP no había fila en la UDT. Verificado en el log del
# 2026-09-10: DocEntry 550 y 551 emitidos y aceptados, con
# `no se pudo encolar el correo de recepción — SL error: Service Not Found`
# entre medio.
#
# `@CL_FEC_MAILSQUEUE` sigue siendo el nombre correcto para la METADATA
# (`config/sap_schemas/outgoing_mails_udt.json`, `UserTablesMD`): son dos
# nombres del mismo objeto y solo cambia el de OData.
#
# ── Por qué un UPDATE en el lugar ───────────────────────────────────────────
# Mismo motivo que `20260907162000_rename_mail_queue_sl_resource.rb`: la fila
# puede tener una personalización de `query_params` hecha desde la pantalla de
# mantenimiento, y `seeds.rb` no reescribe una consulta marcada
# `is_standard = false`. Se corrige solo el `resource`, que es un dato de
# infraestructura y no algo que el cliente pueda haber ajustado.
#
# Modelo propio y mínimo, no `SlResource`: el `default_scope` de
# `SoftDeletable` escondería la fila si estuviera dada de baja.
class FixMailQueueSlResourceEntityName < ActiveRecord::Migration[8.1]
  # `code` => [resource viejo, resource nuevo]
  RESOURCES = {
    'getMailInformation' => ['@CL_FEC_MAILSQUEUE',         'U_CL_FEC_MAILSQUEUE'],
    'createMailQueue'    => ['@CL_FEC_MAILSQUEUE',         'U_CL_FEC_MAILSQUEUE'],
    # Sin comillas alrededor de la llave: la UDT es `bott_NoObjectAutoIncrement`
    # y su `Code` es numérico — citarlo hace fallar la petición.
    'updateMailQueue'    => ['@CL_FEC_MAILSQUEUE(#Code#)', 'U_CL_FEC_MAILSQUEUE(#Code#)']
  }.freeze

  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    RESOURCES.each { |code, (old, new)| rename(code, old, new) }
  end

  def down
    RESOURCES.each { |code, (old, new)| rename(code, new, old) }
  end

  private

  # Idempotente y acotada al valor esperado: una instalación sembrada de cero ya
  # trae el nombre nuevo, y una que haya sido corregida a mano no se pisa.
  def rename(code, from, to)
    MigrationSlResource.where(code: code, resource: from).update_all(resource: to)
  end
end

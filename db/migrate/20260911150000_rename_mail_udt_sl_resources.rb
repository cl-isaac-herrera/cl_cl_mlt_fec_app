# frozen_string_literal: true

# Apunta las tres consultas de la UDT de correos al nombre nuevo: la tabla pasó
# de `@CL_FEC_MAILSQUEUE` a `@CL_FEC_MAILSDETAILS`
# (`config/sap_schemas/outgoing_mails_udt.json`), porque lo que guarda es el
# DETALLE del correo —destinatarios, remitente, estado visible en SAP— y no la
# cola: cuándo reintentar el envío lo decide la cola externa
# (`Documents::MailQueue`, `CLAUDE.md` §37).
#
# El `resource` del catálogo lleva el nombre de OData (prefijo `U_`), no el
# SQL/DI-API (prefijo `@`) — es la corrección que hizo
# `20260910123000_fix_mail_queue_sl_resource_entity_name.rb`, y acá solo cambia
# la parte del nombre que el rename tocó.
#
# ── Por qué una migración y no alcanza con `db/seeds.rb` ────────────────────
# El seed **se saltea** las consultas que el cliente personalizó desde la
# pantalla de mantenimiento (`is_standard = false`): en esa instalación la fila
# se quedaría apuntando a la UDT vieja y el Service Layer contestaría
# `Service Not Found`, exactamente el fallo silencioso del 2026-09-10 que
# documenta `20260910123000`. Por eso se corrige acá, y sin filtrar por
# `is_standard`: el `resource` es infraestructura, no algo que el cliente haya
# ajustado — mismo criterio que la migración anterior.
#
# Modelo propio y mínimo, no `SlResource`: el `default_scope` de
# `SoftDeletable` escondería la fila si estuviera dada de baja.
class RenameMailUdtSlResources < ActiveRecord::Migration[8.1]
  OLD_ENTITY = 'U_CL_FEC_MAILSQUEUE'
  NEW_ENTITY = 'U_CL_FEC_MAILSDETAILS'

  # `code` => sufijo del `resource`. Sin comillas alrededor de la llave del
  # update (`(#Code#)` y no `('#Code#')`): la UDT es `bott_NoObjectAutoIncrement`
  # y su `Code` es numérico — citarlo hace fallar la petición.
  RESOURCES = {
    'getMailInformation' => '',
    'createMailQueue' => '',
    'updateMailQueue' => '(#Code#)'
  }.freeze

  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    RESOURCES.each { |code, suffix| rename(code, "#{OLD_ENTITY}#{suffix}", "#{NEW_ENTITY}#{suffix}") }
  end

  def down
    RESOURCES.each { |code, suffix| rename(code, "#{NEW_ENTITY}#{suffix}", "#{OLD_ENTITY}#{suffix}") }
  end

  private

  # Idempotente y acotada al valor esperado: una instalación sembrada de cero ya
  # trae el nombre nuevo, y una que haya sido corregida a mano no se pisa.
  def rename(code, from, to)
    MigrationSlResource.where(code: code, resource: from).update_all(resource: to)
  end
end

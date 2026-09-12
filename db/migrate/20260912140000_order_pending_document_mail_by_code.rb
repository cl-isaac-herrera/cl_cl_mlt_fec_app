# frozen_string_literal: true

# Le agrega `$orderby=Code desc` a `getPendingDocumentMail`, la consulta con la
# que `Sap::MailQueue#find` resuelve CUÁL correo está por enviarse
# (`SendElectronicReceiptJob`).
#
# ── Por qué hace falta ahora y no antes ─────────────────────────────────────
# Hasta el botón "Reenviar" del panel "Correos", un documento tenía a lo sumo
# UNA fila sin terminar en la UDT: la que creaba `SyncIssuedDocumentsJob`. Sin
# competencia, el orden daba igual.
#
# Un reenvío inserta una fila nueva en estado Pendiente. Si el envío anterior
# quedó en Error (3) —que es justamente el caso en que alguien reenvía—, el
# `$filter` devuelve LAS DOS, porque solo excluye los estados terminales
# (4 Enviado y 5 Omitido). Sin `$orderby`, `#find` se quedaba con la que SAP
# pusiera primero, que es la vieja: el correo salía a los destinatarios
# anteriores, se marcaba la fila anterior, y el reenvío quedaba Pendiente para
# siempre sin que nadie recibiera un error.
#
# `Code desc` deja arriba la más reciente — el mismo criterio y la misma columna
# que `getDocumentMails` (`20260912100000`): `Code` es la llave que SAP
# autoincrementa en la UDT (`bott_NoObjectAutoIncrement`), así que ordena por
# orden de registro sin depender de `U_CreatedAt`, que es texto (`db_Alpha(25)`).
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# El seed se saltea las consultas que el cliente personalizó desde la pantalla
# de mantenimiento (`is_standard = false`). En esa instalación la consulta se
# quedaría sin `$orderby` y el fallo de arriba seguiría vivo, en silencio.
#
# A diferencia de los renames de `resource`/`code`, acá se toca `query_params`,
# que SÍ es lo que el cliente puede haber ajustado. Por eso el cambio es
# quirúrgico: solo se agrega la opción si la fila todavía no tiene ningún
# `$orderby` — un cliente que ya eligió otro orden a propósito no se pisa.
class OrderPendingDocumentMailByCode < ActiveRecord::Migration[8.1]
  CODE     = 'getPendingDocumentMail'
  # Nombre anterior: una instalación que no haya corrido `20260912110000` todavía
  # no existe (esta migración va después), pero el catálogo se puede haber
  # quedado con el `code` viejo si aquella no encontró la fila. Se buscan los dos.
  OLD_CODE = 'getMailInformation'
  ORDER_BY = '$orderby=Code desc'

  # Modelo propio y mínimo, no `SlResource`: el `default_scope` de
  # `SoftDeletable` escondería la fila si estuviera dada de baja.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    record = find_record
    return if record.nil?

    params = record.query_params.to_s
    return if params.include?('$orderby')

    record.update!(query_params: params.empty? ? ORDER_BY : "#{params}&#{ORDER_BY}")
  end

  # Solo se quita el `$orderby` que agregó `#up`, y solo si es el que agregó:
  # uno que el cliente haya escrito después no es de esta migración.
  def down
    record = find_record
    return if record.nil?

    params = record.query_params.to_s
    return unless params.end_with?(ORDER_BY)

    record.update!(query_params: params.delete_suffix(ORDER_BY).delete_suffix('&').presence)
  end

  private

  def find_record
    MigrationSlResource.find_by(code: CODE) || MigrationSlResource.find_by(code: OLD_CODE)
  end
end

# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las siete filas que consultan en SAP los
# datos del comprobante que necesita el cuerpo del correo de recepción
# electrónica: una por cada tipo de documento que `DocType` conoce y que NO es
# mensaje de receptor — mismo universo que `20260905160000_add_get_documents
# _sl_resources.rb`.
#
# ── Por qué una migración y no solo `db/seeds.rb` ────────────────────────────
# Mismo motivo que `20260905160000`: correr `db:seed` contra una base viva es
# destructivo en otras tablas del mismo seed (`CLAUDE.md` §36), así que el
# catálogo se completa acá para que una base migrada quede idéntica a una
# sembrada de cero.
#
# ── Por qué `$filter=DocEntry eq @DocEntry` y no `(#DocumentEntry#)` ─────────
# `Sap::MailDocumentInfo` le suma a este `$filter` `U_CL_FEC_Status eq 6`
# cuando `company.send_rejected_documents?` es `false`, combinando con
# `Sap::ResourceQuery#merge` (mismo patrón que
# `Sap::IssuedDocumentsSearch#extra_filter`) — una entidad puntual
# (`Invoices(#DocumentEntry#)`) no admite esa composición.
class AddMailDocumentInfoSlResources < ActiveRecord::Migration[8.1]
  SELECT_FIELDS = '$select=U_CL_FEC_NumConsecutivo,CardName,U_CL_FEC_Clave,U_CL_FEC_FechaEmision,' \
                  'DocTotal,DocTotalFc,DocCurrency,U_CL_FEC_Status,U_CL_FEC_XmlSentUrl,' \
                  'U_CL_FEC_XmlResponseUrl'

  # code                     description                                                       resource
  ROWS = [
    ['getMailDocumentInfo01', # FE — Factura electrónica
     'Datos del comprobante para el correo de recepción (factura electrónica)',
     'Invoices'],
    ['getMailDocumentInfo02', # ND — Nota de débito electrónica
     'Datos del comprobante para el correo de recepción (nota de débito electrónica)',
     'Invoices'],
    ['getMailDocumentInfo03', # NC — Nota de crédito electrónica
     'Datos del comprobante para el correo de recepción (nota de crédito electrónica)',
     'CreditNotes'],
    ['getMailDocumentInfo04', # TE — Tiquete electrónico
     'Datos del comprobante para el correo de recepción (tiquete electrónico)',
     'Invoices'],
    ['getMailDocumentInfo09', # FEE — Factura electrónica de exportación
     'Datos del comprobante para el correo de recepción (factura electrónica de exportación)',
     'Invoices'],
    ['getMailDocumentInfo08', # FEC — Factura electrónica de compra
     'Datos del comprobante para el correo de recepción (factura electrónica de compra)',
     'PurchaseInvoices'],
    ['getMailDocumentInfo10', # REP — Recibo electrónico de pago
     'Datos del comprobante para el correo de recepción (recibo electrónico de pago)',
     'IncomingPayments']
  ].freeze

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    ROWS.each do |code, description, resource|
      record = MigrationSlResource.find_or_initialize_by(code: code)
      record.description  = description
      record.resource     = resource
      record.query_params = "$filter=DocEntry eq @DocEntry&#{SELECT_FIELDS}"
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

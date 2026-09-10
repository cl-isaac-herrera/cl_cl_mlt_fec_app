# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las siete filas que traen el estado y el
# detalle de error ACTUALES de un documento — lo que pide el panel "Información
# del documento" cada vez que se abre (`Api::DocumentsController#show`).
#
# Una por tipo de documento que `DocType` conoce y que NO es mensaje de
# receptor, mismo universo y mismo mapeo tipo→entidad que
# `20260907161000_add_mail_document_info_sl_resources.rb`.
#
# ── Por qué la ENTIDAD y no la vista de cabecera ────────────────────────────
# `#show` leía `qsGetDocumentHeaderInfo`, la misma vista que usa
# `Sap::DocumentDetails`. Esa vista es una SQL Query view y devuelve sus
# propios alias (`Status`, `ErrDetails`) en vez de los nombres de los UDFs, así
# que pedirle `U_CL_FEC_ErrorDetails` devolvía `nil` y el panel no mostraba
# nunca la sección de detalles. Contra la entidad los nombres son los del campo
# real y el `$select` es confiable (la advertencia sobre `$select` de
# `CheckSentDocumentsJob#header_for` aplica a las vistas, no a las entidades
# OData nativas).
#
# ── Por qué llave y no `$filter` ────────────────────────────────────────────
# Es un documento identificado por `DocEntry`, y acá no hay nada que componer
# —a diferencia de `getMailDocumentInfo*`, que le suma un filtro de estado
# según la compañía y por eso necesita `$filter`.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del
# mismo seed (`CLAUDE.md` §36 y `TODOS.md` → Deploy), así que el catálogo se
# completa acá para que una base migrada quede idéntica a una sembrada de cero.
class AddDocumentErrorDetailsSlResources < ActiveRecord::Migration[8.1]
  QUERY_PARAMS = '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails'

  # code                          description                                                    resource
  ROWS = [
    ['getDocumentErrorDetails01', # FE — Factura electrónica
     'Estado y detalle de error actuales de una factura electrónica',
     'Invoices(#DocEntry#)'],
    ['getDocumentErrorDetails02', # ND — Nota de débito electrónica
     'Estado y detalle de error actuales de una nota de débito electrónica',
     'Invoices(#DocEntry#)'],
    ['getDocumentErrorDetails03', # NC — Nota de crédito electrónica
     'Estado y detalle de error actuales de una nota de crédito electrónica',
     'CreditNotes(#DocEntry#)'],
    ['getDocumentErrorDetails04', # TE — Tiquete electrónico
     'Estado y detalle de error actuales de un tiquete electrónico',
     'Invoices(#DocEntry#)'],
    ['getDocumentErrorDetails08', # FEC — Factura electrónica de compra
     'Estado y detalle de error actuales de una factura electrónica de compra',
     'PurchaseInvoices(#DocEntry#)'],
    ['getDocumentErrorDetails09', # FEE — Factura electrónica de exportación
     'Estado y detalle de error actuales de una factura electrónica de exportación',
     'Invoices(#DocEntry#)'],
    ['getDocumentErrorDetails10', # REP — Recibo electrónico de pago
     'Estado y detalle de error actuales de un recibo electrónico de pago',
     'IncomingPayments(#DocEntry#)']
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
      record.query_params = QUERY_PARAMS
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

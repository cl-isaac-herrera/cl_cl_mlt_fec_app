# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las siete filas que consultan en SAP el
# listado paginado de documentos, para la futura pantalla de "Documentos
# emitidos": una por cada tipo de documento que `DocType` conoce y que NO es
# mensaje de receptor (`DocType::RECEIVER_MESSAGES` queda fuera — esos no son
# comprobantes con `DocEntry` propio en SAP).
#
# ── Por qué una migración y no solo `db/seeds.rb` ────────────────────────────
# Mismo motivo que `20260905140000_add_update_document_sl_resources.rb`: correr
# `db:seed` contra una base viva es destructivo en otras tablas del mismo seed
# (`CLAUDE.md` §36), así que el catálogo de `sl_resources` se completa acá para
# que una base migrada quede idéntica a una sembrada de cero.
#
# ── No son vistas, no llevan prefijo ─────────────────────────────────────────
# `resource` apunta a una entidad ESTÁNDAR de SAP (`Invoices`, `CreditNotes`,
# `IncomingPayments`, `PurchaseInvoices`) completa, sin `(#DocumentEntry#)`: es
# un listado, no un documento puntual. El mismo `code` sirve en SQL Server y en
# HANA, sin el prefijo `view.svc/`/`sml.svc/` que `SlResourceSeed.qualify` les
# agrega a las vistas — mismo mapeo tipo→objeto que
# `SL_RESOURCES_STATUS_UPDATES` en `db/seeds.rb`.
#
# El `code` lleva el CÓDIGO NUMÉRICO de Hacienda (`DocType::FE` = '01'), no la
# mnemotecnia — mismo criterio que `updateDocument01`..`10`.
#
# ── `query_params` y `page_size` ─────────────────────────────────────────────
# Solo lleva el `$select`: el `$top`/`$skip` de la paginación real los agrega
# el llamador con `Sap::ResourceQuery#merge` en cada página, no se hornean acá.
#
# ⚠️ `page_size: 0` a propósito, y NO un valor alto: el Service Layer nunca
# devuelve más de 20 filas por respuesta si no se manda el header
# `Prefer: odata.maxpagesize`, y `Clavisco::ServiceLayer::Client` todavía no lo
# soporta —tampoco sigue `odata.nextLink`— (`TODOS.md` → SAP, sección "deuda
# del acceso a Service Layer"). Quien construya el listado tiene que paginar de
# a 20 filas o menos por request hasta que el submódulo agregue el header.
class AddGetDocumentsSlResources < ActiveRecord::Migration[8.1]
  SELECT_FIELDS = '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,' \
                  'U_CL_FEC_NumConsecutivo,U_CL_FEC_Status,U_CL_FEC_FechaEmision'

  # code              description                                                                 resource
  ROWS = [
    ['getDocuments01', # FE — Factura electrónica
     'Obtiene el listado paginado de facturas electrónicas desde SAP',
     'Invoices'],
    ['getDocuments02', # ND — Nota de débito electrónica
     'Obtiene el listado paginado de notas de débito electrónicas desde SAP',
     'Invoices'],
    ['getDocuments03', # NC — Nota de crédito electrónica
     'Obtiene el listado paginado de notas de crédito electrónicas desde SAP',
     'CreditNotes'],
    ['getDocuments04', # TE — Tiquete electrónico
     'Obtiene el listado paginado de tiquetes electrónicos desde SAP',
     'Invoices'],
    ['getDocuments09', # FEE — Factura electrónica de exportación
     'Obtiene el listado paginado de facturas electrónicas de exportación desde SAP',
     'Invoices'],
    ['getDocuments08', # FEC — Factura electrónica de compra
     'Obtiene el listado paginado de facturas electrónicas de compra desde SAP',
     'PurchaseInvoices'],
    ['getDocuments10', # REP — Recibo electrónico de pago
     'Obtiene el listado paginado de recibos electrónicos de pago desde SAP',
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
      # `find_or_initialize_by`: si la fila ya existe —activa o dada de baja—
      # se reactiva y actualiza, nunca se duplica. Mismo criterio que
      # `db/seeds.rb`.
      record = MigrationSlResource.find_or_initialize_by(code: code)
      record.description  = description
      record.resource     = resource
      record.query_params = SELECT_FIELDS
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

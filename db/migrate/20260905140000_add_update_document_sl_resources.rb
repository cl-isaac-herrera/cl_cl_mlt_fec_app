# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las siete filas que actualizan en SAP el
# resultado del envío a Hacienda: una por cada tipo de documento que
# `DocType` conoce y que NO es mensaje de receptor (`DocType::RECEIVER_MESSAGES`
# queda fuera — esos no son comprobantes que este flujo sincronice).
#
# ── Por qué una migración y no solo `db/seeds.rb` ────────────────────────────
# El seed declara el catálogo para una instalación nueva, pero correr
# `db:seed` contra una base viva es destructivo: vacía `permissions` y
# `role_permissions` antes de insertar (`CLAUDE.md` §36). Esta migración deja a
# una base migrada idéntica a una sembrada de cero, sin tocar nada más.
#
# ── No son vistas, no llevan prefijo ─────────────────────────────────────────
# `resource` apunta a una entidad ESTÁNDAR de SAP (`Invoices`, `CreditNotes`,
# `IncomingPayments`, `PurchaseInvoices`), no a una vista `_B1SLQuery` — el
# mismo `code` sirve en SQL Server y en HANA, sin el prefijo `view.svc/`/
# `sml.svc/` que `SlResourceSeed.qualify` les agrega a las vistas.
#
# `#DocumentEntry#` es el marcador de PATH que resuelve `Sap::ResourceQuery`
# (no un `$filter` de query): `path_for('updateDocument01', DocumentEntry: 25)`
# da `Invoices(25)`, listo para un `client.patch(path, body: {…})`.
#
# El `code` lleva el CÓDIGO NUMÉRICO de Hacienda (`DocType::FE` = '01'), no la
# mnemotecnia: es el mismo valor que trae `Documents::PendingQueue::Entry#doc_type`,
# así que resolver la fila por ese código no exige traducir de un lado a otro.
class AddUpdateDocumentSlResources < ActiveRecord::Migration[8.1]
  # code               description                                                                resource
  ROWS = [
    ['updateDocument01', # FE — Factura electrónica
     'Actualiza en SAP el resultado del envío a Hacienda de una factura electrónica',
     'Invoices(#DocumentEntry#)'],
    ['updateDocument02', # ND — Nota de débito electrónica
     'Actualiza en SAP el resultado del envío a Hacienda de una nota de débito',
     'Invoices(#DocumentEntry#)'],
    ['updateDocument03', # NC — Nota de crédito electrónica
     'Actualiza en SAP el resultado del envío a Hacienda de una nota de crédito',
     'CreditNotes(#DocumentEntry#)'],
    ['updateDocument04', # TE — Tiquete electrónico
     'Actualiza en SAP el resultado del envío a Hacienda de un tiquete electrónico',
     'Invoices(#DocumentEntry#)'],
    ['updateDocument09', # FEE — Factura electrónica de exportación
     'Actualiza en SAP el resultado del envío a Hacienda de una factura electrónica de exportación',
     'Invoices(#DocumentEntry#)'],
    ['updateDocument08', # FEC — Factura electrónica de compra
     'Actualiza en SAP el resultado del envío a Hacienda de una factura electrónica de compra',
     'PurchaseInvoices(#DocumentEntry#)'],
    ['updateDocument10', # REP — Recibo electrónico de pago
     'Actualiza en SAP el resultado del envío a Hacienda de un recibo electrónico de pago',
     'IncomingPayments(#DocumentEntry#)']
  ].freeze

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    ROWS.each do |code, description, resource|
      # `unscoped` (el modelo mínimo no tiene default_scope, pero se deja
      # explícito el mismo criterio que `db/seeds.rb`): si la fila ya existe
      # —activa o dada de baja— se reactiva y actualiza, nunca se duplica.
      record = MigrationSlResource.find_or_initialize_by(code: code)
      record.description  = description
      record.resource     = resource
      record.query_params = nil
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

# frozen_string_literal: true

# Reemplaza las siete filas de LECTURA `getMailDocumentInfo01`..`10` por UNA
# sola fila (`getMailDocumentInfo`) que apunta a la vista unificada de SAP
# `CL_D_CL_MLT_FEC_SLT_DOCMAILINFO_B1SLQuery`, en vez de la entidad estándar
# por tipo (`Invoices`/`CreditNotes`/`PurchaseInvoices`/`IncomingPayments`) que
# sembró `20260907161000_add_mail_document_info_sl_resources.rb`.
#
# ── Por qué UNA fila y no siete, a diferencia de `DOCDISPLAYINFO` ───────────
# La migración análoga para el listado de documentos emitidos
# (`20260914100000_point_get_documents_sl_resources_to_view`) sí dejó una fila
# por tipo, porque ahí el `$filter=DocType eq '<tipo>'` se hornea LITERAL en el
# catálogo (el listado lo elige el usuario desde la pantalla). Acá
# `Sap::MailDocumentInfo` ya recibe el tipo como parámetro (`doc_type`), así
# que el mismo binding dinámico que resuelve `@DocEntry` resuelve `@DocType` —
# no hay ninguna razón para hornear un literal por fila cuando el llamador ya
# tiene el valor a mano.
#
# ── Qué cambia además del `resource`/`$filter` ──────────────────────────────
# El `$select` desaparece: la vista está diseñada para este consumidor y solo
# expone las columnas que hacen falta (mismo criterio que `DOCDISPLAYINFO`).
# Además renombra los mismos UDFs (`U_CL_FEC_Status` → `Status`,
# `U_CL_FEC_XmlSentUrl` → `XmlSentUrl`, `U_CL_FEC_XmlResponseUrl` →
# `XmlResponseUrl`, `U_CL_FEC_Clave` → `Clave`, `U_CL_FEC_NumConsecutivo` →
# `NumeroConsecutivo`, `U_CL_FEC_FechaEmision` → `FechaEmision`) y ya resuelve
# el monto en la moneda correcta (`DocTotal` viene en la moneda que dice
# `DocCurrency`; antes había que elegir entre `DocTotal` y `DocTotalFc` según
# la moneda del documento).
#
# ── Las siete filas viejas se dan de BAJA, no se borran ─────────────────────
# `CLAUDE.md` §2.2: nunca `DELETE` de una fila que pudo haber estado en uso.
# `is_active: false` alcanza — `Sap::ResourceQuery#record` ya filtra por el
# `default_scope` de `SoftDeletable`, así que una fila dada de baja no se
# resuelve más.
#
# ── El prefijo de la vista se resuelve acá, no en `db/seeds.rb` ────────────
# Mismo criterio que la migración de `DOCDISPLAYINFO`: en HANA el nombre de la
# vista va en MAYÚSCULAS con el prefijo `sml.svc/`; en SQL Server va tal cual
# con el prefijo `view.svc/`.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del
# mismo seed (`CLAUDE.md` §36), así que el catálogo se actualiza acá para que
# una base migrada quede idéntica a una sembrada de cero.
class PointGetMailDocumentInfoSlResourcesToView < ActiveRecord::Migration[8.1]
  VIEW_NAME = 'CL_D_CL_MLT_FEC_SLT_DOCMAILINFO_B1SLQuery'
  PREFIXES  = { 'HANA' => 'sml.svc/', 'SQL' => 'view.svc/' }.freeze

  NEW_CODE = 'getMailDocumentInfo'
  NEW_DESCRIPTION = 'Datos del comprobante para el correo de recepción electrónica'
  NEW_FILTER = '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)'

  # code                    resource original (para `down`)
  OLD_ROWS = [
    ['getMailDocumentInfo01', 'Invoices'],
    ['getMailDocumentInfo02', 'Invoices'],
    ['getMailDocumentInfo03', 'CreditNotes'],
    ['getMailDocumentInfo04', 'Invoices'],
    ['getMailDocumentInfo08', 'PurchaseInvoices'],
    ['getMailDocumentInfo09', 'Invoices'],
    ['getMailDocumentInfo10', 'IncomingPayments']
  ].freeze

  # `query_params` que sembró originalmente cada fila
  # (`20260907161000_add_mail_document_info_sl_resources.rb`), para `down`.
  OLD_SELECT_FIELDS = '$select=U_CL_FEC_NumConsecutivo,CardName,U_CL_FEC_Clave,U_CL_FEC_FechaEmision,' \
                      'DocTotal,DocTotalFc,DocCurrency,U_CL_FEC_Status,U_CL_FEC_XmlSentUrl,' \
                      'U_CL_FEC_XmlResponseUrl'
  OLD_QUERY_PARAMS = "$filter=DocEntry eq @DocEntry&#{OLD_SELECT_FIELDS}"

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar/desactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    record = MigrationSlResource.find_or_initialize_by(code: NEW_CODE)
    record.description  = NEW_DESCRIPTION
    record.resource     = qualified_view
    record.query_params = NEW_FILTER
    record.page_size    = 0
    record.is_standard  = true
    record.is_active    = true
    record.save!

    MigrationSlResource.where(code: OLD_ROWS.map(&:first)).update_all(is_active: false)
  end

  def down
    MigrationSlResource.find_by(code: NEW_CODE)&.destroy

    OLD_ROWS.each do |code, resource|
      record = MigrationSlResource.find_by(code: code)
      next if record.nil?

      record.update!(resource: resource, query_params: OLD_QUERY_PARAMS, is_active: true)
    end
  end

  private

  def qualified_view
    server_type = ENV['SERVER_TYPE'].to_s.strip.upcase
    prefix = PREFIXES.fetch(server_type) do
      raise "SERVER_TYPE #{ENV['SERVER_TYPE'].inspect} no es válido. Valores: #{PREFIXES.keys.join(' | ')}. " \
            'Definila antes de correr esta migración.'
    end
    name = server_type == 'HANA' ? VIEW_NAME.upcase : VIEW_NAME
    "#{prefix}#{name}"
  end
end

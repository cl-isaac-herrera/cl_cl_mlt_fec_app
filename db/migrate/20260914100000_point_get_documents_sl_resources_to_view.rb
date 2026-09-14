# frozen_string_literal: true

# Apunta las siete filas de LECTURA `getDocuments01`..`10` a la vista unificada
# de SAP `CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery`, en vez de la entidad
# estándar por tipo (`Invoices`/`CreditNotes`/`PurchaseInvoices`) que sembró
# `20260905160000_add_get_documents_sl_resources.rb` y amplió
# `20260913160000_add_document_xml_url_sl_resources.rb`.
#
# ⚠️ Alcance: SOLO estas siete, que son la LECTURA para el listado. Las
# ESCRITURAS (`updateDocument01`..`10`, `SL_RESOURCES_STATUS_UPDATES` en
# `db/seeds.rb`) siguen pegando a la entidad directa de SAP — no se tocan acá.
#
# ── Qué cambia y por qué ─────────────────────────────────────────────────────
# La vista nueva expone `DocType` — calculado por
# `dbo.CL_D_CL_MLT_FEC_SLT_FEDOCUMENTTYPE` a partir de `SAPObjectType` +
# `Series`/`DocEntry` (`db/external/sql_server/fe_doc_type_function.sql`, la
# misma función que ahora arma la cola en `sap_post_transact_section.sql`) para
# los cuatro objetos de SAP que sincronizan documentos (OINV/ORIN/OPCH/ORCT).
# Con esa columna ya no hace falta que cada tipo pegue a una entidad distinta
# para poder distinguirse: las siete filas apuntan a la MISMA vista y lo que
# cambia entre ellas es el `$filter=DocType eq '<tipo>'`.
#
# ── El `$filter` de Series por instalación queda OBSOLETO ──────────────────
# `Sap::IssuedDocumentsSearch` (comentario de cabecera) explicaba que la
# `Series` que distingue FE/ND/TE/FEE dentro de `Invoices` se agregaba a mano
# al `query_params` de cada instalación, porque esa entidad no tiene columna
# `DocType`. La vista sí la tiene, así que esta migración SIEMPRE sobreescribe
# `resource`/`query_params` —igual que hizo la migración original, sin mirar
# `is_standard`—: el ajuste manual de Series que trajera una instalación ya no
# tiene sentido contra la vista nueva.
#
# ── El prefijo de la vista se resuelve acá, no en `db/seeds.rb` ────────────
# Mismo criterio que `SlResourceSeed.qualify` (`db/seeds.rb`, sección 5): en
# HANA el nombre de la vista va en MAYÚSCULAS con el prefijo `sml.svc/`; en SQL
# Server va tal cual con el prefijo `view.svc/`. Se duplica acá en vez de
# invocar ese módulo porque una migración no depende de un archivo que cambia
# con el tiempo — mismo motivo por el que usa su propio modelo mínimo.
#
# ── Sin `$select`: la vista ya devuelve justo lo que el listado necesita ────
# A diferencia de la entidad estándar (que trae todas las columnas de SAP si no
# se acota), la vista `DOCDISPLAYINFO` se diseñó para este listado: solo expone
# las columnas que hacen falta, así que no hay nada que acotar.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del
# mismo seed (`CLAUDE.md` §36), así que el catálogo se actualiza acá para que
# una base migrada quede idéntica a una sembrada de cero.
class PointGetDocumentsSlResourcesToView < ActiveRecord::Migration[8.1]
  VIEW_NAME = 'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery'
  PREFIXES  = { 'HANA' => 'sml.svc/', 'SQL' => 'view.svc/' }.freeze

  ORDER = '$orderby=DocEntry desc'

  # code              doc_type   resource anterior (para `down`)         query_params anterior (para `down`)
  ROWS = [
    ['getDocuments01', '01', 'Invoices', # FE  — Factura electrónica
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc'],
    ['getDocuments02', '02', 'Invoices', # ND  — Nota de débito electrónica
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc'],
    ['getDocuments03', '03', 'CreditNotes', # NC  — Nota de crédito electrónica
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc'],
    ['getDocuments04', '04', 'Invoices', # TE  — Tiquete electrónico
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc'],
    ['getDocuments08', '08', 'PurchaseInvoices', # FEC — Factura electrónica de compra
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc'],
    ['getDocuments09', '09', 'Invoices', # FEE — Factura electrónica de exportación
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc'],
    ['getDocuments10', '10', 'IncomingPayments', # REP — Recibo electrónico de pago
     '$select=DocEntry,DocDate,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
     'U_CL_FEC_Status,U_CL_FEC_FechaEmision,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl&$orderby=DocEntry desc']
  ].freeze

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    resource = qualified_view
    ROWS.each do |code, doc_type, _old_resource, _old_query_params|
      record = MigrationSlResource.find_or_initialize_by(code: code)
      record.resource     = resource
      record.query_params = "$filter=DocType eq '#{doc_type}'&#{ORDER}"
      record.page_size    = 0
      record.is_standard  = true
      record.is_active    = true
      record.save!
    end
  end

  def down
    ROWS.each do |code, _doc_type, old_resource, old_query_params|
      record = MigrationSlResource.find_by(code: code)
      next if record.nil?

      record.update!(resource: old_resource, query_params: old_query_params)
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

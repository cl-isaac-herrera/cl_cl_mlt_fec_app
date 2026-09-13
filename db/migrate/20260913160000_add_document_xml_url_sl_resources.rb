# frozen_string_literal: true

# Lo que el listado de documentos emitidos necesita para poder ofrecer
# "Descargar XML comprobante" y "Descargar XML respuesta" contra SAP, en vez de
# contra el .NET (`GET /api/Documents/GetXMLDoc` y `DownloadDocumentXML`).
#
# El XML no vive en SAP: vive en Azure (`Documents::XmlArchive`), y SAP guarda
# su URL en dos UDFs del comprobante — `U_CL_FEC_XmlSentUrl` (el firmado que se
# envió) y `U_CL_FEC_XmlResponseUrl` (el que devolvió Hacienda), que escribe
# `Sap::DocumentStatus`. Así que hacen falta dos cosas del catálogo:
#
#   1. Que el LISTADO traiga las dos URLs, para saber si hay algo que descargar
#      antes de ofrecer la opción (`documents_issued_controller.js` la
#      inhabilita con su motivo cuando el campo viene vacío, §26).
#   2. Una consulta por documento que devuelva las dos URLs
#      (`getDocumentXmlUrls<tipo>`), que es de donde
#      `Api::Documents::XmlFilesController` las resuelve al momento de bajar el
#      archivo.
#
# ── Por qué el servidor vuelve a preguntarle a SAP en vez de recibir la URL ──
# Porque una URL que llega del cliente es una URL que el cliente eligió: bastaría
# cambiarle la carpeta (`<contenedor>/<cédula>/…`) para bajar el XML de otro
# contribuyente con las credenciales de Azure de la instalación. La URL de la
# fila del listado sirve para decidir si el botón se ofrece; la que se baja la
# resuelve el servidor por `DocEntry` contra la compañía activa.
#
# ── Por qué una familia nueva y no ampliar `getDocumentErrorDetails<tipo>` ───
# Mismo criterio que esa familia frente a `qsGetDocumentHeaderInfo`: el `code`
# dice qué devuelve la consulta. Sumarle dos campos que no son ni el estado ni
# el detalle de error dejaría un nombre que miente, y el panel de información
# pagaría el `$select` más ancho sin usarlo.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del mismo
# seed (`CLAUDE.md` §36), así que el catálogo se completa acá para que una base
# migrada quede idéntica a una sembrada de cero.
class AddDocumentXmlUrlSlResources < ActiveRecord::Migration[8.1]
  XML_URL_FIELDS = %w[U_CL_FEC_XmlSentUrl U_CL_FEC_XmlResponseUrl].freeze

  QUERY_PARAMS = "$select=#{XML_URL_FIELDS.join(',')}".freeze

  # Las filas del listado a las que hay que ampliarles el `$select`.
  LIST_CODES = %w[getDocuments01 getDocuments02 getDocuments03 getDocuments04
                  getDocuments08 getDocuments09 getDocuments10].freeze

  # La consulta puntual, una por tipo de documento que `DocType` conoce y que NO
  # es mensaje de receptor — mismo universo y mismo mapeo tipo→entidad que
  # `getDocumentErrorDetails<tipo>` (`Invoices` para FE/ND/TE/FEE, `CreditNotes`
  # para NC, `PurchaseInvoices` para FEC, `IncomingPayments` para REP).
  #
  # Por llave (`Invoices(#DocEntry#)`) y no `$filter`: es un documento, y contra
  # la entidad el `$select` de un UDF sí es confiable (la advertencia de
  # `CheckSentDocumentsJob#header_for` aplica a las vistas `_B1SLQuery`).
  ROWS = [
    ['getDocumentXmlUrls01', # FE — Factura electrónica
     'URLs de los XML archivados de una factura electrónica',
     'Invoices(#DocEntry#)'],
    ['getDocumentXmlUrls02', # ND — Nota de débito electrónica
     'URLs de los XML archivados de una nota de débito electrónica',
     'Invoices(#DocEntry#)'],
    ['getDocumentXmlUrls03', # NC — Nota de crédito electrónica
     'URLs de los XML archivados de una nota de crédito electrónica',
     'CreditNotes(#DocEntry#)'],
    ['getDocumentXmlUrls04', # TE — Tiquete electrónico
     'URLs de los XML archivados de un tiquete electrónico',
     'Invoices(#DocEntry#)'],
    ['getDocumentXmlUrls08', # FEC — Factura electrónica de compra
     'URLs de los XML archivados de una factura electrónica de compra',
     'PurchaseInvoices(#DocEntry#)'],
    ['getDocumentXmlUrls09', # FEE — Factura electrónica de exportación
     'URLs de los XML archivados de una factura electrónica de exportación',
     'Invoices(#DocEntry#)'],
    ['getDocumentXmlUrls10', # REP — Recibo electrónico de pago
     'URLs de los XML archivados de un recibo electrónico de pago',
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

    LIST_CODES.each { |code| rewrite_select(code) { |fields| fields | XML_URL_FIELDS } }
  end

  def down
    MigrationSlResource.where(code: ROWS.map(&:first)).delete_all

    LIST_CODES.each { |code| rewrite_select(code) { |fields| fields - XML_URL_FIELDS } }
  end

  private

  # Toca ÚNICAMENTE la opción `$select` de la fila, dejando intactas las demás.
  #
  # `$filter` es justo lo que el cliente ajusta desde la pantalla de
  # mantenimiento (la `Series` que distingue FE de ND/TE/FEE varía por
  # instalación, `db/seeds.rb`), así que reescribir `query_params` entero le
  # borraría la configuración y el listado devolvería documentos de otro tipo.
  # Por el mismo motivo el cambio se aplica también a las filas personalizadas
  # (`is_standard = false`), que el seed se saltea: es aditivo y sin él la
  # pantalla se queda sin las dos acciones, en silencio.
  #
  # Una fila SIN `$select` no se toca: pide la entidad completa, así que las dos
  # URLs ya vienen.
  def rewrite_select(code)
    record = MigrationSlResource.find_by(code: code)
    return if record.nil?

    options = record.query_params.to_s.split('&')
    index   = options.index { |option| option.start_with?('$select=') }
    return if index.nil?

    fields = yield options[index].delete_prefix('$select=').split(',')
    return if fields.empty?

    options[index] = "$select=#{fields.join(',')}"
    record.update!(query_params: options.join('&'))
  end
end

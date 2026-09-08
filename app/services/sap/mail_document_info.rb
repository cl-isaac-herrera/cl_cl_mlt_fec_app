# frozen_string_literal: true

module Sap
  # Trae de SAP los datos del comprobante que necesita el cuerpo del correo de
  # recepción electrónica: consecutivo, receptor, clave, fecha de emisión,
  # monto, moneda, estado y las URLs de Azure de los XML a adjuntar.
  #
  #   info = Sap::MailDocumentInfo.new(company: company, doc_entry: 25, doc_type: '01', client: client).call
  #   info.string('CardName')   # => 'ACME S.A.'
  #   info.nil?                 # => true si el documento no aplica (ver abajo)
  #
  # Consume el catálogo `getMailDocumentInfo01`..`10` (`db/seeds.rb` →
  # `SL_RESOURCES_MAIL_DOCUMENT_INFO`), mismo mapeo tipo→entidad que
  # `Sap::IssuedDocumentsSearch`.
  #
  # ── El filtro por `send_rejected_documents` ──────────────────────────────
  # Si la compañía NO quiere correo de recepción para documentos Rechazados
  # (`company.send_rejected_documents?` en `false`), se le suma al `$filter`
  # del catálogo `U_CL_FEC_Status eq 6` (Aceptado) — mismo patrón de
  # composición que `Sap::IssuedDocumentsSearch#extra_filter` (combinar con
  # `Sap::ResourceQuery#merge`, nunca reemplazar el `$filter` del catálogo).
  # Un documento Rechazado con la compañía en `false` no matchea ese filtro:
  # `call` devuelve `nil`, y es la señal para que `SendElectronicReceiptJob`
  # marque la fila `Omitido` en vez de enviar el correo — NO es un error.
  class MailDocumentInfo
    # El tipo pedido no tiene una fila `getMailDocumentInfo<tipo>` en el
    # catálogo (no es de los 7 que `DocType` admite para esto, o la fila fue
    # dada de baja). A diferencia de un `nil` por el filtro de estado, ESTO sí
    # es un error de configuración.
    class UnsupportedDocType < StandardError; end

    ACCEPTED_STATUS = 6

    # @param company [Company] dueña del documento — decide el filtro de estado.
    # @param doc_entry [Integer] consecutivo interno de SAP.
    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param client [Clavisco::ServiceLayer::Client]
    def initialize(company:, doc_entry:, doc_type:, client:)
      @company   = company
      @doc_entry = doc_entry
      @doc_type  = doc_type
      @client    = client
    end

    # @return [Documents::Row, nil]
    def call
      rows = Array.wrap(client.get(query.path)).map { |row| Documents::Row.new(row) }
      rows.first
    rescue Sap::ResourceQuery::UnknownResource
      raise UnsupportedDocType, "El tipo de documento #{doc_type.inspect} no tiene una consulta " \
                                'configurada (catálogo `getMailDocumentInfo<tipo>`).'
    end

    private

    attr_reader :company, :doc_entry, :doc_type, :client

    def query
      base = Sap::ResourceQuery.new("getMailDocumentInfo#{doc_type}", bindings: { DocEntry: doc_entry })
      return base if company.send_rejected_documents?

      combined_filter = [base.params['$filter'], "U_CL_FEC_Status eq #{ACCEPTED_STATUS}"].compact.join(' and ')
      base.merge('$filter' => combined_filter)
    end
  end
end

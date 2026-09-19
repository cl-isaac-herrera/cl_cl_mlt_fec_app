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
  # Consume una ÚNICA fila del catálogo (`getMailDocumentInfo`, `db/seeds.rb` →
  # `SL_RESOURCES_MAIL_DOCUMENT_INFO`), no una por tipo: la vista
  # `CL_D_CL_MLT_FEC_SLT_DOCMAILINFO_B1SLQuery` ya une los cuatro objetos de SAP
  # que sincronizan documentos y expone `DocType`, así que lo único que cambia
  # entre un tipo y otro es el valor de `DocType` en el `$filter` — y eso ya es
  # un binding dinámico (`@DocType`), no hace falta una fila de catálogo por
  # tipo (a diferencia de `Sap::IssuedDocumentsSearch`/`getDocuments01`..`10`,
  # que sí necesitan una fila por tipo porque el `$filter` se hornea en el
  # catálogo, literal, para que el listado pueda filtrar por tipo sin que el
  # llamador arme el `$filter` a mano).
  #
  # ── El filtro por `send_rejected_documents` ──────────────────────────────
  # Si la compañía NO quiere correo de recepción para documentos Rechazados
  # (`company.send_rejected_documents?` en `false`), se le suma al `$filter`
  # del catálogo `Status eq 6` (Aceptado) — mismo patrón de
  # composición que `Sap::IssuedDocumentsSearch#extra_filter` (combinar con
  # `Sap::ResourceQuery#merge`, nunca reemplazar el `$filter` del catálogo).
  # `Status`, no `U_CL_FEC_Status`: la vista `DOCMAILINFO` renombra ese UDF al
  # exponerlo (ver `db/seeds.rb` → `SL_RESOURCES_MAIL_DOCUMENT_INFO`).
  # Un documento Rechazado con la compañía en `false` no matchea ese filtro:
  # `call` devuelve `nil`, y es la señal para que `SendElectronicReceiptJob`
  # marque la fila `Omitido` en vez de enviar el correo — NO es un error.
  class MailDocumentInfo
    # El tipo pedido no es uno de los que este correo aplica: un mensaje de
    # receptor (`05`/`06`/`07`, que no son comprobantes con `DocEntry` propio)
    # o un código que `DocType` no reconoce. Se valida ACÁ, antes de tocar SAP,
    # porque ahora el catálogo tiene una sola fila para los siete tipos válidos
    # y ya no hay una fila ausente que lo delate.
    class UnsupportedDocType < StandardError; end

    ACCEPTED_STATUS = 6

    RESOURCE_CODE = 'getMailDocumentInfo'

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
      unless mail_info_doc_type?
        raise UnsupportedDocType, "El tipo de documento #{doc_type.inspect} no tiene correo de recepción " \
                                  '(no es un comprobante con DocEntry propio, o Hacienda no lo reconoce).'
      end

      rows = Array.wrap(client.get(query.path)).map { |row| Documents::Row.new(row) }
      rows.first
    end

    private

    attr_reader :company, :doc_entry, :doc_type, :client

    # Los mensajes de receptor (`05`/`06`/`07`) no son comprobantes — no tienen
    # `DocEntry` propio en la vista — así que quedan fuera junto con cualquier
    # código que `DocType` no reconozca.
    def mail_info_doc_type?
      DocType.valid?(doc_type) && !DocType.receiver_message?(doc_type)
    end

    def query
      base = Sap::ResourceQuery.new(RESOURCE_CODE, bindings: { DocEntry: doc_entry, DocType: doc_type })
      return base if company.send_rejected_documents?

      combined_filter = [base.params['$filter'], "Status eq #{ACCEPTED_STATUS}"].compact.join(' and ')
      base.merge('$filter' => combined_filter)
    end
  end
end

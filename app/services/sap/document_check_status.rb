# frozen_string_literal: true

module Sap
  # Escribe en SAP el resultado de VERIFICAR contra Hacienda un comprobante que
  # ya estaba `Sent`.
  #
  #   Sap::DocumentCheckStatus.new(client: client, doc_type: '01', doc_entry: 25)
  #                          .call(status: Documents::PendingQueue::STATUS_ACCEPTED,
  #                                xml_response_url: url)
  #
  # ── Por qué NO es `Sap::DocumentStatus` ─────────────────────────────────────
  # `DocumentStatus` manda los SIETE campos SIEMPRE, a propósito (ver su propio
  # comentario): es correcto para el desenlace del ENVÍO, donde el llamador
  # sabe (o sabe que no sabe) `Clave`/`NumConsecutivo`/`XmlSentUrl` en cada
  # corrida. Acá esos tres YA están en SAP desde ese envío, y esta clase nunca
  # los toca: mandarlos como `nil` en este `PATCH` los borraría. Por eso `#call`
  # solo acepta los tres campos que una verificación puede cambiar.
  class DocumentCheckStatus
    # Mismo catálogo que `Sap::DocumentStatus` — es el mismo objeto de SAP.
    RESOURCE_PREFIX = 'updateDocument'

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía.
    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param doc_entry [Integer] `DocEntry` del documento en SAP.
    def initialize(client:, doc_type:, doc_entry:)
      @client = client
      @doc_type = doc_type
      @doc_entry = doc_entry
    end

    # @param status [Integer] `Documents::PendingQueue::STATUS_SENT` (sigue en
    #   proceso), `STATUS_ACCEPTED` o `STATUS_REJECTED`.
    # @param details [String, nil] el motivo del rechazo, o el de un error al
    #   consultar (la verificación falló pero el documento sigue `Sent`).
    # @param xml_response_url [String, nil] URL del XML de respuesta de
    #   Hacienda, ya archivado (`Documents::XmlArchive.store_response`).
    def call(status:, details: nil, xml_response_url: nil)
      client.patch(path, body: {
                     'U_CL_FEC_Status' => status,
                     'U_CL_FEC_ErrorDetails' => details,
                     'U_CL_FEC_XmlResponseUrl' => xml_response_url
                   })
    end

    private

    attr_reader :client, :doc_type, :doc_entry

    def path
      Sap::ResourceQuery.path_for("#{RESOURCE_PREFIX}#{doc_type}", DocumentEntry: doc_entry)
    end
  end
end

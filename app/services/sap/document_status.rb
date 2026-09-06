# frozen_string_literal: true

module Sap
  # Escribe en SAP cómo terminó el envío del comprobante a Hacienda.
  #
  #   Sap::DocumentStatus.new(client: client, doc_type: '01', doc_entry: 25)
  #                      .call(status: Documents::PendingQueue::STATUS_SENT,
  #                            clave: '506…', consecutivo: '00100001…')
  #
  # Es la mitad de SAP del paso 5 de `docs/sync-documents-flow.md`; la otra
  # mitad —la cola— la escribe `Documents::PendingQueue#mark`. Las dos guardan
  # el MISMO catálogo de estados (`STATUS_*`, que es el `dbo.StatusCodes` de la
  # base de la cola), a propósito: que el estado que ve alguien en SAP y el que
  # ve alguien en la cola sean el mismo número es lo que hace que los dos lados
  # se puedan comparar sin traducir.
  #
  # ⚠️ Ese catálogo NO es el del .NET legacy, que numeraba 1=Aceptado…7=Anulado.
  # Los dos no coinciden y confundirlos escribe un estado equivocado en SAP —
  # ver la nota de `#statusLabel` en `documents_issued_controller.js`.
  #
  # ── El objeto de SAP lo elige el catálogo, no esta clase ────────────────────
  # `updateDocument01`…`10` son filas de `sl_resources` (`db/seeds.rb` →
  # `SL_RESOURCES_STATUS_UPDATES`) y cada una ya sabe a qué entidad le pega:
  # `Invoices(#DocumentEntry#)` para FE/ND/TE/FEE, `CreditNotes` para NC,
  # `PurchaseInvoices` para FEC, `IncomingPayments` para REP. Acá solo se
  # compone el código con el tipo de documento.
  #
  # ── Los SIETE campos van SIEMPRE, en TODO desenlace ─────────────────────────
  # Error de validación propia, error de XSD, envío, rechazo o aceptación:
  # ninguno es un caso especial que recorte el body. `#call` no acepta un
  # subconjunto de argumentos — los siete parámetros están siempre en el `PATCH`,
  # con `nil` cuando el llamador no tiene ese dato todavía (por ejemplo, un
  # documento que no pasó la validación nunca llegó a firmarse, así que no hay
  # `xml_sent_url`). El llamador (`SyncIssuedDocumentsJob`) es quien decide qué
  # sabe en cada desenlace; esta clase no adivina ni omite.
  #
  # ⚠️ `fecha_emision` es el único de los siete que el llamador NUNCA rellena
  # fuera de un envío aceptado (`STATUS_SENT`) — ver `SyncIssuedDocumentsJob#sent`
  # vs. `#failed`. A diferencia de `clave`/`consecutivo` (que sí sobreviven a un
  # rechazo, porque ya existían en el payload antes de fallar), la fecha de
  # emisión ante Hacienda representa que Hacienda YA lo recibió: escribirla en
  # un desenlace que no fue un envío exitoso mentiría sobre si el documento
  # llegó a Hacienda.
  class DocumentStatus
    # Prefijo de las filas del catálogo. El sufijo es el código numérico de
    # Hacienda tal como lo trae la cola (`'01'`), así que no hay que traducir.
    RESOURCE_PREFIX = 'updateDocument'

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía.
    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param doc_entry [Integer] `DocEntry` del documento en SAP.
    def initialize(client:, doc_type:, doc_entry:)
      @client = client
      @doc_type = doc_type
      @doc_entry = doc_entry
    end

    # @param status [Integer] uno de los `Documents::PendingQueue::STATUS_*`.
    # @param details [String, nil] el motivo, cuando el estado es de falla.
    # @param clave [String, nil] la clave del comprobante.
    # @param consecutivo [String, nil] el número consecutivo.
    # @param xml_sent_url [String, nil] URL del XML firmado que se envió (`Documents::XmlArchive`).
    # @param xml_response_url [String, nil] URL del XML de respuesta de Hacienda.
    # @param fecha_emision [String, nil] fecha ISO 8601 de emisión, SOLO en un envío aceptado.
    def call(status:, details: nil, clave: nil, consecutivo: nil, xml_sent_url: nil, xml_response_url: nil,
             fecha_emision: nil)
      client.patch(path, body: {
                     'U_CL_FEC_Status' => status,
                     'U_CL_FEC_ErrorDetails' => details,
                     'U_CL_FEC_Clave' => clave,
                     'U_CL_FEC_NumConsecutivo' => consecutivo,
                     'U_CL_FEC_XmlSentUrl' => xml_sent_url,
                     'U_CL_FEC_XmlResponseUrl' => xml_response_url,
                     'U_CL_FEC_FechaEmision' => fecha_emision
                   })
    end

    private

    attr_reader :client, :doc_type, :doc_entry

    def path
      Sap::ResourceQuery.path_for("#{RESOURCE_PREFIX}#{doc_type}", DocumentEntry: doc_entry)
    end
  end
end

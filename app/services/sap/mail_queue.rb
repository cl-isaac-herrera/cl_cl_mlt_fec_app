# frozen_string_literal: true

module Sap
  # Lee y escribe en la UDT `@CL_FEC_MAILSQUEUE` —cuyos datos el Service Layer
  # expone como el entity set `U_CL_FEC_MAILSQUEUE`, que es el nombre que
  # guarda el catálogo (`db/seeds.rb` → `SL_RESOURCES_MAIL_QUEUE`)—
  # (`config/sap_schemas/outgoing_mails_udt.json`), el detalle del correo de
  # recepción electrónica de un documento: destinatarios, remitente y estado
  # visible en SAP. El CUERPO del correo no se guarda en ningún lado.
  #
  # Es a `SendElectronicReceiptJob`/`SyncIssuedDocumentsJob` lo que
  # `Sap::DocumentStatus` es a `SyncIssuedDocumentsJob`: el detalle vive en SAP
  # (para que el operador lo vea desde ahí), pero CUÁNDO reintentar el envío lo
  # decide la cola externa (`Documents::MailQueue`, `CLAUDE.md` §37) — las dos
  # bases comparten el MISMO catálogo de estados (`Documents::MailQueue::STATUS_*`),
  # a propósito, igual que `PendingQueue`/`DocumentStatus`.
  #
  # Las tres consultas del catálogo (`db/seeds.rb` → `SL_RESOURCES_MAIL_QUEUE`)
  # son las únicas que saben el path real de la UDT; acá solo se atan los
  # marcadores con `Sap::ResourceQuery`.
  class MailQueue
    QUERY_CODE  = 'getMailInformation'
    CREATE_CODE = 'createMailQueue'
    UPDATE_CODE = 'updateMailQueue'

    # `U_Type` del catálogo: 1 = Envío. El envío automático (aceptado/rechazado
    # por Hacienda) es el único flujo implementado hoy; un reenvío manual (2)
    # queda para cuando exista ese botón.
    TYPE_SEND = 1

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía.
    def initialize(client:)
      @client = client
    end

    # La fila de la UDT para este documento que todavía no terminó en Enviado
    # (el `$filter` ya excluye `U_Status = 4`, ver `SL_RESOURCES_MAIL_QUEUE`) —
    # o `nil` si SAP no tiene ninguna. En el caso normal hay a lo sumo una: el
    # aviso es para cuando el dato no cuadra con esa expectativa, no para
    # cortar la lectura.
    #
    # @return [Documents::Row, nil]
    def find(doc_entry:, doc_type:)
      rows = Array.wrap(client.get(query_path(doc_entry, doc_type))).map { |row| Documents::Row.new(row) }

      if rows.size > 1
        Rails.logger.warn(
          "[Sap::MailQueue] #{QUERY_CODE} devolvió #{rows.size} filas para " \
          "#{doc_type}/#{doc_entry}; se usa la primera."
        )
      end

      rows.first
    end

    # Registra el correo por enviar. Nace SIEMPRE en 1 (Pendiente, el
    # `DefaultValue` del schema) — quien decide un reenvío explícito es una
    # funcionalidad que todavía no existe.
    #
    # @return [String, nil] el `Code` que SAP asignó a la fila nueva.
    def create(doc_entry:, doc_type:, output_to:, output_cc:, output_bcc:)
      body = {
        'U_DocEntry'  => doc_entry,
        'U_DocType'   => doc_type,
        'U_Status'    => 1,
        'U_CreatedAt' => Time.current.iso8601,
        'U_OutputTo'  => output_to,
        'U_OutputCC'  => output_cc,
        'U_OutputBCC' => output_bcc,
        'U_Type'      => TYPE_SEND
      }

      Documents::Row.new(client.post(Sap::ResourceQuery.path_for(CREATE_CODE), body: body)).string('Code')
    end

    # Anota el desenlace de un intento de envío: estado, fecha del intento
    # (`U_LastAttempt`) y, según el caso, el motivo del error/de la omisión
    # (`U_Details`) o el remitente con el que salió el correo (`U_Email`).
    #
    # @param status [Integer] uno de `Documents::MailQueue::STATUS_*`.
    # @param details [String, nil] por qué falló o por qué se omitió el envío.
    # @param email [String, nil] el REMITENTE (`EmailConfig#email`) — no el
    #   cuerpo del correo, que no se persiste.
    def update_status(code:, status:, details: nil, email: nil)
      client.patch(Sap::ResourceQuery.path_for(UPDATE_CODE, Code: code), body: {
                     'U_Status'      => status,
                     'U_LastAttempt' => Time.current.iso8601,
                     'U_Details'     => details,
                     'U_Email'       => email
                   })
    end

    private

    attr_reader :client

    def query_path(doc_entry, doc_type)
      Sap::ResourceQuery.path_for(QUERY_CODE, DocEntry: doc_entry, DocType: doc_type)
    end
  end
end

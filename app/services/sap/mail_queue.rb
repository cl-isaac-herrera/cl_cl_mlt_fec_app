# frozen_string_literal: true

module Sap
  # Lee y escribe en la UDT `@CL_FEC_MAILSDETAILS` —cuyos datos el Service Layer
  # expone como el entity set `U_CL_FEC_MAILSDETAILS`, que es el nombre que
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
  # Las cuatro consultas del catálogo (`db/seeds.rb` → `SL_RESOURCES_MAIL_QUEUE`)
  # son las únicas que saben el path real de la UDT; acá solo se atan los
  # marcadores con `Sap::ResourceQuery`.
  #
  # La cuarta, `#list`, es la del PANEL "Correos" del listado de emitidos: el
  # historial completo del documento. Las otras tres son el flujo de envío.
  class MailQueue
    # Los `code` del catálogo. Decían "MailQueue" hasta que la UDT dejó de ser
    # una cola (`20260912110000_rename_mail_queue_sl_resource_codes.rb`): lo que
    # guarda es el detalle del correo, y cuándo reintentar lo decide la cola
    # externa (`Documents::MailQueue`, `CLAUDE.md` §37).
    QUERY_CODE  = 'getPendingDocumentMail'
    CREATE_CODE = 'createDocumentMail'
    UPDATE_CODE = 'updateDocumentMail'
    LIST_CODE   = 'getDocumentMails'
    FETCH_CODE  = 'getDocumentMailByCode'

    # `U_Type` del catálogo de la UDT.
    #
    # 1 = Envío — el automático, que crea `SyncIssuedDocumentsJob` cuando
    # Hacienda recibe el documento. Hay EXACTAMENTE UNO por documento y es el
    # primero: guarda los destinatarios originales, que es de donde el reenvío
    # sin "otros destinatarios" los copia (`Api::Documents::MailsController`).
    #
    # 2 = Reenvío — el que pide una persona desde el panel "Correos". Puede
    # haber muchos.
    TYPE_SEND   = 1
    TYPE_RESEND = 2

    # Un correo ya leído, como lo muestra el panel "Correos" del listado de
    # emitidos. `status` y `type` son los catálogos que declara el schema de la
    # UDT (`Documents::MailQueue::STATUS_*` y `TYPE_SEND`/`TYPE_RESEND`).
    #
    # `sender` es `U_Email`: el REMITENTE con el que salió el correo, no un
    # destinatario. El nombre de la UDT es ambiguo en una fila que además tiene
    # tres campos de destinatarios, así que acá se dice cuál de los dos es.
    Mail = Data.define(:code, :created_at, :last_attempt, :status, :type,
                       :output_to, :output_cc, :output_bcc, :sender, :details)

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía.
    def initialize(client:)
      @client = client
    end

    # La fila de la UDT por su `Code`: una entidad por llave, sin ambigüedad
    # posible. Es como `SendElectronicReceiptJob` resuelve QUÉ correo mandar —
    # el `Code` se lo dice la fila de la cola (`Documents::MailQueue::Entry
    # #udt_code`), que lo guardó al encolarse.
    #
    # @return [Documents::Row]
    # @raise [Clavisco::ServiceLayer::Client::NotFoundError] si el `Code` no existe.
    def fetch(code)
      Documents::Row.new(client.get(Sap::ResourceQuery.path_for(FETCH_CODE, Code: code)))
    end

    # La fila de la UDT para este documento que todavía no terminó en Enviado
    # (el `$filter` ya excluye `U_Status` 4 y 5, ver `SL_RESOURCES_MAIL_QUEUE`) —
    # o `nil` si SAP no tiene ninguna.
    #
    # ⚠️ Esto se usa al ENCOLAR, no al enviar. `CheckSentDocumentsJob` necesita
    # el `Code` del correo que `SyncIssuedDocumentsJob` registró en otra corrida,
    # y lo único que tiene es el documento. Ahí la búsqueda es legítima: el
    # documento acaba de resolverse y hay una sola fila pendiente.
    #
    # Para ENVIAR no se usa: ahí el `Code` viaja en la fila de la cola y se lee
    # con `#fetch`. Buscar por documento en ese momento sería adivinar, porque un
    # documento con reenvíos tiene varias filas vivas a la vez.
    #
    # Se queda con la MÁS RECIENTE (el `$orderby=Code desc` vive en el catálogo).
    # El aviso de abajo se queda: dos filas sin terminar al encolar siguen siendo
    # algo que conviene mirar.
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

    # TODOS los correos del documento, del más reciente al más viejo — el
    # `$orderby` vive en el catálogo, igual que el `$filter`.
    #
    # Es la lectura del PANEL, no la del envío: `#find` devuelve a lo sumo la
    # fila que todavía falta mandar (su `$filter` excluye Enviado y Omitido), y
    # acá hacen falta justamente esas. Por eso son dos consultas distintas del
    # catálogo y no una sola con dos usos.
    #
    # @return [Array<Mail>]
    def list(doc_entry:, doc_type:)
      rows = Array.wrap(client.get(Sap::ResourceQuery.path_for(LIST_CODE,
                                                               DocEntry: doc_entry, DocType: doc_type)))

      rows.map do |raw|
        row = Documents::Row.new(raw)

        Mail.new(
          code:         row.string('Code'),
          created_at:   row.string('U_CreatedAt'),
          last_attempt: row.string('U_LastAttempt'),
          status:       row.integer('U_Status'),
          type:         row.integer('U_Type'),
          output_to:    row.string('U_OutputTo'),
          output_cc:    row.string('U_OutputCC'),
          output_bcc:   row.string('U_OutputBCC'),
          sender:       row.string('U_Email'),
          details:      row.string('U_Details')
        )
      end
    end

    # Registra el correo por enviar. Nace SIEMPRE en 1 (Pendiente, el
    # `DefaultValue` del schema), sea envío o reenvío: lo que distingue a los
    # dos es `U_Type`, no el estado.
    #
    # ⚠️ Crear la fila NO manda nada. El disparador del envío es la cola externa
    # (`Documents::MailQueue.create`, `CLAUDE.md` §37); esta fila es el detalle
    # que `SendElectronicReceiptJob` va a leer cuando le toque. Quien registre
    # un reenvío tiene que hacer las DOS cosas.
    #
    # @param type [Integer] `TYPE_SEND` (automático) o `TYPE_RESEND` (a pedido).
    # @return [Integer, nil] el `Code` que SAP asignó a la fila nueva.
    #
    # Integer y no String aunque el Service Layer lo devuelva como texto: la UDT
    # es `bott_NoObjectAutoIncrement`, así que el `Code` es un consecutivo, y la
    # columna que lo guarda (`OutgoingMailsQueue.UdtCode`) es `int`. La
    # conversión pasa acá, en el borde, para que nadie más abajo tenga que
    # decidir si `'07'` y `7` son el mismo correo.
    def create(doc_entry:, doc_type:, output_to:, output_cc:, output_bcc:, type: TYPE_SEND)
      body = {
        'U_DocEntry'  => doc_entry,
        'U_DocType'   => doc_type,
        'U_Status'    => Documents::MailQueue::STATUS_PENDING,
        'U_CreatedAt' => Time.current.iso8601,
        'U_OutputTo'  => output_to,
        'U_OutputCC'  => output_cc,
        'U_OutputBCC' => output_bcc,
        'U_Type'      => type
      }

      Documents::Row.new(client.post(Sap::ResourceQuery.path_for(CREATE_CODE), body: body)).integer('Code')
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

# frozen_string_literal: true

module Api
  module Documents
    # Correos de recepción electrónica de un documento emitido: el panel
    # "Correos" del listado (`documents_issued_controller.js`).
    #
    # Viven en la UDT `@CL_FEC_MAILSDETAILS` de la compañía (`Sap::MailQueue`),
    # no en la base propia. Reemplazan `GET /api/Email/GetOutgoingMails?docId=N`
    # y `POST /api/Email/` del .NET, que leían y escribían la tabla
    # `OutgoingMails` con `spGetOutgoingMails` y `spResendDocEmail`.
    #
    # ── Por qué es un recurso anidado y no dos acciones del documento ──────────
    # Reenviar un correo no es una acción sobre el documento: CREA un correo
    # (`CLAUDE.md` §28 regla 4). Modelado así, listar y reenviar son el `index` y
    # el `create` del mismo recurso, y el documento es el padre del path — no un
    # `docId` suelto en la query string como en el .NET.
    #
    # `:document_id` es el `DocEntry` de SAP, no un id de la base de la app: el
    # listado viene de SAP y es lo único que puede ofrecer (ver
    # `Api::DocumentsController`). Por eso `doc_type` viaja siempre — la UDT
    # identifica el correo con el par `DocEntry` + `DocType`.
    class MailsController < AuthorizedController
      # El orden importa: primero el permiso (401/403), después los datos del
      # pedido. Un usuario sin permiso no tiene por qué enterarse de si mandó
      # bien los parámetros.
      before_action :authorize_action
      before_action :require_company!
      before_action :require_doc_type!

      # ⚠️ `create` envía un correo REAL a un cliente y hoy lo autoriza el mismo
      # permiso que ver la pantalla, que es lo más estricto que se puede sin
      # inventar un permiso que ningún rol tiene todavía (el .NET no pedía
      # ninguno: `EmailController` solo tiene `[Authorize]`). Un
      # `Documents_Emission_ResendMail` propio está anotado en `TODOS.md`.
      PERMISSIONS = {
        'index' => 'Documents_Issued_ViewDocuments',
        'create' => 'Documents_Issued_ViewDocuments'
      }.freeze

      # GET /api/documents/:document_id/mails?doc_type=01
      #
      # El historial completo, del más reciente al más viejo.
      def index
        items = mail_queue.list(doc_entry: doc_entry, doc_type: doc_type)

        render json: ApiResponse.success({ Items: items.map { |mail| serialize(mail) } }).to_h
      rescue *SAP_REQUEST_ERRORS => e
        render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
      rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
        render json: ApiResponse.error(e.sap_message || e.message).to_h, status: :bad_gateway
      end

      # POST /api/documents/:document_id/mails?doc_type=01
      # Cuerpo: { "OtherEmails": true, "MailTo": "a@x.com", "MailCC": "b@x.com" }
      #
      # Registra un REENVÍO. Son dos escrituras en dos lados distintos y las dos
      # hacen falta (ver `Sap::MailQueue#create`):
      #
      #   1. La fila de la UDT (`U_Type = 2`), con los destinatarios. Es el
      #      DETALLE que `SendElectronicReceiptJob` va a leer. El POST devuelve
      #      su `Code`.
      #   2. La fila de la cola externa (§37), con ese `Code` en `UdtCode`. Es el
      #      DISPARADOR: sin ella el job nunca mira este documento y la fila de
      #      la UDT no sirve de nada.
      #
      # En ese orden, a propósito, por dos motivos: el `Code` solo existe después
      # del paso 1, y la fila de la cola nace reclamable — encolar primero
      # abriría una ventana en la que el job reclama una fila cuyo detalle
      # todavía no existe y la marca como fallida.
      #
      # El reenvío SIEMPRE inserta su fila de cola, aunque el intento anterior
      # siga vivo: trae destinatarios propios y sin fila que la apunte, nadie la
      # manda. El dedupe del procedimiento solo protege al envío automático.
      #
      # El correo NO sale de acá. Esto deja el pedido registrado; lo manda el
      # job en su próxima corrida, con el mismo backoff que todo lo demás.
      def create
        recipients = resolve_recipients
        return if performed?

        udt_code = mail_queue.create(doc_entry: doc_entry, doc_type: doc_type,
                                     type: Sap::MailQueue::TYPE_RESEND, output_to: recipients[:to],
                                     output_cc: recipients[:cc], output_bcc: recipients[:bcc])

        if udt_code.blank?
          return render json: ApiResponse.error(
            'SAP no devolvió el identificador del correo registrado; no se encoló el reenvío.'
          ).to_h, status: :bad_gateway
        end

        ::Documents::MailQueue.create(sap_db: company.sap_db, doc_entry: doc_entry, doc_type: doc_type,
                                      udt_code: udt_code, type: Sap::MailQueue::TYPE_RESEND)

        render json: ApiResponse.success({ Message: 'Reenvío registrado; el correo sale en la próxima corrida.' }).to_h
      rescue *SAP_REQUEST_ERRORS => e
        render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
      rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
        render json: ApiResponse.error(e.sap_message || e.message).to_h, status: :bad_gateway
      rescue ExternalDb::ConfigurationError => e
        render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
      rescue ExternalDb::Error => e
        render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
      end

      private

      # Lo que impide siquiera intentar hablar con SAP: la compañía sin conexión
      # configurada o una consulta que no está en el catálogo. Las dos son 422
      # (el pedido no se puede resolver), no 502 (SAP contestó mal).
      SAP_REQUEST_ERRORS = [Sap::CompanyClient::MissingConfiguration,
                            Sap::ResourceQuery::UnknownResource].freeze

      # A quién se le reenvía.
      #
      # Con "otros destinatarios", lo que escribió la persona. Sin ellos, los
      # del correo de tipo Envío (1) — el automático, el primero y el único de
      # ese tipo: los destinatarios ORIGINALES del documento.
      #
      # Se copian los tres campos y no solo Para/CC: el reenvío es el mismo
      # correo saliendo de nuevo, y dejar afuera la copia oculta cambiaría en
      # silencio quién lo recibe. (El `spResendDocEmail` del .NET solo copiaba
      # dos, con la columna BCC existiendo al lado — no se replica el olvido.)
      #
      # @return [Hash] `{ to:, cc:, bcc: }`, o `nil` habiendo ya respondido.
      def resolve_recipients
        return custom_recipients if other_recipients?

        original = mail_queue.list(doc_entry: doc_entry, doc_type: doc_type)
                             .find { |mail| mail.type == Sap::MailQueue::TYPE_SEND }

        if original.nil?
          render json: ApiResponse.error(
            'Este documento no tiene un correo de envío original del cual tomar los destinatarios. ' \
            'Indique otros destinatarios para reenviarlo.'
          ).to_h, status: :unprocessable_content
          return nil
        end

        { to: original.output_to, cc: original.output_cc, bcc: original.output_bcc }
      end

      # "Para" es obligatorio cuando la persona elige los destinatarios. El .NET
      # trataba un "Para" vacío como si no hubiera pedido otros destinatarios y
      # mandaba el correo a los originales — silenciosamente, ignorando el CC que
      # sí había escrito. Acá se lo dice.
      def custom_recipients
        to = params[:MailTo].to_s.strip
        if to.empty?
          render json: ApiResponse.error('Indique al menos un destinatario en "Para".').to_h,
                 status: :unprocessable_content
          return nil
        end

        { to: to, cc: params[:MailCC].to_s.strip.presence, bcc: nil }
      end

      def other_recipients?
        ActiveModel::Type::Boolean.new.cast(params[:OtherEmails]) || params[:MailTo].present?
      end

      def serialize(mail)
        {
          Code: mail.code,
          CreatedAt: mail.created_at,
          LastAttempt: mail.last_attempt,
          Status: mail.status,
          Type: mail.type,
          OutputTo: mail.output_to,
          OutputCC: mail.output_cc,
          OutputBCC: mail.output_bcc,
          Sender: mail.sender,
          Details: mail.details
        }
      end

      # Un solo cliente de SAP por petición: `create` lo usa dos veces (leer el
      # correo original y escribir el reenvío) y no tiene sentido abrir dos.
      #
      # `Sap::CompanyClient` y no `Sap::UserClient` aunque haya una persona
      # detrás del click: la UDT de correos la escribe el proceso de fondo con
      # la licencia de servidor, y un reenvío tiene que quedar igual que un
      # envío para que `SendElectronicReceiptJob` no vea dos clases de fila.
      def mail_queue
        @mail_queue ||= Sap::MailQueue.new(client: Sap::CompanyClient.for(company))
      end

      def authorize_action
        require_permission!(PERMISSIONS.fetch(action_name))
      end

      def require_company!
        return if company

        render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
               status: :forbidden
      end

      def require_doc_type!
        @doc_type = DocType.normalize(params[:doc_type])
        return if @doc_type && !DocType.receiver_message?(@doc_type)

        render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
               status: :unprocessable_content
      end

      attr_reader :doc_type

      # El `DocEntry` de SAP (ver la nota de la clase).
      def doc_entry = params[:document_id].to_i

      # La compañía activa, validada contra las asignadas al usuario — el id
      # sale de la sesión, nunca de un parámetro (§28 regla 5).
      def company
        @company ||= Company.assigned_to(Current.user.id).find_by(id: Current.company_id)
      end
    end
  end
end

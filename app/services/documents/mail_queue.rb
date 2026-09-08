# frozen_string_literal: true

module Documents
  # Cola externa de correos de recepción electrónica pendientes de envío.
  #
  # Es a `SendElectronicReceiptJob` lo que `PendingQueue` es a
  # `SyncIssuedDocumentsJob`: vive en la base de documentos (`ExternalDb::Pool`,
  # `CLAUDE.md` §37), no en SAP. La UDT (`Sap::MailQueue`) guarda el DETALLE del
  # correo —destinatarios, cuerpo, estado visible en SAP—; esta cola solo
  # coordina CUÁNDO reintentar el envío, con el mismo backoff exponencial que
  # `PendingQueue` usa para los documentos (`CL_D_CL_MLT_FEC_SLT_PENDINGMAILS`).
  #
  # La fila UDT (`Sap::MailQueue`) se crea antes, en `SyncIssuedDocumentsJob`,
  # tan pronto Hacienda RECIBE el documento (`Sent`) — ahí ya se conocen los
  # destinatarios. Esta fila (la externa, el disparador real de envío) se crea
  # DESPUÉS, en `CheckSentDocumentsJob#queue_receipt_mail`, solo cuando Hacienda
  # se pronuncia (Aceptado o Rechazado): antes de eso no hay nada que enviar
  # todavía.
  #
  # Sin historial de intentos (a diferencia de `PendingQueue`/
  # `DocumentAttemptDetails`): el detalle de cada intento vive en la UDT
  # (`U_Details`), no en esta cola — es deliberadamente más chica.
  class MailQueue
    GROUP_CODE = 'DOCS_DB_ODBC'

    CREATE_PROCEDURE  = 'CL_D_CL_MLT_FEC_CRT_MAILTOQUEUE'
    PENDING_PROCEDURE = 'CL_D_CL_MLT_FEC_SLT_PENDINGMAILS'
    UPDATE_PROCEDURE  = 'CL_D_CL_MLT_FEC_UPT_MAIL'

    # Catálogo de estados. Es el MISMO que `U_Status` de la UDT
    # (`config/sap_schemas/outgoing_mails_udt.json`) y el `Status` de
    # `db/external/sql_server/schema.sql` → `OutgoingMailsQueue` — a propósito,
    # para que el estado que ve alguien en SAP y el de la cola sean el mismo
    # número (mismo criterio que `PendingQueue::STATUS_*` / `Sap::DocumentStatus`).
    STATUS_PENDING = 1
    STATUS_SENDING = 2
    STATUS_ERROR   = 3
    STATUS_SENT    = 4
    # El documento se resolvió (Rechazado) pero la compañía tiene
    # `send_rejected_documents = false`: no se manda correo A PROPÓSITO, no es
    # un fallo. Distinto de `STATUS_ERROR` para que no ensucie el monitoreo de
    # errores con algo esperado (`SendElectronicReceiptJob#skip`).
    STATUS_SKIPPED = 5

    # Una fila de la cola. Mismo shape que `PendingQueue::Entry`: `id` identifica
    # el intento de envío dentro de esta cola; `doc_entry` + `doc_type` +
    # `sap_db` identifican el documento en SAP.
    Entry = Data.define(:id, :doc_entry, :doc_type, :sap_db) do
      def to_s
        "correo##{id} #{sap_db}/#{doc_type}/DocEntry #{doc_entry}"
      end
    end

    class << self
      # @return [Array<Entry>]
      def pending
        new.pending
      end

      # @see #create
      def create(sap_db:, doc_entry:, doc_type:)
        new.create(sap_db: sap_db, doc_entry: doc_entry, doc_type: doc_type)
      end

      # @see #mark
      def mark(entry, status:)
        new.mark(entry, status: status)
      end
    end

    # @return [Array<Entry>] en el orden en que los devolvió el procedimiento.
    #
    # `commit: true` por la misma razón que `PendingQueue#pending`: es un
    # `UPDATE … OUTPUT` que reclama las filas, y el conector revierte por
    # defecto (§37) — sin la excepción la marca no queda y la misma tanda se
    # reprocesaría en cada corrida.
    def pending
      rows = ExternalDb::Pool.with(GROUP_CODE) { |client| client.call(PENDING_PROCEDURE, [], commit: true) }

      rows.filter_map { |row| build_entry(row) }
    end

    # Encola el envío de un correo ya registrado en la UDT.
    #
    # `commit: true`: el procedimiento SÍ escribe (inserta la fila) y el
    # conector revierte por defecto (§37).
    def create(sap_db:, doc_entry:, doc_type:)
      ExternalDb::Pool.with(GROUP_CODE) do |client|
        client.call(CREATE_PROCEDURE, [sap_db, doc_entry, doc_type], commit: true)
      end
    end

    # Anota el desenlace de un intento (estado, `Attempts += 1`, `UpdatedAt`
    # como fecha del último intento — el SP lo hace todo en una sola escritura).
    #
    # @param entry [Entry]
    # @param status [Integer] uno de los `STATUS_*`.
    def mark(entry, status:)
      ExternalDb::Pool.with(GROUP_CODE) do |client|
        client.call(UPDATE_PROCEDURE, [entry.id, status], commit: true)
      end
    end

    private

    # Mismo criterio que `PendingQueue#build_entry`: una fila sin los datos
    # mínimos se descarta con un aviso, no tumba la corrida completa.
    def build_entry(raw)
      row = Row.new(raw)

      id        = row.integer('Id')
      doc_entry = row.integer('DocEntry')
      doc_type  = row.string('DocType')
      sap_db    = row.string('SAPDB')

      if id.nil? || doc_entry.nil? || doc_type.nil? || sap_db.nil?
        Rails.logger.warn(
          "[Documents::MailQueue] fila incompleta en #{PENDING_PROCEDURE}, se omite: #{row.to_h.inspect}"
        )
        return nil
      end

      Entry.new(id: id, doc_entry: doc_entry, doc_type: DocType.normalize(doc_type) || doc_type, sap_db: sap_db)
    end
  end
end

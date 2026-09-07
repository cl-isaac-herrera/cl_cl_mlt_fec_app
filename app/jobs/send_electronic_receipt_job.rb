# frozen_string_literal: true

# Envío del correo de recepción electrónica: el aviso al receptor de que
# Hacienda aceptó o rechazó su comprobante. `CheckSentDocumentsJob` es quien
# encola cada correo (`#queue_receipt_mail`) en cuanto resuelve un documento;
# este job es la otra mitad, la que de verdad lo envía.
#
#   1. `Documents::MailQueue.pending` → la cola externa, por ODBC (con el mismo
#      backoff exponencial que `Documents::PendingQueue`)
#   2. `Sap::MailQueue#find`          → el detalle del correo en la UDT de SAP
#      (destinatarios, ver `config/sap_schemas/outgoing_mails_udt.json`)
#   3. `Documents::ReceiptMailer`     → arma y envía el correo por SMTP
#   4. `Sap::MailQueue#update_status` + `Documents::MailQueue.mark` → el
#      desenlace, en LOS DOS lados — mismo criterio que
#      `SyncIssuedDocumentsJob`/`Documents::PendingQueue`.
#
# ⚠️ Sin PDF adjunto. El legacy (`CLVS_FE.Mails/Common.cs#SendMail`, que es el
# correo de EMISIÓN y no el de recepción, pero comparte el mecanismo de
# adjuntos) arma el PDF del comprobante y lo adjunta; acá el cuerpo es un aviso
# mínimo, sin comprobante adjunto. Queda pendiente a propósito — anotar en
# `TODOS.md` cuando se retome.
#
# El horario vive en `config/recurring.yml`, igual que los otros dos jobs de
# sincronización.
class SendElectronicReceiptJob < ApplicationJob
  queue_as :send_electronic_receipt

  def perform
    entries = pending_entries
    return if entries.nil?

    if entries.empty?
      Rails.logger.info('[SendElectronicReceipt] no hay correos pendientes de envío.')
      return
    end

    @directory = Documents::CompanyDirectory.load
    @clients   = {}
    tally      = Hash.new(0)

    Rails.logger.info(
      "[SendElectronicReceipt] #{entries.size} correo(s) por enviar; " \
      "#{@directory.size} compañía(s) configurada(s)."
    )

    entries.each { |entry| tally[process(entry)] += 1 }

    Rails.logger.info("[SendElectronicReceipt] resultado: #{summarize(tally)}.")
  end

  private

  # Mismo criterio que `SyncIssuedDocumentsJob#pending_entries`: una
  # instalación a medio configurar no es un fallo del job.
  def pending_entries
    Documents::MailQueue.pending
  rescue ExternalDb::ConfigurationError => e
    Rails.logger.warn("[SendElectronicReceipt] sin conexión a la base de documentos: #{e.message}")
    nil
  end

  # @return [Symbol] cómo terminó, para el resumen del final.
  def process(entry)
    company = @directory.fetch(entry.sap_db)
    if company.nil?
      msg = "No hay una compañía activa con el código de base de SAP #{entry.sap_db.inspect}. " \
            "Configuradas: #{@directory.known_databases.inspect}."
      Rails.logger.warn("[SendElectronicReceipt] #{entry}: #{msg}")
      mark_queue(entry, Documents::MailQueue::STATUS_ERROR)
      return :sin_compania
    end

    mail_row = Sap::MailQueue.new(client: client_for(company)).find(doc_entry: entry.doc_entry, doc_type: entry.doc_type)
    if mail_row.nil?
      msg = 'SAP no tiene un registro pendiente en la UDT de correos para este documento.'
      Rails.logger.warn("[SendElectronicReceipt] #{entry}: #{msg}")
      mark_queue(entry, Documents::MailQueue::STATUS_ERROR)
      return :sin_udt
    end

    send_mail(entry, company, mail_row)
  rescue Documents::ReceiptMailer::MissingConfiguration => e
    Rails.logger.warn("[SendElectronicReceipt] #{entry}: #{e.message}")
    failed(entry, company, mail_row, e.message)
    :sin_configuracion
  rescue StandardError => e
    Sentry.capture_exception(e)
    Rails.logger.error("[SendElectronicReceipt] #{entry}: #{e.class}: #{e.message}")
    failed(entry, company, mail_row, "#{e.class}: #{e.message}")
    :error
  end

  def send_mail(entry, company, mail_row)
    body_html = receipt_body_html(entry)

    Documents::ReceiptMailer.new(
      company: company,
      to: mail_row.string('U_OutputTo'),
      cc: mail_row.string('U_OutputCC'),
      bcc: mail_row.string('U_OutputBCC'),
      body_html: body_html
    ).call

    Rails.logger.info("[SendElectronicReceipt] #{entry} · #{company.name} · correo enviado.")

    mark_udt(company, mail_row, status: Documents::MailQueue::STATUS_SENT, email: body_html)
    mark_queue(entry, Documents::MailQueue::STATUS_SENT)

    :enviado
  end

  # Cuerpo mínimo del correo de recepción. Placeholder deliberado: el legacy
  # arma un HTML con el logo de la compañía y los datos del comprobante
  # (Clave, NumeroConsecutivo, nombres de emisor/receptor), que exigirían otra
  # consulta a SAP no pedida en este cambio — ver el comentario de la clase.
  def receipt_body_html(entry)
    "<p>Se procesó el envío a Hacienda del comprobante #{DocType.label(entry.doc_type)} " \
      "(DocEntry #{entry.doc_entry}).</p>"
  end

  # Ni la UDT ni la cola externa pueden tumbar la tanda: se avisa y se sigue
  # con los correos que siguen (mismo criterio que `SyncIssuedDocumentsJob`).
  def failed(entry, company, mail_row, details)
    mark_udt(company, mail_row, status: Documents::MailQueue::STATUS_ERROR, details: details) if company && mail_row
    mark_queue(entry, Documents::MailQueue::STATUS_ERROR)
  end

  def mark_udt(company, mail_row, status:, details: nil, email: nil)
    Sap::MailQueue.new(client: client_for(company)).update_status(
      code: mail_row.string('Code'), status: status, details: details, email: email
    )
  rescue StandardError => e
    Rails.logger.error("[SendElectronicReceipt] no se pudo actualizar la UDT de correos — #{e.message}")
    Sentry.capture_exception(e)
  end

  def mark_queue(entry, status)
    Documents::MailQueue.mark(entry, status: status)
  rescue StandardError => e
    Rails.logger.error("[SendElectronicReceipt] #{entry}: no se pudo marcar el estado en la cola — #{e.message}")
    Sentry.capture_exception(e)
  end

  # ── Colaboradores por compañía ──────────────────────────────────────────────
  # Una sesión de SAP por compañía y no una por correo, mismo criterio que
  # `SyncIssuedDocumentsJob#client_for`.
  def client_for(company)
    @clients[company.id] ||= Sap::CompanyClient.for(company)
  end

  def summarize(tally)
    return 'nada que procesar' if tally.empty?

    tally.map { |outcome, count| "#{count} #{outcome}" }.join(', ')
  end
end

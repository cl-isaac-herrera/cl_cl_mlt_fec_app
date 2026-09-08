# frozen_string_literal: true

# Envío del correo de recepción electrónica: el aviso al receptor de que
# Hacienda aceptó o rechazó su comprobante. `SyncIssuedDocumentsJob` encola la
# fila de la UDT (destinatarios) tan pronto Hacienda recibe el documento;
# `CheckSentDocumentsJob` encola la fila externa (`#queue_receipt_mail`) recién
# al resolverse; este job es el último paso, el que de verdad envía.
#
#   1. `Documents::MailQueue.pending` → la cola externa, por ODBC (con el mismo
#      backoff exponencial que `Documents::PendingQueue`)
#   2. `Sap::MailQueue#find`          → el detalle del correo en la UDT de SAP
#      (destinatarios, ver `config/sap_schemas/outgoing_mails_udt.json`)
#   3. `Sap::MailDocumentInfo`        → los datos del comprobante para el
#      cuerpo del correo — `nil` cuando el documento Rechazado no debe
#      notificarse (`company.send_rejected_documents?` en `false`), y ahí el
#      desenlace es `Omitido`, NO un envío ni un error (`#skip`)
#   4. `Documents::XmlArchive.fetch`  → baja de Azure el XML enviado y el de
#      respuesta, para adjuntarlos
#   5. `Documents::ReceiptMailer`     → arma y envía el correo por SMTP
#   6. `Sap::MailQueue#update_status` + `Documents::MailQueue.mark` → el
#      desenlace, en LOS DOS lados — mismo criterio que
#      `SyncIssuedDocumentsJob`/`Documents::PendingQueue`.
#
# ⚠️ Sin PDF adjunto. El legacy (`CLVS_FE.Mails/Common.cs#SendMail`, que es el
# correo de EMISIÓN y no el de recepción, pero comparte el mecanismo de
# adjuntos) arma el PDF del comprobante y lo adjunta; acá no. Queda pendiente
# a propósito — anotar en `TODOS.md` cuando se retome.
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

    info = Sap::MailDocumentInfo.new(
      company: company, doc_entry: entry.doc_entry, doc_type: entry.doc_type, client: client_for(company)
    ).call
    return skip(entry, company, mail_row) if info.nil?

    send_mail(entry, company, mail_row, info)
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

  def send_mail(entry, company, mail_row, info)
    body_html = receipt_body_html(entry, company, info)
    attachments = build_attachments(info)

    Documents::ReceiptMailer.new(
      company: company,
      to: mail_row.string('U_OutputTo'),
      cc: mail_row.string('U_OutputCC'),
      bcc: mail_row.string('U_OutputBCC'),
      body_html: body_html,
      attachments: attachments
    ).call

    Rails.logger.info("[SendElectronicReceipt] #{entry} · #{company.name} · correo enviado.")

    mark_udt(company, mail_row, status: Documents::MailQueue::STATUS_SENT, email: body_html)
    mark_queue(entry, Documents::MailQueue::STATUS_SENT)

    :enviado
  end

  # El cuerpo del correo: logo de la compañía (si tiene uno legible, ver
  # `Documents::ReceiptMailer#embed_logo`), el nombre con el que se identifica
  # ante el receptor (`Company#email_sender_name`, legal o comercial según
  # `email_sender_type`) y los datos del comprobante que trajo
  # `Sap::MailDocumentInfo`.
  def receipt_body_html(entry, company, info)
    total = info.decimal('DocTotal')
    currency = info.string('DocCurrency')
    monto = total ? "#{ActiveSupport::NumberHelper.number_to_currency(total, unit: '', precision: 2,
                                                                              format: '%n')} #{currency}".strip : nil

    <<~HTML
      <div style="font-family: Arial, sans-serif; font-size: 14px; color: #1f2937;">
        <p><img src="cid:logo" alt="#{ERB::Util.html_escape(company.email_sender_name)}" style="max-height: 60px;"></p>
        <h2 style="margin: 0 0 8px;">#{ERB::Util.html_escape(company.email_sender_name)}</h2>
        <p>Se ha procesado ante Hacienda el siguiente comprobante electrónico:</p>
        <table cellpadding="4" cellspacing="0" style="border-collapse: collapse;">
          <tr><td><strong>Tipo</strong></td><td>#{ERB::Util.html_escape(DocType.label(entry.doc_type))}</td></tr>
          <tr><td><strong>Consecutivo</strong></td><td>#{ERB::Util.html_escape(info.string('U_CL_FEC_NumConsecutivo'))}</td></tr>
          <tr><td><strong>Clave</strong></td><td>#{ERB::Util.html_escape(info.string('U_CL_FEC_Clave'))}</td></tr>
          <tr><td><strong>Fecha de emisión</strong></td><td>#{ERB::Util.html_escape(info.string('U_CL_FEC_FechaEmision'))}</td></tr>
          <tr><td><strong>Receptor</strong></td><td>#{ERB::Util.html_escape(info.string('CardName'))}</td></tr>
          <tr><td><strong>Monto</strong></td><td>#{ERB::Util.html_escape(monto)}</td></tr>
          <tr><td><strong>Estado</strong></td><td>#{ERB::Util.html_escape(status_label(info))}</td></tr>
        </table>
      </div>
    HTML
  end

  def status_label(info)
    info.integer('U_CL_FEC_Status') == Sap::MailDocumentInfo::ACCEPTED_STATUS ? 'Aceptado' : 'Rechazado'
  end

  # Descarga de Azure el XML enviado y el de respuesta (`Documents::XmlArchive
  # .fetch`), para adjuntarlos — sin PDF, a propósito (ver el comentario de la
  # clase). Una URL vacía (el documento no llegó a esa etapa) simplemente no
  # aporta ese adjunto.
  def build_attachments(info)
    clave = info.string('U_CL_FEC_Clave')

    [
      ['U_CL_FEC_XmlSentUrl', "comprobante-#{clave}.xml"],
      ['U_CL_FEC_XmlResponseUrl', "respuesta-#{clave}.xml"]
    ].filter_map do |field, filename|
      url = info.string(field)
      next if url.nil?

      { filename: filename, mime_type: 'application/xml', content: Documents::XmlArchive.fetch(url) }
    end
  end

  # El documento se resolvió (Rechazado) pero la compañía no quiere correo de
  # recepción para eso (`company.send_rejected_documents?` en `false`): NO se
  # envía correo, y NO es un error — es la decisión de negocio funcionando
  # como se pidió. Se marca `Omitido` en los DOS lados para que la fila no
  # quede reintentando para siempre.
  def skip(entry, company, mail_row)
    details = 'Documento rechazado; la compañía no envía correo de recepción para documentos rechazados.'

    Rails.logger.info("[SendElectronicReceipt] #{entry} · #{company.name} · omitido — #{details}")

    mark_udt(company, mail_row, status: Documents::MailQueue::STATUS_SKIPPED, details: details)
    mark_queue(entry, Documents::MailQueue::STATUS_SKIPPED)

    :omitido
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

# frozen_string_literal: true

# Envío del correo de recepción electrónica: el aviso al receptor de que
# Hacienda aceptó o rechazó su comprobante. `SyncIssuedDocumentsJob` encola la
# fila de la UDT (destinatarios) tan pronto Hacienda recibe el documento;
# `CheckSentDocumentsJob` encola la fila externa (`#queue_receipt_mail`) recién
# al resolverse; este job es el último paso, el que de verdad envía.
#
#   1. `Documents::MailQueue.pending` → la cola externa, por ODBC (con el mismo
#      backoff exponencial que `Documents::PendingQueue`)
#   2. `Sap::MailQueue#fetch`         → el detalle del correo en la UDT de SAP
#      (destinatarios, ver `config/sap_schemas/outgoing_mails_udt.json`), leído
#      POR LLAVE con el `Code` que la fila de la cola trae en `UdtCode`. No se
#      busca "el correo pendiente del documento": un documento con reenvíos
#      tiene varias filas vivas a la vez y esa pregunta no tiene una sola
#      respuesta
#   3. `Sap::MailDocumentInfo`        → los datos del comprobante para el
#      cuerpo del correo — `nil` cuando el documento Rechazado no debe
#      notificarse (`company.send_rejected_documents?` en `false`), y ahí el
#      desenlace es `Omitido`, NO un envío ni un error (`#skip`)
#   4. `Documents::XmlArchive.fetch`  → baja de Azure el XML enviado y el de
#      respuesta, para adjuntarlos con el mismo nombre que tienen en Azure
#      (`Documents::XmlArchive.file_name`)
#   5. `Documents::ReceiptMailBody`   → arma el asunto y el cuerpo (HTML +
#      texto plano), con la plantilla `app/views/documents/receipt_mail.html.erb`
#   6. `Documents::ReceiptMailer`     → lo ensambla en MIME y lo envía por SMTP
#   7. `Sap::MailQueue#update_status` + `Documents::MailQueue.mark` → el
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

    if entry.udt_code.blank?
      msg = 'La fila de la cola no dice qué correo de la UDT manda (UdtCode vacío); ' \
            'se encoló antes de que la columna existiera.'
      Rails.logger.warn("[SendElectronicReceipt] #{entry}: #{msg}")
      mark_queue(entry, Documents::MailQueue::STATUS_ERROR)
      return :sin_udt
    end

    mail_row = fetch_mail_row(company, entry)
    if mail_row.nil?
      msg = "SAP no tiene el correo #{entry.udt_code} en la UDT."
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

  # El correo que esta fila de la cola manda, leído POR LLAVE. El `Code` lo
  # guardó la fila al encolarse, así que no hay que adivinar cuál de los correos
  # del documento es — con reenvíos puede haber varios vivos a la vez, cada uno
  # con destinatarios distintos.
  #
  # Un `Code` que no existe en SAP devuelve 404 y se trata como "no está", no
  # como una falla del enlace con SAP: la fila de la cola quedó apuntando a algo
  # que alguien borró de la UDT, y eso es un error de este correo, no de la tanda.
  def fetch_mail_row(company, entry)
    Sap::MailQueue.new(client: client_for(company)).fetch(entry.udt_code)
  rescue Clavisco::ServiceLayer::Client::NotFoundError
    nil
  end

  def send_mail(entry, company, mail_row, info)
    body = Documents::ReceiptMailBody.new(company: company, doc_type: entry.doc_type, info: info).call

    Documents::ReceiptMailer.new(
      company: company,
      to: mail_row.string('U_OutputTo'),
      cc: mail_row.string('U_OutputCC'),
      bcc: mail_row.string('U_OutputBCC'),
      subject: body.subject,
      body_html: body.html,
      body_text: body.text,
      inline_images: body.inline_images,
      attachments: build_attachments(info)
    ).call

    Rails.logger.info("[SendElectronicReceipt] #{entry} · #{company.name} · correo enviado.")

    # `U_Email` es el REMITENTE, no el cuerpo: la dirección de la bandeja con la
    # que salió el correo (`EmailConfig#email`, la misma que autentica contra el
    # SMTP). Es lo que el reporte de correos muestra en la columna "Remitente".
    # El cuerpo no se persiste en ningún lado, a propósito.
    mark_udt(company, mail_row, status: Documents::MailQueue::STATUS_SENT,
                                email: company.email_config&.email)
    mark_queue(entry, Documents::MailQueue::STATUS_SENT)

    :enviado
  end

  # Descarga de Azure el XML enviado y el de respuesta (`Documents::XmlArchive
  # .fetch`), para adjuntarlos — sin PDF, a propósito (ver el comentario de la
  # clase). Una URL vacía (el documento no llegó a esa etapa) simplemente no
  # aporta ese adjunto.
  #
  # El nombre del adjunto es el del blob (`Documents::XmlArchive.file_name`), no
  # uno que se arme acá: así el archivo que recibe quien abre el correo se llama
  # igual que el archivado (`<clave>.xml` y `<clave>_respuesta.xml`), y no hay
  # dos convenciones de nombre que se puedan separar sin que nadie lo note.
  def build_attachments(info)
    %w[U_CL_FEC_XmlSentUrl U_CL_FEC_XmlResponseUrl].filter_map do |field|
      url = info.string(field)
      next if url.blank?

      filename = Documents::XmlArchive.file_name(url)
      next if filename.blank?

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

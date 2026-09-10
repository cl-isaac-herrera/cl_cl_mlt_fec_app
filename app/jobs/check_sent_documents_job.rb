# frozen_string_literal: true

# Verificación periódica de los comprobantes que quedaron `Sent`.
#
# Un envío aceptado por Hacienda deja el comprobante en `Sent` (3), que es de
# TRÁNSITO: Hacienda todavía tiene que contestar si lo acepta o lo rechaza —
# ver el comentario de `SyncIssuedDocumentsJob` ("Enviar NO es el final"). Este
# job recoge esa resolución, la segunda mitad del flujo.
#
#   1. `Documents::PendingQueue.pending_check` → los `Sent` de la cola, por ODBC
#   2. `Documents::CompanyDirectory`            → compañía y conexión por `SAPDB`
#   3. `Sap::ResourceQuery` + la vista de cabecera → la `Clave` (ver `#header_for`
#      sobre por qué se trae la fila COMPLETA y no con `$select=Clave`)
#   4. `Hacienda::Client#check_status`          → `GET` a la URL de VERIFICACIÓN
#      (`HACIENDA_FE_URI_CHECK`), no la de envío
#   5. la cola y SAP                            → el desenlace
#   6. `Documents::MailQueue`                   → encola en la cola EXTERNA el
#      correo de recepción (`#queue_receipt_mail`), solo en un desenlace final
#      — la fila de la UDT (`Sap::MailQueue`) ya la creó `SyncIssuedDocumentsJob`
#      antes, tan pronto Hacienda recibió el documento
#
# ── Los dos desenlaces y su regla ───────────────────────────────────────────
#   · Hacienda contesta "aceptado"/"rechazado" (`CheckResult#resolved?`) → es
#     un desenlace FINAL: `Accepted`/`Rejected` en LOS DOS lados (cola y SAP,
#     mismo catálogo de estados — ver `Sap::DocumentStatus`), con el XML de
#     respuesta archivado (`Documents::XmlArchive.store_response`).
#   · Cualquier otra cosa (todavía "procesando"/"recibido", un error de red, un
#     HTTP que no es 2xx, una compañía o clave que no se resolvió) → el
#     documento se queda en `Sent`: no es un desenlace, es que todavía no hay
#     uno. El detalle (si lo hubo) se anota para que quede visible en la cola
#     y en SAP, pero el estado NUNCA escala a `Error` — ver `#stay_sent`.
#
# El horario vive en `config/recurring.yml`, igual que `SyncIssuedDocumentsJob`.
class CheckSentDocumentsJob < ApplicationJob
  queue_as :check_sent_documents

  def perform
    entries = pending_entries
    return if entries.nil?

    if entries.empty?
      Rails.logger.info('[CheckSentDocuments] no hay documentos Sent pendientes de verificar.')
      return
    end

    @directory = Documents::CompanyDirectory.load
    @clients   = {}
    @hacienda  = {}
    tally      = Hash.new(0)

    Rails.logger.info(
      "[CheckSentDocuments] #{entries.size} documento(s) por verificar; " \
      "#{@directory.size} compañía(s) configurada(s)."
    )

    entries.each { |entry| tally[process(entry)] += 1 }

    Rails.logger.info("[CheckSentDocuments] resultado: #{summarize(tally)}.")
  end

  private

  # Mismo criterio que `SyncIssuedDocumentsJob#pending_entries`: una
  # instalación a medio configurar no es un fallo del job.
  def pending_entries
    Documents::PendingQueue.pending_check
  rescue ExternalDb::ConfigurationError => e
    Rails.logger.warn("[CheckSentDocuments] sin conexión a la base de documentos: #{e.message}")
    nil
  end

  # @return [Symbol] cómo terminó, para el resumen del final.
  def process(entry)
    company = @directory.fetch(entry.sap_db)
    if company.nil?
      msg = "No hay una compañía activa con el código de base de SAP #{entry.sap_db.inspect}. " \
            "Configuradas: #{@directory.known_databases.inspect}."
      Rails.logger.warn("[CheckSentDocuments] #{entry}: #{msg}")
      stay_sent(entry, nil, msg)
      return :sin_compania
    end

    header = header_for(entry, company)
    clave  = header&.string('Clave')
    if clave.nil?
      msg = 'SAP no devolvió la clave del comprobante.'
      Rails.logger.warn("[CheckSentDocuments] #{entry}: #{msg}")
      stay_sent(entry, company, msg)
      return :sin_clave
    end

    check(entry, company, clave)
  rescue Hacienda::Client::TransientError, Hacienda::Client::InvalidCredentials => e
    Rails.logger.warn("[CheckSentDocuments] #{entry}: #{e.message}")
    stay_sent(entry, company, e.message)
    :hacienda_no_contesto
  rescue Sap::CompanyClient::MissingConfiguration, Hacienda::Client::MissingConfiguration => e
    # Falta configuración de la instalación: accionable por quien administra,
    # y ya se sabría por qué esta compañía no emite (ver `SyncIssuedDocumentsJob`).
    Rails.logger.warn("[CheckSentDocuments] #{entry}: #{e.message}")
    stay_sent(entry, company, e.message)
    :sin_configuracion
  rescue StandardError => e
    Sentry.capture_exception(e)
    Rails.logger.error("[CheckSentDocuments] #{entry}: #{e.class}: #{e.message}")
    stay_sent(entry, company, "#{e.class}: #{e.message}")
    :error
  end

  def check(entry, company, clave)
    result = hacienda_for(company).check_status(clave)

    unless result.resolved?
      Rails.logger.info(
        "[CheckSentDocuments] #{entry}: sigue en proceso en Hacienda " \
        "(ind-estado #{result.status.presence.inspect})."
      )
      stay_sent(entry, company, nil)
      return :en_proceso
    end

    resolved(entry, company, clave, result)
  end

  # El comprobante ya tiene un desenlace final.
  def resolved(entry, company, clave, result)
    status = result.accepted? ? Documents::PendingQueue::STATUS_ACCEPTED : Documents::PendingQueue::STATUS_REJECTED
    xml = result.xml_base64.present? ? Base64.decode64(result.xml_base64) : nil

    Rails.logger.info(
      "[CheckSentDocuments] #{entry} · #{company.name} · Hacienda respondió #{result.status}."
    )

    xml_response_url = archive_response(entry, company, clave, xml)
    details = detail_message(xml)

    mark_queue(entry, status: status, details: details)
    mark_sap(entry, company, status: status, details: details, xml_response_url: xml_response_url)
    queue_receipt_mail(entry)

    result.accepted? ? :aceptado : :rechazado
  end

  # Encola en la cola EXTERNA (`Documents::MailQueue`) el correo de recepción,
  # ahora que Hacienda ya se pronunció (aceptado o rechazado) — es esta fila la
  # que `SendElectronicReceiptJob` usa como disparador real de envío.
  #
  # La fila de la UDT (`Sap::MailQueue`, destinatarios y estado visible en
  # SAP) ya la creó `SyncIssuedDocumentsJob#queue_receipt_mail` tan pronto
  # Hacienda RECIBIÓ el documento (`Sent`), antes de esta resolución — acá no
  # hace falta volver a leer la cabecera para eso.
  #
  # Ni la cola externa puede tumbar la verificación del documento: es una
  # notificación aparte, no el desenlace que `#resolved` ya registró.
  def queue_receipt_mail(entry)
    Documents::MailQueue.create(sap_db: entry.sap_db, doc_entry: entry.doc_entry, doc_type: entry.doc_type)
  rescue StandardError => e
    Rails.logger.error("[CheckSentDocuments] #{entry}: no se pudo encolar el correo de recepción — #{e.message}")
    Sentry.capture_exception(e)
  end

  # El documento se queda en `Sent`: no es un desenlace, es que todavía no hay
  # uno (ver el comentario de la clase). `company` puede venir en `nil` cuando
  # ni siquiera se pudo resolver — ahí solo se anota en la cola.
  def stay_sent(entry, company, details)
    mark_queue(entry, status: Documents::PendingQueue::STATUS_SENT, details: details)
    mark_sap(entry, company, status: Documents::PendingQueue::STATUS_SENT, details: details) if company
  end

  # La fila COMPLETA de la cabecera, sin `$select`. Se probó acotar a
  # `$select=Clave` para no traer el documento entero de nuevo, pero SAP
  # Service Layer no mapea `$select` de forma confiable sobre estas vistas
  # (`view.svc`/`sml.svc`, SQL Queries y no una entidad OData nativa): con
  # `$select=Clave` a secas devolvía el VALOR bajo otro nombre de campo
  # (`OtrosDatos`), y solo se corrige agregando más columnas al `$select` —
  # comportamiento confirmado a mano contra SAP real, no una suposición. La
  # consulta sin `$select` es la MISMA que ya usa `Sap::DocumentDetails` y está
  # probada en producción, así que es la que se reutiliza acá.
  def header_for(entry, company)
    query = Sap::ResourceQuery.new(Sap::DocumentDetails::HEADER,
                                    bindings: { DocEntry: entry.doc_entry, DocType: entry.doc_type })

    rows = Array.wrap(client_for(company).get(query.path)).map { |row| Documents::Row.new(row) }
    rows.first
  end

  # El XML de respuesta se archiva SIEMPRE que Hacienda lo mandó (aceptado o
  # rechazado), aunque falle no impide anotar el desenlace: la URL queda en
  # `nil` y el estado se escribe igual — la resolución es el dato importante.
  def archive_response(entry, company, clave, xml)
    return nil if xml.nil?

    Documents::XmlArchive.store_response(company: company, clave: clave, xml: xml)
  rescue Documents::XmlArchive::MissingIdNumber, Azure::BlobStorage::MissingConfiguration,
         Azure::BlobStorage::TransientError, Azure::BlobStorage::RejectedError => e
    Rails.logger.error("[CheckSentDocuments] #{entry}: no se pudo archivar la respuesta de Hacienda — #{e.message}")
    Sentry.capture_exception(e)
    nil
  end

  # El detalle legible que trae la respuesta de Hacienda, del propio XML
  # (`MensajeHacienda` trae un `DetalleMensaje`) — SIEMPRE, no solo en el
  # rechazo: un comprobante ACEPTADO puede traer igual un `DetalleMensaje`
  # (una observación, por ejemplo) en el MISMO campo, y antes se descartaba a
  # propósito. Sin namespace: el XML de Hacienda lo declara y buscarlo
  # calificado obligaría a repetir la URI en cada `xpath`.
  def detail_message(xml)
    return nil if xml.nil?

    Nokogiri::XML(xml).remove_namespaces!.at_xpath('//DetalleMensaje')&.text&.strip.presence
  rescue StandardError
    nil
  end

  # Ni la cola ni SAP pueden tumbar la tanda: se avisa y se sigue con los
  # documentos que siguen (mismo criterio que `SyncIssuedDocumentsJob`).
  def mark_queue(entry, status:, details:)
    Documents::PendingQueue.mark(entry, status: status, details: details)
  rescue StandardError => e
    Rails.logger.error("[CheckSentDocuments] #{entry}: no se pudo marcar el estado en la cola — #{e.message}")
    Sentry.capture_exception(e)
  end

  def mark_sap(entry, company, status:, details: nil, xml_response_url: nil)
    Sap::DocumentCheckStatus.new(
      client:    client_for(company),
      doc_type:  entry.doc_type,
      doc_entry: entry.doc_entry
    ).call(status: status, details: details, xml_response_url: xml_response_url)
  rescue Sap::CompanyClient::MissingConfiguration => e
    Rails.logger.debug { "[CheckSentDocuments] #{entry}: tampoco se pudo actualizar SAP — #{e.message}" }
  rescue StandardError => e
    Rails.logger.error("[CheckSentDocuments] #{entry}: no se pudo actualizar el estado en SAP — #{e.message}")
    Sentry.capture_exception(e)
  end

  # ── Colaboradores por compañía ──────────────────────────────────────────────
  # Mismo criterio que `SyncIssuedDocumentsJob`: una sesión de SAP y un cliente
  # de Hacienda por compañía y por corrida, no por documento.

  def client_for(company)
    @clients[company.id] ||= Sap::CompanyClient.for(company)
  end

  def hacienda_for(company)
    @hacienda[company.id] ||= Hacienda::Client.new(company)
  end

  def summarize(tally)
    return 'nada que procesar' if tally.empty?

    tally.map { |outcome, count| "#{count} #{outcome}" }.join(', ')
  end
end

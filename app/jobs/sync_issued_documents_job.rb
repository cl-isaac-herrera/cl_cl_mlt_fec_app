# frozen_string_literal: true

# Sincronización periódica de documentos emitidos.
#
# Recorre los cinco pasos del flujo de `docs/sync-documents-flow.md`: lee la
# cola de documentos pendientes, arma cada uno con el detalle que trae de SAP,
# lo emite ante Hacienda y anota el desenlace en los dos lados.
#
#   1. `Documents::PendingQueue`     → la cola, por ODBC (paso 2)
#   2. `Documents::CompanyDirectory` → compañía y conexión por `SAPDB`
#   3. `Sap::DocumentDetails`        → las seis consultas de Service Layer
#   4. `Documents::UnifiedBuilder`   → el objeto unificado
#   5. `Documents::Issuer`           → validar, generar el XML, firmar, archivar y enviar (paso 4)
#   6. la cola y SAP                 → el estado, la clave, el consecutivo, el motivo y el
#                                       XML archivado (paso 5)
#
# ── El desenlace se anota en LOS DOS lados, con el MISMO número ──────────────
# `Documents::PendingQueue#mark` escribe en la cola y `Sap::DocumentStatus` en
# el documento de SAP, y los dos guardan el mismo catálogo de estados
# (`STATUS_*`). Así el estado que ve alguien en SAP y el que ve alguien en la
# cola son comparables sin traducir.
#
# ── Enviar NO es el final ────────────────────────────────────────────────────
# Un envío aceptado deja el comprobante en `Sent` (3), que es de TRÁNSITO:
# Hacienda contesta si lo acepta o lo rechaza después, y recogerlo es otra
# pasada que todavía no existe (necesita del lado de la cola un procedimiento
# que devuelva lo que está en `Sent`). Anotado en `TODOS.md`.
#
# El horario NO se decide acá — vive en `config/recurring.yml`, que es lo que lee
# el Scheduler de Solid Queue. Cambiar la frecuencia es cambiar ese archivo y
# reiniciar el worker; este archivo no se toca.
class SyncIssuedDocumentsJob < ApplicationJob
  queue_as :sync_issued_documents

  def perform
    entries = pending_entries
    return if entries.nil?

    if entries.empty?
      Rails.logger.info('[SyncIssuedDocuments] no hay documentos pendientes en la cola.')
      return
    end

    @directory = Documents::CompanyDirectory.load
    @clients   = {}
    @signers   = {}
    @hacienda  = {}
    tally      = Hash.new(0)

    Rails.logger.info(
      "[SyncIssuedDocuments] #{entries.size} documento(s) pendiente(s); " \
      "#{@directory.size} compañía(s) configurada(s)."
    )

    entries.each { |entry| tally[process(entry)] += 1 }

    Rails.logger.info("[SyncIssuedDocuments] resultado: #{summarize(tally)}.")
  end

  private

  # La cola pendiente, o `nil` si la instalación todavía no puede consultarla.
  #
  # ── Por qué la configuración faltante NO es un fallo del job ─────────────────
  # `ExternalDb::ConfigurationError` significa que el operador no terminó de
  # llenar Configuraciones → Generales. Es un estado normal de una instalación
  # recién puesta, no un incidente. Como esta tarea corre **cada dos minutos**,
  # dejarla fallar acumularía una ejecución fallida y un evento en Sentry cada dos
  # minutos, para siempre — y ese ruido es justo lo que hace que después nadie
  # mire las alertas de verdad.
  #
  # Lo que sí se deja fallar es todo lo demás: una base caída o credenciales
  # rechazadas (`ExternalDb::ConnectionError`) son transitorias o son un problema
  # real, y ahí la ejecución fallida es la señal correcta.
  def pending_entries
    Documents::PendingQueue.pending
  rescue ExternalDb::ConfigurationError => e
    Rails.logger.warn("[SyncIssuedDocuments] sin conexión a la base de documentos: #{e.message}")
    nil
  end

  # Un documento no puede tumbar la tanda.
  #
  # Cada fila de la cola es independiente: un XML mal formado, una compañía a
  # medio configurar o un timeout de SAP en el documento 3 no tienen por qué dejar
  # sin procesar los documentos 4 en adelante. Se registra el motivo con el
  # identificador de la fila y se sigue.
  #
  # ── La clasificación de la falla decide si el documento vuelve ──────────────
  # La pregunta que separa los `rescue` de abajo es una sola: **¿reintentar sin
  # que nadie toque nada puede funcionar?**
  #
  #   · Hacienda caída, un timeout, un 5xx  → sí  → `transient`, la fila queda
  #     en `Processing` y el procedimiento la vuelve a repartir en diez minutos.
  #   · El documento no cuadra, Hacienda lo rechaza, falta el certificado o un
  #     ajuste                              → no  → `Error`, con el motivo, para
  #     que alguien lo corrija.
  #
  # @return [Symbol] cómo terminó, para el resumen del final.
  def process(entry)
    # Se reinician por documento: son lo único que le permite a `failed`/`sent`
    # reportar `Clave`/`NumConsecutivo`/`xml_sent_url` a SAP en CUALQUIER
    # desenlace, incluido uno que revienta a mitad de camino — sin esto, un
    # rescue no tiene forma de ver lo que `emit` alcanzó a construir.
    @payload = nil
    @issuer = nil

    unless entry.known_type?
      return failed(entry, :tipo_desconocido,
                    "El tipo de documento #{entry.doc_type.inspect} no es un comprobante " \
                    'electrónico que este producto sepa emitir.')
    end

    company = @directory.fetch(entry.sap_db)
    if company.nil?
      return failed(entry, :sin_compania,
                    'No hay una compañía activa con el código de base de SAP ' \
                    "#{entry.sap_db.inspect}. Configuradas: #{@directory.known_databases.inspect}.")
    end

    emit(entry, company)
  rescue Documents::Issuer::ValidationFailed => e
    failed(entry, :invalido, validation_message(e), company: company)
  rescue Hacienda::XmlBuilder::InvalidValue => e
    failed(entry, :invalido, e.message, company: company)
  rescue Hacienda::XmlBuilder::UnsupportedDocType => e
    # Distinto de un rechazo: el documento puede estar perfecto y es ESTE
    # producto el que todavía no sabe armar su XML. El resumen lo cuenta aparte
    # para que se vea de un vistazo cuántos documentos quedan fuera por eso.
    failed(entry, :tipo_sin_xml, e.message, company: company)
  rescue Hacienda::Client::RejectedError => e
    failed(entry, :rechazado, e.message, company: company)
  rescue Sap::CompanyClient::MissingConfiguration,
         Hacienda::CompanySigner::MissingCertificate,
         Hacienda::Client::MissingConfiguration,
         Documents::XmlArchive::MissingIdNumber,
         Azure::BlobStorage::MissingConfiguration => e
    # No se llegó a hablar con nadie: falta configuración de la instalación. Es
    # accionable por quien administra, así que va como warn y no como error.
    failed(entry, :sin_configuracion, e.message, level: :warn, company: company)
  rescue Hacienda::Client::TransientError, Azure::BlobStorage::TransientError => e
    transient(entry, e.message)
  rescue StandardError => e
    # `Sentry.capture_exception` explícito: este rescue impide que la excepción
    # llegue al `on_thread_error` de Solid Queue (`config/initializers/solid_queue.rb`),
    # así que sin esto el fallo de un documento se quedaría solo en el log.
    Sentry.capture_exception(e)
    failed(entry, :error, "#{e.class}: #{e.message}", level: :error, company: company)
  end

  # Arma el documento y lo emite.
  def emit(entry, company)
    details = Sap::DocumentDetails.new(
      company:   company,
      doc_entry: entry.doc_entry,
      doc_type:  entry.doc_type,
      client:    client_for(company)
    ).call

    @payload = Documents::UnifiedBuilder.new(
      company:  company,
      doc_type: entry.doc_type,
      details:  details
    ).call

    @issuer = Documents::Issuer.new(
      doc_type: entry.doc_type,
      payload:  @payload,
      company:  company,
      signer:   signer_for(company),
      hacienda: hacienda_for(company)
    )
    receipt = @issuer.call

    sent(entry, company, receipt)
  end

  # ── Registro del desenlace ──────────────────────────────────────────────────

  # El comprobante quedó en poder de Hacienda.
  #
  # ⚠️ Si la cola NO acepta la marca, la fila se queda en `Processing` y a los
  # diez minutos se vuelve a repartir — o sea, el MISMO comprobante se le manda
  # a Hacienda otra vez. No es un problema: Hacienda contesta que ya lo había
  # recibido y `Hacienda::Client` trata esa respuesta como un envío bueno, con
  # el `Location` armado a partir de la clave. Por eso ese caso está manejado y
  # no es una curiosidad del protocolo.
  def sent(entry, company, receipt)
    clave = document_field('Clave')

    Rails.logger.info(
      "[SyncIssuedDocuments] #{entry} · #{company.name} · #{DocType.label(entry.doc_type)} · " \
      "clave #{clave.inspect} · enviado#{' (ya lo tenía Hacienda)' if receipt.duplicate?} · " \
      "resolución en #{receipt.location.inspect}"
    )

    mark_queue(entry) { Documents::PendingQueue.mark_sent(entry, receipt.location) }
    mark_sap(entry, company,
             status: Documents::PendingQueue::STATUS_SENT,
             clave: clave,
             consecutivo: document_field('NumeroConsecutivo'),
             xml_sent_url: @issuer.xml_sent_url)

    :enviado
  end

  # Registra la falla en el log, en la cola Y en SAP.
  #
  # Las tres cosas: el log es para quien está mirando el servidor, y la cola y
  # SAP son donde el operador puede ver qué pasó con SU documento sin pedirle a
  # nadie que le lea un archivo. Sin marcar la fila, queda en `Processing` —el
  # estado en que la dejó el reclamo— indistinguible de una que se está
  # procesando ahora, y el procedimiento la vuelve a repartir cada diez minutos
  # sin que nadie se entere de por qué nunca avanza.
  #
  # ── `Error` es TERMINAL, y es lo correcto ───────────────────────────────────
  # El procedimiento no vuelve a repartir un documento en estado `Error`, y así
  # tiene que ser: acá llega lo que NO se arregla reintentando —una validación
  # que no pasa, un rechazo de Hacienda, un certificado que falta—. Lo que sí se
  # arregla solo no pasa por este método, pasa por `#transient`.
  #
  # El camino de vuelta NO es el reintento sino SAP: cuando alguien corrige el
  # documento allá, el add-on lo vuelve a encolar con
  # `CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE`, que inserta una fila NUEVA. Por eso la
  # cola es un historial de intentos y no un registro por documento — el `Id` de
  # `Entry` es el del intento (ver `Documents::PendingQueue::Entry`).
  #
  # `company` puede venir en `nil` (no se supo cuál es, o falló al resolverla):
  # ahí solo se anota en la cola, que es lo único a lo que se puede llegar.
  #
  # `Clave`/`NumConsecutivo`/`xml_sent_url` se mandan si `@payload`/`@issuer`
  # alcanzaron a existir, aunque el desenlace sea un error: un documento que no
  # pasó la validación de Hacienda YA tenía payload (clave incluida) antes de
  # fallar, y uno que Hacienda rechazó después de firmar ya tiene su
  # `xml_sent_url`. Solo quedan en `nil` cuando de verdad no se llegó a esa
  # parte del flujo (`tipo_desconocido`, `sin_compania`, o un `StandardError`
  # que revienta mientras se consulta SAP).
  def failed(entry, outcome, details, level: :warn, company: nil)
    Rails.logger.public_send(level, "[SyncIssuedDocuments] #{entry}: #{details}")

    mark_queue(entry) { Documents::PendingQueue.mark_error(entry, details) }
    if company
      mark_sap(entry, company,
               status: Documents::PendingQueue::STATUS_ERROR,
               details: details,
               clave: document_field('Clave'),
               consecutivo: document_field('NumeroConsecutivo'),
               xml_sent_url: @issuer&.xml_sent_url)
    end

    outcome
  end

  # La falla no es del documento: no se anota en ningún lado.
  #
  # Dejar la fila en `Processing` ES el reintento — el procedimiento la vuelve a
  # repartir a los diez minutos (ver `Documents::PendingQueue::PROCEDURE`). Si
  # se marcara `Error`, media hora de Hacienda caída dejaría toda la cola en un
  # estado terminal y cada documento tendría que volver a emitirse a mano desde
  # SAP.
  def transient(entry, details)
    Rails.logger.warn(
      "[SyncIssuedDocuments] #{entry}: #{details} Queda en proceso y se reintenta solo."
    )

    :reintentable
  end

  # Ni la cola ni SAP pueden tumbar la tanda: si uno no acepta la marca, se
  # avisa y se sigue con los documentos que siguen. Son el registro del
  # desenlace, no una dependencia para poder trabajar.
  def mark_queue(entry)
    yield
  rescue StandardError => e
    Rails.logger.error(
      "[SyncIssuedDocuments] #{entry}: no se pudo marcar el estado en la cola — #{e.message}"
    )
    Sentry.capture_exception(e)
  end

  def mark_sap(entry, company, **fields)
    Sap::DocumentStatus.new(
      client:    client_for(company),
      doc_type:  entry.doc_type,
      doc_entry: entry.doc_entry
    ).call(**fields)
  rescue Sap::CompanyClient::MissingConfiguration => e
    # Si la compañía no tiene credenciales de SAP, no hay con qué escribirle: es
    # el MISMO problema que `#failed` acaba de registrar como el desenlace del
    # documento. Va en `debug` y sin Sentry para no decir dos veces lo mismo —
    # la tarea corre cada dos minutos y duplicaría cada aviso y cada alerta.
    Rails.logger.debug { "[SyncIssuedDocuments] #{entry}: tampoco se pudo actualizar SAP — #{e.message}" }
  rescue StandardError => e
    Rails.logger.error(
      "[SyncIssuedDocuments] #{entry}: no se pudo actualizar el estado en SAP — #{e.message}"
    )
    Sentry.capture_exception(e)
  end

  # Un campo del `Document` armado para esta corrida, o `nil` si `emit` no
  # llegó a construir el payload (`@payload` sigue en `nil`).
  def document_field(name)
    @payload&.dig('Document', name)
  end

  # Todas las reglas incumplidas y no solo la primera: el validador las acumula
  # justamente para que quien tiene que corregir el documento en SAP se entere
  # de todo de una vez y no de a una por intento.
  def validation_message(error)
    messages = error.errors.map(&:message)

    "El documento no cumple #{messages.size} regla(s) de Hacienda: #{messages.join(' ')}"
  end

  # ── Colaboradores por compañía ──────────────────────────────────────────────

  # Una sesión de SAP por compañía y no una por documento.
  #
  # El pool del Client ya reutiliza la sesión (la llave incluye `company_db`), así
  # que esto no es lo que evita el `/Login` de más — lo que evita es revalidar la
  # configuración de la conexión en cada fila de la cola, y que una compañía sin
  # credenciales repita el mismo mensaje una vez por documento.
  #
  # No se llama `logout` al terminar: la sesión se reutiliza entre corridas del
  # job y expira sola (CLAVISCO-PLATFORM-STANDARDS §2.7).
  def client_for(company)
    @clients[company.id] ||= Sap::CompanyClient.for(company)
  end

  # Un firmador por compañía: abrir el `.p12` descifra la llave privada y eso no
  # se repite por documento.
  def signer_for(company)
    @signers[company.id] ||= Hacienda::CompanySigner.for(company)
  end

  # Un cliente de Hacienda por compañía: el token se memoiza en la instancia, así
  # que es un `/token` por compañía y por corrida en vez de uno por documento.
  def hacienda_for(company)
    @hacienda[company.id] ||= Hacienda::Client.new(company)
  end

  def summarize(tally)
    return 'nada que procesar' if tally.empty?

    tally.map { |outcome, count| "#{count} #{outcome}" }.join(', ')
  end
end

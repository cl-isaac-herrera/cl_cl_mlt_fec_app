# frozen_string_literal: true

# Sincronización periódica de documentos emitidos.
#
# Implementa los pasos 2 y 3 del flujo de `docs/sync-documents-flow.md`: lee la
# cola de documentos pendientes y arma, por cada uno, el objeto unificado con el
# detalle que trae de SAP.
#
#   1. `Documents::PendingQueue`     → la cola, por ODBC (punto 1)
#   2. `Documents::CompanyDirectory` → compañía y conexión por `SAPDB` (punto 2)
#   3. `Sap::DocumentDetails`        → las seis consultas de Service Layer (3 a 9)
#   4. `Documents::UnifiedBuilder`   → el objeto unificado (punto 10)
#
# ⚠️ HASTA ACÁ LLEGA ESTA ETAPA. El objeto armado se registra en el log y se
# descarta: todavía NO se envía a Hacienda ni se actualizan los estados en la cola
# ni en SAP (pasos 4 y 5 del flujo). Es el corte que fija el punto 12 del
# documento.
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
  # @return [Symbol] cómo terminó, para el resumen del final.
  def process(entry)
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

    build(entry, company)
  rescue Sap::CompanyClient::MissingConfiguration => e
    # No se llegó a hablar con SAP: falta configuración de la instalación. Es
    # accionable por quien administra, así que va como warn y no como error.
    failed(entry, :sin_configuracion, e.message, level: :warn)
  rescue StandardError => e
    # `Sentry.capture_exception` explícito: este rescue impide que la excepción
    # llegue al `on_thread_error` de Solid Queue (`config/initializers/solid_queue.rb`),
    # así que sin esto el fallo de un documento se quedaría solo en el log.
    Sentry.capture_exception(e)
    failed(entry, :error, "#{e.class}: #{e.message}", level: :error)
  end

  # Registra la falla en el log Y en la cola.
  #
  # Las dos cosas, y no una: el log es para quien está mirando el servidor, y la
  # cola es donde el operador puede ver qué pasó con SU documento sin pedirle a
  # nadie que le lea un archivo. Sin marcar la fila, queda en `Processing` —el
  # estado en que la dejó el reclamo— indistinguible de una que se está
  # procesando ahora, y el procedimiento la vuelve a repartir cada diez minutos
  # sin que nadie se entere de por qué nunca avanza.
  #
  # ── `Error` es TERMINAL, y es lo correcto ───────────────────────────────────
  # El procedimiento no vuelve a repartir un documento en estado `Error`, y así
  # tiene que ser: la causa más común es un problema del documento mismo —una
  # validación que no pasa, un dato que falta— y reintentarlo sin que nadie lo
  # toque daría el mismo resultado indefinidamente.
  #
  # El camino de vuelta NO es el reintento sino SAP: cuando alguien corrige el
  # documento allá, el add-on lo vuelve a encolar con
  # `CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE`, que inserta una fila NUEVA. Por eso la
  # cola es un historial de intentos y no un registro por documento — el `Id` de
  # `Entry` es el del intento (ver `Documents::PendingQueue::Entry`).
  #
  # La consecuencia a tener presente: una falla de INSTALACIÓN (una licencia de
  # SAP sin llenar, un `$filter` mal sembrado) marca en error todo lo que haya en
  # la cola en ese momento, y esos documentos no vuelven solos. Está evaluado y
  # aceptado; la salida sería un estado aparte de "error técnico" que sí se
  # reintente, anotado en `TODOS.md` → Emisión de documentos.
  #
  # No puede tumbar la tanda: si la cola no acepta la marca, se avisa y se sigue
  # con el resto de los documentos.
  def failed(entry, outcome, details, level: :warn)
    Rails.logger.public_send(level, "[SyncIssuedDocuments] #{entry}: #{details}")

    begin
      Documents::PendingQueue.mark_error(entry, details)
    rescue StandardError => e
      Rails.logger.error(
        "[SyncIssuedDocuments] #{entry}: no se pudo marcar el error en la cola — #{e.message}"
      )
      Sentry.capture_exception(e)
    end

    outcome
  end

  def build(entry, company)
    details = Sap::DocumentDetails.new(
      company:   company,
      doc_entry: entry.doc_entry,
      doc_type:  entry.doc_type,
      client:    client_for(company)
    ).call

    payload = Documents::UnifiedBuilder.new(
      company:  company,
      doc_type: entry.doc_type,
      details:  details
    ).call

    log_built(entry, company, details, payload)
    :armado
  end

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

  # Qué se armó. Se registran CONTEOS y la clave, no el objeto: el payload lleva
  # nombres, identificaciones y montos de un contribuyente, y el log no es lugar
  # para eso.
  #
  # La clave sí va: es el identificador con el que se rastrea un comprobante ante
  # Hacienda y es lo primero que se necesita para diagnosticar.
  def log_built(entry, company, details, payload)
    Rails.logger.info(
      "[SyncIssuedDocuments] #{entry} · #{company.name} · #{DocType.label(entry.doc_type)} · " \
      "clave #{payload.dig('Document', 'Clave').inspect} · " \
      "#{details.lines.size} línea(s), #{details.payment_methods.size} medio(s) de pago, " \
      "#{details.other_charges.size} otro(s) cargo(s), #{details.references.size} referencia(s), " \
      "#{details.others.size} adicional(es)"
    )
  end

  def summarize(tally)
    return 'nada que procesar' if tally.empty?

    tally.map { |outcome, count| "#{count} #{outcome}" }.join(', ')
  end
end

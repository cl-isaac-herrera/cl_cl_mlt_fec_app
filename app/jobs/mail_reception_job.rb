# frozen_string_literal: true

# Servicio de lectura de bandejas de correo para recepción de documentos
# electrónicos emitidos por proveedores.
#
# Reemplaza el conector .NET legacy (`legacy/reception/clvsfemailsconector`):
# un ejecutable de consola que un scheduler externo corría cada tanto, sin
# ningún ciclo propio. Acá es un job recurrente cada 5 minutos
# (`config/recurring.yml`), mismo criterio que `SyncIssuedDocumentsJob`.
#
# ── Qué hace, y qué NO hace todavía ──────────────────────────────────────────
# Por cada bandeja activa (`ReceptionMailbox`):
#   1. Abre el Inbox (usuario/contraseña o XOAUTH2, `MailReception::ImapSession`).
#   2. Busca los correos NO LEÍDOS (tope blando por bandeja y tope duro por
#      corrida — ver la sección de límites más abajo).
#   3. Por cada adjunto que es un comprobante FE/ND/NC (tiene `Clave`, la
#      identificación del receptor, y su elemento raíz es uno de los tres que
#      este flujo procesa — `MailReception::IncomingDocument`; cualquier otro
#      tipo, incluida la respuesta de Hacienda que a veces viaja junto al
#      comprobante, se ignora en silencio), busca la compañía por esa
#      identificación (`Company#issuer_id_number`), archiva el .eml COMPLETO
#      del correo en su carpeta (`Documents::EmailArchive`), y registra la
#      cabecera + colecciones del mensaje receptor en las UDTs de SAP
#      (`MailReception::ReceivedDocument` parsea el XML,
#      `MailReception::EmailBodyTags` resuelve Mensaje/DetalleMensaje/
#      CondicionImpuesto/TaxFactor/CodigoActividadReceptor desde el cuerpo del
#      correo o los defaults de la compañía, `Sap::ReceptionMessages`
#      escribe).
#   4. Marca el correo como leído.
#
# Lo que SIGUE sin implementar: armar y enviar el XML del mensaje receptor a
# Hacienda, y crear la factura de compra en SAP cuando se acepta — eso deja
# `DocEntry`/`DocTypeSAP` en la cabecera, hoy siempre vacíos (CLAUDE.md §41,
# Prioridad 3). Tampoco replica `EmailProcessorLog`/`InboxProcessingTenant`
# del legacy (auditoría cruda del correo, bandeja compartida entre
# compañías) — ver `TODOS.md` → Recepción de documentos.
#
# ── Sin ejecuciones paralelas ────────────────────────────────────────────────
# `limits_concurrency` (Solid Queue) asegura que nunca haya dos corridas de
# este job al mismo tiempo: si el scheduler encola una nueva antes de que la
# anterior libere el semáforo, la nueva queda BLOQUEADA — no se descarta, y
# tampoco corre en paralelo — hasta que la primera termine o hasta que pasen
# `duration` (red de seguridad para el caso de un worker que muere a media
# conexión IMAP sin liberar el semáforo). `duration: 15.minutes` es tres veces
# el intervalo del scheduler (5 minutos): dos corridas perdidas de margen antes
# de asumir que la anterior quedó colgada.
#
# ── Límites: blando por bandeja, duro por corrida ────────────────────────────
# Mismo concepto que `MaxEmailsToReadPerInbox`/`MaxEmailsToReadPerExecution`
# del conector legacy, pero configurables (`MAIL_RECEPTION_MAX_MESSAGES_PER_*`
# en `settings`, Configuraciones → Generales) y recalculados para el intervalo
# de este job:
#
#   · BLANDO (`MAX_MESSAGES_PER_MAILBOX`) — tope de correos sin leer que se
#     toman de UNA bandeja en la corrida. Al llegar al tope, esa bandeja para
#     y las demás bandejas activas siguen procesándose normalmente.
#   · DURO (`MAX_MESSAGES_PER_EXECUTION`) — tope total de correos de TODA la
#     corrida, sumando todas las bandejas. Al llegar al tope, la corrida entera
#     se detiene ahí mismo — ninguna bandeja ni correo pendiente se procesa
#     hasta la corrida siguiente.
#
# Los valores del legacy (20 por bandeja, 350 por ejecución) estaban pensados
# para un scheduler externo cada 15 minutos. Este job corre cada 5 (un tercio
# del intervalo), así que los defaults son esos mismos números divididos entre
# 3 y redondeados hacia arriba — ver `DEFAULT_MAX_MESSAGES_PER_MAILBOX`/
# `DEFAULT_MAX_MESSAGES_PER_EXECUTION` — para no perder throughput proporcional
# de más por el redondeo. El operador puede ajustarlos desde
# Configuraciones → Generales sin esperar un deploy.
#
# ── Orden de las bandejas: la más atrasada primero ───────────────────────────
# `ReceptionMailbox#oldest_first` ordena por `last_processed_at` ascendente
# (`NULL` —nunca procesada— primero de todas). Con el límite duro activo, una
# corrida puede terminar sin llegar a todas las bandejas; sin este orden, las
# últimas de una lista fija (por `id`) podrían quedar sin turno corrida tras
# corrida si las primeras nunca dejan margen. `last_processed_at` se actualiza
# al terminar CADA intento sobre una bandeja, sea cual sea el desenlace —así
# una que revienta siempre no puede seguir colándose primera para siempre.
#
# ── Por qué se marca \Seen incluso sin match de compañía ─────────────────────
# El legacy marcaba \Seen en un `finally`, sin importar el resultado —incluso
# si la conexión a la base fallaba a mitad de camino—, y eso significaba que
# un fallo transitorio nunca se reintentaba solo (CLAUDE.md, análisis del
# conector, punto 15). Acá se distingue:
#
#   · Sin adjunto reconocible, o sin ninguna compañía con la identificación
#     del receptor → \Seen. Reintentar no cambia nada: ES un correo que no le
#     interesa a este job (spam, un XML que no es de Hacienda), o le falta una
#     compañía que alguien tiene que dar de alta — no algo que se arregle
#     reintentando.
#   · El `.eml` no se pudo archivar (Azure caído, sin credenciales
#     configuradas, o la compañía sin uuid válido) → NO se marca, sin importar
#     el motivo, y tampoco se intenta registrar el mensaje receptor en SAP. El
#     archivo del correo original es el dato que no se puede perder ni
#     reconstruir bajando el correo de nuevo por IMAP una vez marcado \Seen, así
#     que la corrida siguiente reintenta el correo completo — aunque el motivo
#     sea de configuración y no vaya a resolverse solo, es preferible seguir
#     reintentando (y quedar visible en Sentry/logs) a arriesgar perder el .eml.
#   · Con el `.eml` ya archivado, un fallo transitorio de sesión SAP al
#     registrar el mensaje receptor → tampoco se marca (se reintenta). Un
#     rechazo de SAP a los datos (no transitorio) → sí se marca: reintentar el
#     mismo cuerpo no lo arregla, y el `.eml` ya quedó a salvo.
class MailReceptionJob < ApplicationJob
  queue_as :mail_reception

  limits_concurrency to: 1, key: 'mail_reception', duration: 15.minutes

  # 20 correos/bandeja × (5 minutos / 15 minutos) = 6.67 → 7.
  DEFAULT_MAX_MESSAGES_PER_MAILBOX = 7
  # 350 correos/corrida × (5 minutos / 15 minutos) = 116.67 → 117.
  DEFAULT_MAX_MESSAGES_PER_EXECUTION = 117

  def perform
    mailboxes = ReceptionMailbox.where(is_active: true).oldest_first.to_a
    if mailboxes.empty?
      Rails.logger.info('[MailReception] no hay bandejas de recepción activas.')
      return
    end

    @max_per_mailbox   = configured_limit('MAX_MESSAGES_PER_MAILBOX', DEFAULT_MAX_MESSAGES_PER_MAILBOX)
    @max_per_execution = configured_limit('MAX_MESSAGES_PER_EXECUTION', DEFAULT_MAX_MESSAGES_PER_EXECUTION)
    @processed_count = 0

    tally = Hash.new(0)
    mailboxes.each do |mailbox|
      break if execution_limit_reached?(mailbox)

      process_mailbox(mailbox, tally)
    end

    Rails.logger.info("[MailReception] resultado: #{summarize(tally)}.")
  end

  private

  # El límite DURO: al llegar al tope de correos de la corrida, ni siquiera se
  # abre la conexión a las bandejas que quedan — todas terminan en la corrida
  # siguiente, sin gastar una sesión IMAP para nada.
  def execution_limit_reached?(next_mailbox)
    return false if @processed_count < @max_per_execution

    Rails.logger.warn(
      "[MailReception] límite duro alcanzado (#{@max_per_execution} correos en esta corrida); " \
      "#{next_mailbox.email} y las bandejas que faltan quedan para la próxima."
    )
    true
  end

  # Una bandeja que no conecta no puede tumbar la corrida completa: las demás
  # bandejas activas siguen procesándose.
  #
  # `last_processed_at` se marca en el `ensure`, así que queda al día pase lo
  # que pase adentro —éxito, error de conexión, lo que sea— con tal de que se
  # haya LLEGADO a intentar esta bandeja. Es lo que hace que `oldest_first`
  # reparta el turno entre corridas: una bandeja que revienta cada vez no
  # puede seguir colándose primera para siempre, y una que el límite duro deja
  # sin tocar (nunca entra acá) conserva su prioridad para la próxima.
  def process_mailbox(mailbox, tally)
    MailReception::ImapSession.new(mailbox).open do |imap|
      uids = imap.uid_search(['UNSEEN']).first(@max_per_mailbox)
      Rails.logger.info("[MailReception] #{mailbox.email}: #{uids.size} correo(s) sin leer.")

      uids.each do |uid|
        break if execution_limit_reached?(mailbox)

        process_message(imap, mailbox, uid, tally)
        @processed_count += 1
      end
    end
  rescue MailReception::ImapSession::ConnectionError, MailReception::OauthToken::Error => e
    Rails.logger.warn("[MailReception] #{mailbox.email}: no se pudo conectar — #{e.message}")
    tally[:sin_conexion] += 1
  rescue StandardError => e
    Sentry.capture_exception(e)
    Rails.logger.error("[MailReception] #{mailbox.email}: #{e.class}: #{e.message}")
    tally[:error] += 1
  ensure
    mailbox.update_column(:last_processed_at, Time.current)
  end

  # Un correo puntual que revienta al leerlo/parsearlo no puede tumbar los
  # demás correos de la bandeja.
  def process_message(imap, mailbox, uid, tally)
    raw = imap.uid_fetch(uid, 'RFC822').first.attr['RFC822']
    attachments = MailReception::IncomingDocument.attachments_from(raw)

    if attachments.empty?
      tally[:sin_documento] += 1
      mark_seen(imap, uid)
      return
    end

    outcomes = attachments.map { |attachment| archive(raw, mailbox, attachment) }
    outcomes.each { |outcome| tally[outcome] += 1 }
    # Si CUALQUIER adjunto falló al archivar el .eml (sea transitorio o de
    # configuración) o por un fallo transitorio de SAP, el correo entero queda
    # sin marcar: la corrida siguiente reintenta el correo completo, incluidos
    # los adjuntos que sí se archivaron (re-subir el mismo blob no es un
    # problema — `Azure::BlobStorage#upload` sobrescribe en el mismo path).
    mark_seen(imap, uid) unless (outcomes & %i[error_transitorio error_guardado_eml]).any?
  rescue StandardError => e
    Sentry.capture_exception(e)
    Rails.logger.error("[MailReception] #{mailbox.email} · uid #{uid}: #{e.class}: #{e.message}")
    tally[:error] += 1
    # No se marca \Seen: un fallo inesperado leyendo o parseando ESTE correo
    # puntual se reintenta solo en la corrida siguiente.
  end

  def archive(raw, mailbox, attachment)
    company = Company.find_by(issuer_id_number: attachment.receptor_id_number)
    if company.nil?
      Rails.logger.warn(
        "[MailReception] clave #{attachment.clave}: ninguna compañía tiene la identificación " \
        "#{attachment.receptor_id_number.inspect}."
      )
      return :sin_compania
    end

    store_eml(company, attachment, raw) || register_reception_message(raw, mailbox, company, attachment)
  end

  # El .eml es el dato que no se puede perder: si no se pudo archivar, el
  # correo NO se registra en SAP y NO se marca \Seen — sin importar si el
  # motivo es transitorio (Azure caído) o de configuración (falta credencial,
  # compañía sin uuid válido). Un motivo de configuración no se arregla solo
  # reintentando, pero es preferible seguir reintentando (y que el error quede
  # visible en Sentry/logs) a marcar leído un correo cuyo .eml nunca quedó
  # guardado — no hay forma de recuperarlo después sin bajarlo de nuevo por
  # IMAP, y ya estaría marcado \Seen.
  #
  # Devuelve `:error_guardado_eml` si falló, o `nil` si se archivó bien (para
  # que `archive` siga con `register_reception_message` solo en ese caso).
  def store_eml(company, attachment, raw)
    Documents::EmailArchive.store(company: company, clave: attachment.clave, eml: raw)
    nil
  rescue Azure::BlobStorage::TransientError => e
    Rails.logger.warn("[MailReception] clave #{attachment.clave}: Azure no disponible — #{e.message}")
    :error_guardado_eml
  rescue Azure::BlobStorage::MissingConfiguration, Azure::BlobStorage::RejectedError,
         Documents::EmailArchive::MissingUuid => e
    Sentry.capture_exception(e)
    Rails.logger.error("[MailReception] clave #{attachment.clave}: no se pudo archivar el .eml — #{e.message}")
    :error_guardado_eml
  end

  # Ya con el `.eml` archivado, registra la cabecera + colecciones del
  # mensaje receptor en las UDTs de SAP (`Sap::ReceptionMessages`). El .eml
  # ya quedó archivado aunque esto falle —no se deshace—: es la misma
  # asimetría que ya existe entre Azure y el resto del pipeline, y evita
  # volver a bajar el correo por IMAP solo para reintentar la parte de SAP.
  #
  # `:archivado` cubre los dos desenlaces exitosos posibles (con o sin datos
  # de mensaje receptor) porque, a diferencia del match de compañía, esto
  # nunca decide si el correo se reintenta — solo lo que se cuenta en el log
  # de resumen.
  def register_reception_message(raw, mailbox, company, attachment)
    message = ::Mail.read_from_string(raw)
    body = (message.text_part || message).body.decoded

    document = MailReception::ReceivedDocument.new(attachment.root, doc_type: attachment.doc_type)
    client = Sap::CompanyClient.for(company)
    Sap::ReceptionMessages.new(client: client).create_from_document(
      document: document, company: company, email_body: body, mailbox_email: mailbox.email
    )
    :archivado
  rescue Sap::CompanyClient::MissingConfiguration => e
    Rails.logger.warn(
      "[MailReception] clave #{attachment.clave}: sin configuración de SAP para " \
      "#{company.name.inspect} — #{e.message}"
    )
    :error_configuracion
  rescue Clavisco::ServiceLayer::Client::AuthenticationError,
         Clavisco::ServiceLayer::Client::SessionExpiredError => e
    # La sesión del pool se renueva sola en el próximo intento — no es un
    # rechazo de los datos, así que sí se reintenta.
    Rails.logger.warn("[MailReception] clave #{attachment.clave}: sesión de SAP no disponible — #{e.message}")
    :error_transitorio
  rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
    # SAP rechazó el POST (un campo fuera de `ValidValues`, una UDT sin
    # sincronizar, etc.): reintentar el mismo cuerpo nunca lo arregla solo.
    Sentry.capture_exception(e)
    Rails.logger.error(
      "[MailReception] clave #{attachment.clave}: SAP rechazó el mensaje receptor — #{e.message}"
    )
    :error_configuracion
  end

  def mark_seen(imap, uid)
    imap.uid_store(uid, '+FLAGS', [:Seen])
  rescue StandardError => e
    Rails.logger.error("[MailReception] no se pudo marcar el correo #{uid} como leído — #{e.message}")
  end

  # El valor configurado en `settings` (Configuraciones → Generales), o el
  # default calculado si no hay uno guardado o quedó en algo no numérico —
  # un ajuste mal escrito no puede tumbar el job cada 5 minutos.
  def configured_limit(field, default)
    Integer(Setting.value_for("MAIL_RECEPTION_#{field}"))
  rescue ArgumentError, TypeError
    default
  end

  def summarize(tally)
    return 'sin bandejas' if tally.empty?

    tally.map { |outcome, count| "#{count} #{outcome}" }.join(', ')
  end
end

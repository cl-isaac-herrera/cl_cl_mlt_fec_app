# frozen_string_literal: true

module EmailConfigs
  # Comprueba que una bandeja SMTP sirva de verdad: se conecta al host, se
  # autentica y **envía un correo de prueba** al destinatario que indique quien
  # está configurando.
  #
  # Reemplaza `POST /api/EmailConfig/ValidateEmailConfig` del servidor de
  # sincronización .NET.
  #
  # ── Por qué manda un correo y no solo abre la sesión SMTP ───────────────────
  # Autenticar prueba que el usuario y la contraseña son correctos, pero no que
  # el servidor deje SALIR el correo: relays que exigen que el `From` coincida
  # con la cuenta, cuentas sin permiso de envío y políticas anti-spam autentican
  # bien y rechazan el `MAIL FROM`/`RCPT TO`. Esos son justamente los casos que
  # se descubrirían en producción, con el primer comprobante que no llega.
  #
  # El costo es que la prueba necesita un destinatario, y por eso el formulario
  # pide uno: sin él no hay nada que comprobar más allá del login.
  #
  # ── Se prueba lo que está en el FORMULARIO, no lo guardado ──────────────────
  # Igual que `Sap::CredentialValidator` (§29): probar los valores guardados
  # después de escribir otros diría que las credenciales sirven cuando lo que se
  # está por guardar es distinto. `EmailConfig` guardado solo rellena la
  # contraseña, que el servidor nunca devuelve.
  #
  # Nunca levanta: cualquier fallo (host inalcanzable, credenciales rechazadas,
  # destinatario inválido) sale como un Result inválido con el motivo, porque
  # para la pantalla todos significan lo mismo — esa bandeja no sirve todavía.
  class CredentialValidator
    SUBJECT = 'Correo de prueba — configuración de bandeja de envío'

    # Cuánto se espera al SMTP antes de darlo por inalcanzable. Sin tope
    # explícito, `Net::SMTP` espera 60s para abrir y 60s más por comando, y un
    # host mal escrito deja la pantalla girando dos minutos con el botón
    # bloqueado.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    Result = Struct.new(:valid, :message, keyword_init: true) do
      def valid? = valid
    end

    # @param email_config [EmailConfig] la bandeja SIN GUARDAR que se arma con los
    #   valores del formulario. No se persiste: solo se le piden `host`, `port`,
    #   `ssl`, `email`, `password` y `from_header`.
    # @param recipient [String] a quién se le manda el correo de prueba.
    def initialize(email_config:, recipient:)
      @email_config = email_config
      @recipient    = recipient.to_s.strip
    end

    # @return [Result]
    def call
      missing = missing_prerequisite
      return failure(missing) if missing

      deliver!
      success
    rescue Net::SMTPAuthenticationError => e
      # El servidor contestó y rechazó el usuario/contraseña: es el caso que
      # prueba que las credenciales están mal.
      failure("El servidor de correo rechazó las credenciales: #{smtp_reason(e)}")
    rescue Net::SMTPFatalError, Net::SMTPSyntaxError => e
      # Autenticó pero no dejó salir el mensaje (relay denegado, remitente no
      # permitido, destinatario inválido). Es el fallo que solo aparece enviando.
      failure("El servidor de correo aceptó las credenciales pero rechazó el envío: #{smtp_reason(e)}")
    rescue Net::SMTPServerBusy, Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout,
           SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
           OpenSSL::SSL::SSLError, IOError => e
      failure("No se pudo contactar al servidor de correo #{destination}: #{e.message}")
    rescue StandardError => e
      # Red-de-seguridad: la gema `mail` envuelve algunos fallos en errores
      # propios. Se registra con el detalle y al usuario le llega el motivo.
      Rails.logger.warn("[EmailConfigs::CredentialValidator] fallo inesperado: #{e.class}: #{e.message}")
      failure("No se pudo enviar el correo de prueba: #{e.message}")
    end

    private

    attr_reader :email_config, :recipient

    def deliver!
      message = Mail.new
      message.from    = email_config.from_header
      message.to      = recipient
      message.subject = SUBJECT

      message.html_part = Mail::Part.new
      message.html_part.content_type = 'text/html; charset=UTF-8'
      message.html_part.body = body_html

      message.delivery_method(:smtp, smtp_settings)
      message.deliver!
    end

    # @return [String, nil] motivo por el que ni vale la pena abrir la conexión.
    def missing_prerequisite
      return 'Ingrese el correo, el host y el puerto de la bandeja antes de probar.' if destination_missing?
      return 'Ingrese la contraseña de la bandeja para poder probarla.' if email_config.password.blank?
      return 'Indique el correo destinatario al que se enviará la prueba.' if recipient.blank?
      return 'El correo destinatario de la prueba no tiene un formato válido.' unless recipient.match?(URI::MailTo::EMAIL_REGEXP)

      nil
    end

    def destination_missing?
      email_config.email.blank? || email_config.host.blank? || email_config.port.blank?
    end

    def destination = "#{email_config.host}:#{email_config.port}"

    def smtp_settings
      {
        address:              email_config.host,
        port:                 email_config.port,
        user_name:            email_config.email,
        password:             email_config.password,
        authentication:       :plain,
        enable_starttls_auto: email_config.ssl,
        open_timeout:         OPEN_TIMEOUT,
        read_timeout:         READ_TIMEOUT
      }
    end

    # El cuerpo dice CUÁL bandeja se probó: quien recibe la prueba puede ser
    # alguien distinto de quien la configuró, y "llegó un correo" sin más no le
    # sirve a ninguno de los dos.
    def body_html
      <<~HTML
        <p>Este es un correo de prueba enviado desde la configuración de bandejas de envío.</p>
        <p>La bandeja <strong>#{ERB::Util.html_escape(email_config.email)}</strong>
           (#{ERB::Util.html_escape(destination)}) está configurada correctamente.</p>
      HTML
    end

    # `Net::SMTP` mete la respuesta cruda del servidor en el mensaje; se le quita
    # el prefijo del código para que el usuario lea el motivo y no el protocolo.
    def smtp_reason(error)
      error.message.to_s.strip.presence || 'sin detalle'
    end

    def success = Result.new(valid: true, message: "Se envió un correo de prueba a #{recipient}.")
    def failure(message) = Result.new(valid: false, message: message)
  end
end

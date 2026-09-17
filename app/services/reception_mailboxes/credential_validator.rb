# frozen_string_literal: true

module ReceptionMailboxes
  # Comprueba que una bandeja de RECEPCIÓN sirva de verdad: abre una sesión
  # IMAP con las credenciales que sea (usuario/contraseña, o el token OAuth2
  # que arma `MailReception::OauthToken`) y selecciona el Inbox.
  #
  # Mismo criterio que `EmailConfigs::CredentialValidator` (envío) y
  # `Sap::CredentialValidator` (§29): se prueban los valores del FORMULARIO,
  # no los guardados, y nunca levanta — cualquier fallo vuelve como un Result
  # inválido con el motivo.
  class CredentialValidator
    Result = Struct.new(:valid, :message, keyword_init: true) do
      def valid? = valid
    end

    # @param mailbox [ReceptionMailbox] SIN GUARDAR, armada con los valores
    #   del formulario.
    def initialize(mailbox:)
      @mailbox = mailbox
    end

    # @return [Result]
    def call
      missing = missing_prerequisite
      return failure(missing) if missing

      MailReception::ImapSession.new(mailbox).open(&:noop)
      success
    rescue MailReception::OauthToken::Error => e
      failure("No se pudo obtener el token de acceso: #{e.message}")
    rescue MailReception::ImapSession::ConnectionError => e
      failure("No se pudo conectar a la bandeja: #{e.message}")
    rescue StandardError => e
      Rails.logger.warn("[ReceptionMailboxes::CredentialValidator] fallo inesperado: #{e.class}: #{e.message}")
      failure("No se pudo probar la bandeja: #{e.message}")
    end

    private

    attr_reader :mailbox

    def missing_prerequisite
      return 'Ingrese el servidor, el correo y el puerto de la bandeja antes de probar.' if destination_missing?
      return oauth_missing if mailbox.use_token?
      return 'Ingrese la contraseña de la bandeja para poder probarla.' if mailbox.password.blank?

      nil
    end

    def destination_missing?
      mailbox.mail_server.blank? || mailbox.email.blank? || mailbox.port.blank?
    end

    def oauth_missing
      return nil if mailbox.url.present? && mailbox.client_id.present? && mailbox.client_secret.present?

      'Complete la URL, el Client Id y el Client Secret para poder probar.'
    end

    def success = Result.new(valid: true, message: 'La conexión con la bandeja fue exitosa.')
    def failure(message) = Result.new(valid: false, message: message)
  end
end

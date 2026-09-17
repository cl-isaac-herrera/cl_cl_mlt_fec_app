# frozen_string_literal: true

require 'net/imap'

module MailReception
  # Conexión IMAP a una bandeja de recepción, con los dos modos de
  # autenticación que soporta `ReceptionMailbox`: usuario/contraseña o XOAUTH2
  # con un token de `MailReception::OauthToken`.
  #
  # A diferencia del legacy (`InboxHandler.OpenInbox`), que mezclaba llamadas
  # síncronas y asíncronas de MailKit según la rama y desactivaba la
  # validación del certificado TLS del lado de usuario/contraseña
  # (`ServerCertificateValidationCallback = (...) => true`), acá SIEMPRE se
  # valida el certificado —es el comportamiento por defecto de `Net::IMAP`
  # con `ssl: true`, y no se toca— y hay una sola API para los dos modos.
  class ImapSession
    class ConnectionError < StandardError; end

    # @param mailbox [ReceptionMailbox]
    def initialize(mailbox)
      @mailbox = mailbox
    end

    # Corre el bloque con el Inbox ya seleccionado y cierra la sesión siempre,
    # incluso si el bloque revienta — una conexión IMAP no correspondida deja
    # el recurso ocupado del lado del servidor de correo.
    #
    # @yield [Net::IMAP]
    # @raise [ConnectionError, MailReception::OauthToken::Error]
    def open
      imap = connect
      yield imap
    ensure
      close(imap)
    end

    private

    attr_reader :mailbox

    def connect
      imap = Net::IMAP.new(mailbox.mail_server, port: mailbox.port, ssl: true)
      authenticate(imap)
      imap.select('INBOX')
      imap
    rescue MailReception::OauthToken::Error
      raise
    rescue StandardError => e
      raise ConnectionError, enrich(e.message)
    end

    # El SELECT puede reventar con el token aceptado y todo: "authenticated
    # but not connected" es la respuesta textual que da Exchange Online cuando
    # el token de client credentials es válido pero el buzón no tiene IMAP
    # habilitado, o falta una Application Access Policy que le dé a esta app
    # (autenticación app-only, sin un usuario detrás) permiso sobre ESE buzón
    # en particular — el permiso `IMAP.AccessAsUser.All` que sugiere la
    # documentación de Microsoft es DELEGADO y no aplica acá. No es un bug de
    # esta app: es configuración pendiente del lado de Azure/Exchange, y el
    # mensaje del servidor por sí solo no dice eso.
    def enrich(message)
      return message unless mailbox.use_token? && message.to_s.match?(/authenticated but not connected/i)

      "#{message} — el token se aceptó pero Exchange Online no conectó la sesión IMAP a este buzón. " \
      'Habitual cuando el buzón no tiene IMAP habilitado, o cuando falta una Application Access Policy ' \
      '(`New-ApplicationAccessPolicy` en Exchange Online) que autorice a esta aplicación —con el permiso ' \
      'de Graph `full_access_as_app`— a acceder específicamente a este buzón.'
    end

    def authenticate(imap)
      if mailbox.use_token?
        token = MailReception::OauthToken.new(mailbox).fetch
        imap.authenticate('XOAUTH2', mailbox.email, token)
      else
        imap.login(mailbox.email, mailbox.password)
      end
    end

    # Ni un `logout` ni un `disconnect` que revienten pueden tapar el
    # resultado del bloque que ya corrió.
    def close(imap)
      return if imap.nil?

      begin
        imap.logout
      rescue StandardError
        nil
      end
      begin
        imap.disconnect
      rescue StandardError
        nil
      end
    end
  end
end

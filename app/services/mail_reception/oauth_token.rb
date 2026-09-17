# frozen_string_literal: true

module MailReception
  # Token de acceso OAuth2 (client credentials) para autenticar IMAP vía
  # XOAUTH2, contra cualquier proveedor de identidad compatible —Microsoft
  # Entra ID/Exchange Online, Google Workspace, u otro—: el mecanismo es
  # genérico (un POST a `mailbox.url` con `grant_type`/`scope`/`client_id`/
  # `client_secret`), no algo propio de un solo proveedor.
  #
  # Reemplaza la rama `UseToken` de `InboxHandler.OpenInbox` del conector .NET
  # legacy (`legacy/reception/clvsfemailsconector`), que pedía el token con un
  # `HttpClient` crudo y no comprobaba el código de respuesta antes de
  # deserializar — una credencial rechazada llegaba como una excepción de
  # `JsonConvert` sobre el cuerpo de error, no como un mensaje legible. Acá el
  # fallo de autenticación es una excepción propia con el motivo.
  class OauthToken
    class Error < StandardError; end

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15

    # @param mailbox [ReceptionMailbox]
    def initialize(mailbox)
      @mailbox = mailbox
    end

    # @return [String] el `access_token`.
    # @raise [Error]
    def fetch
      response = post
      raise Error, "El servidor de autenticación respondió #{response.code}: #{body_excerpt(response)}" unless
        response.is_a?(Net::HTTPSuccess)

      token = JSON.parse(response.body)['access_token']
      raise Error, 'La respuesta no incluyó un access_token.' if token.blank?

      token
    rescue JSON::ParserError => e
      raise Error, "La respuesta del servidor de autenticación no es JSON válido: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
           Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error, "No se pudo contactar el servidor de autenticación: #{e.message}"
    end

    private

    attr_reader :mailbox

    def post
      uri = URI(mailbox.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.post(uri.request_uri, URI.encode_www_form(form_data),
                'Content-Type' => 'application/x-www-form-urlencoded')
    end

    def form_data
      {
        'grant_type' => mailbox.grant_type,
        'scope' => mailbox.scope,
        'client_id' => mailbox.client_id,
        'client_secret' => mailbox.client_secret
      }
    end

    # No se expone el cuerpo entero: un error de Microsoft identity platform
    # trae `error_description` con detalle suficiente, y el cuerpo completo
    # puede traer un `client_secret` reflejado en un mensaje de validación.
    def body_excerpt(response)
      JSON.parse(response.body)['error_description'] || response.message
    rescue JSON::ParserError
      response.message
    end
  end
end

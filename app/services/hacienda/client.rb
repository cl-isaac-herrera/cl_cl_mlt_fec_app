# frozen_string_literal: true

module Hacienda
  # Cliente de los web services del Ministerio de Hacienda: pide el token y
  # envía el comprobante ya firmado.
  #
  #   receipt = Hacienda::Client.new(company).send_document(
  #     clave:           '506…',
  #     comprobante_xml: signed_b64,
  #     fecha:           '2026-09-06T10:00:00-06:00',
  #     emisor:          { 'numeroIdentificacion' => '3101…', 'tipoIdentificacion' => '02' },
  #     receptor:        { 'numeroIdentificacion' => '1234…', 'tipoIdentificacion' => '01' }
  #   )
  #   receipt.location   # => la URL donde Hacienda va a publicar la resolución
  #
  # ── De dónde sale cada dato ─────────────────────────────────────────────────
  # Las tres URLs, el `client_id` y el `grant_type` son del AMBIENTE contra el
  # que emite la instalación (`settings`, grupo `HACIENDA_FE`); el usuario y la
  # contraseña del ATV son del CONTRIBUYENTE, así que salen de la compañía. El
  # .NET tenía los cinco por compañía (`Company.cs:47-51`) — la división es un
  # cambio deliberado de esta versión, documentado en
  # `20260906120000_move_hacienda_client_credentials_to_settings.rb`.
  #
  # ── Dos diferencias DELIBERADAS con el .NET ────────────────────────────────
  # 1. **Se verifica el certificado TLS.** El legacy instalaba un
  #    `ServerCertificateValidationCallback` que devuelve `true` siempre
  #    (`TransaccionesHacienda.cs:415`), o sea aceptaba cualquier certificado:
  #    eso deja el token y el comprobante expuestos a un intermediario. Los
  #    servidores de Hacienda tienen certificado válido y no hace falta.
  # 2. **El envío declara `Content-Type: application/json`.** El legacy hacía
  #    `httpRequest.Content.Headers.Clear()` (`:307`) y mandaba el cuerpo SIN
  #    Content-Type. Es lo que documenta Hacienda y lo que corresponde; si
  #    alguna vez apareciera un 415 o un 400 sin causa, esto es lo primero que
  #    hay que mirar.
  #
  # ── Recoger la resolución es otra pasada ────────────────────────────────────
  # Enviar deja el comprobante en tránsito; Hacienda contesta después. `#check_status`
  # es el `GET` que consulta esa resolución — lo llama `CheckSentDocumentsJob`, no
  # este mismo envío, porque el legacy esperaba (`sleepToCheck`) y consultaba en el
  # mismo request, y dormir dentro de un job retiene un hilo del worker.
  class Client
    class Error < StandardError; end

    # Falta un ajuste o una credencial. No se llegó a hablar con Hacienda, así
    # que no es una falla del envío: es una instalación a medio configurar.
    class MissingConfiguration < Error; end

    # Falla que NO es del documento: la red, un timeout, un 5xx de Hacienda o un
    # rechazo de autenticación. El documento sigue siendo válido y se puede
    # reintentar tal cual — ver por qué eso importa en `SyncIssuedDocumentsJob`.
    class TransientError < Error; end

    # Hacienda no aceptó el comprobante por lo que el comprobante ES. Reintentar
    # sin corregirlo da el mismo resultado.
    class RejectedError < Error; end

    # Hacienda rechazó el usuario/contraseña del ATV o el Client ID al pedir el
    # token (un 4xx en `POST /token`, no un 5xx). Es distinto de `RejectedError`
    # —no es el comprobante, es la credencial de la compañía— y de
    # `TransientError` —no se arregla solo reintentando, hace falta que alguien
    # corrija la credencial en la compañía o el ajuste—.
    class InvalidCredentials < Error; end

    # Timeouts propios y no los del default de `Net::HTTP` (60 s de lectura, sin
    # tope de apertura): el job corre cada dos minutos y procesa los documentos
    # en fila, así que un Hacienda que no contesta no puede quedarse con la
    # tanda entera. Son los mismos números que usa `proxy_controller.rb`.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    # Lo que responde Hacienda cuando el comprobante ya le había entrado. No es
    # un error: el documento está en su poder y la resolución se consulta igual,
    # así que se trata como un envío exitoso (mismo criterio que el legacy,
    # `TransaccionesHacienda.cs:380`).
    ALREADY_RECEIVED = 'fue recibido anteriormente'

    # Hacienda pone el motivo real del rechazo en este header, no en el cuerpo.
    ERROR_CAUSE_HEADER = 'X-Error-Cause'

    # Los dos valores de `ind-estado` que son un desenlace FINAL. Los demás
    # (`recibido`, `procesando`, o cualquiera que Hacienda agregue) significan
    # que el comprobante sigue en tránsito — ver `CheckResult#resolved?`.
    STATUS_ACCEPTED = 'aceptado'
    STATUS_REJECTED = 'rechazado'

    # Cómo se nombra cada credencial del ATV en el mensaje de configuración
    # faltante. El operador las conoce por su etiqueta en la pantalla de la
    # compañía, no por el nombre de la columna.
    CREDENTIAL_LABELS = {
      token_user: 'el usuario',
      token_password: 'la contraseña'
    }.freeze

    # Acuse del envío. `location` es lo único que hay que guardar: es la URL
    # donde Hacienda va a publicar si aceptó o rechazó el comprobante.
    #
    # `duplicate` distingue "lo recibí ahora" de "ya lo tenía". Los dos son un
    # envío bueno y se anotan igual; la diferencia sirve para el log, donde un
    # duplicado dice que hubo un reintento y no un envío nuevo.
    Receipt = Data.define(:location, :duplicate) do
      def duplicate? = duplicate
    end

    # Lo que contesta Hacienda al consultar el estado de un comprobante.
    #
    # `xml_base64` solo viene (de Hacienda, y por eso solo se guarda) cuando
    # `status` es `STATUS_ACCEPTED`/`STATUS_REJECTED` (mismo criterio que el
    # legacy, `TransaccionesHacienda.cs:454`): en `recibido`/`procesando`
    # Hacienda todavía no tiene una respuesta que devolver.
    CheckResult = Data.define(:status, :xml_base64) do
      def resolved?
        [STATUS_ACCEPTED, STATUS_REJECTED].include?(status)
      end

      def accepted? = status == STATUS_ACCEPTED
    end

    def initialize(company)
      @company = company
    end

    # Manda el comprobante firmado.
    #
    # @param clave [String] la clave de 50 dígitos del comprobante.
    # @param comprobante_xml [String] Base64 del XML firmado (`XmlSigner#sign`).
    # @param fecha [String] fecha de emisión, ISO 8601 con offset.
    # @param emisor [Hash] `{ 'numeroIdentificacion' =>, 'tipoIdentificacion' => }`
    # @param receptor [Hash] igual que `emisor`.
    # @return [Receipt]
    # @raise [MissingConfiguration, TransientError, RejectedError, InvalidCredentials]
    def send_document(clave:, comprobante_xml:, fecha:, emisor:, receptor:)
      body = {
        'clave' => clave,
        'fecha' => fecha,
        'emisor' => emisor,
        'receptor' => receptor,
        'comprobanteXml' => comprobante_xml
      }

      response = post_json(setting('URI_SEND'), body)

      interpret_send(response, clave)
    end

    # Consulta si Hacienda ya resolvió un comprobante que quedó `Sent`.
    #
    # A diferencia de `#send_document`, un HTTP que no sea 2xx (o un timeout, o
    # una respuesta que no es JSON) NO es un rechazo del documento: es que
    # todavía no se pudo confirmar el estado, y el llamador (`CheckSentDocumentsJob`)
    # lo trata igual que "sigue procesando" — el mismo criterio que el legacy,
    # que en ese caso deja `hr.Estado = "procesando"` (`TransaccionesHacienda.cs:480`).
    #
    # @param clave [String] la clave de 50 dígitos del comprobante.
    # @return [CheckResult]
    # @raise [MissingConfiguration, TransientError]
    def check_status(clave)
      response = get_json("#{setting('URI_CHECK').chomp('/')}/#{clave}")

      interpret_check(response)
    end

    private

    attr_reader :company

    # ── Token ─────────────────────────────────────────────────────────────────

    # Un token por instancia del cliente.
    #
    # El job crea un cliente por compañía y por corrida (igual que con el de
    # SAP), así que esto es un `/token` por compañía cada dos minutos y no uno
    # por documento. El legacy además cacheaba el token entre corridas y lo
    # renovaba con el `refresh_token` (`TransaccionesHacienda.cs:210-261`); acá
    # no, porque su propio camino de excepción ya era "pedir uno nuevo" y un
    # POST cada dos minutos no justifica mantener un caché de secretos vivo
    # entre corridas.
    def token
      @token ||= request_token
    end

    # Un 5xx es Hacienda fallando —vale la pena reintentar—; un 4xx (401
    # incluido) es el `POST /token` diciendo que el usuario, la contraseña o el
    # Client ID están mal, y reintentar con la misma credencial mala nunca
    # cambia el resultado (ver `InvalidCredentials`).
    def request_token
      form = {
        'grant_type' => setting('GRANT_TYPE'),
        'client_id' => setting('CLIENT_ID'),
        'username' => credential(:token_user),
        'password' => credential(:token_password)
      }

      response = post_form(token_url, form)
      return extract_access_token(response) if response.is_a?(Net::HTTPSuccess)

      message = "Hacienda no entregó el token de autenticación (#{describe(response)}). " \
                'Revise el usuario y la contraseña del ATV de la compañía y el Client ID configurado.'
      raise TransientError, message if response.is_a?(Net::HTTPServerError)

      raise InvalidCredentials, message
    end

    def extract_access_token(response)
      access_token = JSON.parse(response.body)['access_token'].presence
      return access_token if access_token

      raise TransientError, 'Hacienda entregó un token vacío.'
    rescue JSON::ParserError
      raise TransientError, 'Hacienda entregó una respuesta que no es JSON al pedir el token.'
    end

    # El ajuste guarda la base del endpoint OIDC —con la barra final— y el
    # nombre del recurso lo agrega el cliente, igual que el `$"{_tokeUrl}token"`
    # del legacy (`TransaccionesHacienda.cs:118`). Se tolera que el operador
    # haya pegado la URL completa: sin esto, terminar el ajuste en `token`
    # produce un `…/token/token` y un 404 sin explicación.
    def token_url
      base = setting('URI_TOKEN')
      return base if base.end_with?('/token')

      "#{base.chomp('/')}/token"
    end

    # ── Interpretación de la respuesta del envío ──────────────────────────────

    # Tres desenlaces, y la diferencia entre ellos decide si el documento se
    # puede reintentar:
    #
    #   · 2xx                      → Hacienda lo tomó. La resolución llega después.
    #   · 401/403/5xx/timeout      → no es del documento (`TransientError`).
    #   · el resto                 → es del documento (`RejectedError`), salvo que
    #                                el motivo sea que ya lo había recibido.
    def interpret_send(response, clave)
      return Receipt.new(location: response['Location'], duplicate: false) if
        response.is_a?(Net::HTTPSuccess)

      cause = response[ERROR_CAUSE_HEADER].presence

      # Hacienda no devuelve `Location` en este caso: se arma con la URL de
      # consulta y la clave, que es la misma dirección que habría devuelto el
      # envío original (mismo criterio que `TransaccionesHacienda.cs:387`).
      if cause&.include?(ALREADY_RECEIVED)
        return Receipt.new(location: "#{setting('URI_CHECK').chomp('/')}/#{clave}", duplicate: true)
      end

      raise TransientError, transient_message(response) if transient?(response)

      raise RejectedError,
            "Hacienda rechazó el envío del comprobante: #{cause || describe(response)}"
    end

    # `Unauthorized`/`Forbidden` cuentan como transitorios y no como rechazo del
    # documento: el token pudo vencer entre que se pidió y que se usó, y el
    # legacy también los reintentaba (`Reprocesar`, `TransaccionesHacienda.cs:357`).
    #
    # `HTTPServerError` cubre todo el rango 5xx, incluido el 524 que el legacy
    # trataba aparte (`:359`): `Net::HTTP` clasifica por el primer dígito, así
    # que un código que no conoce igual cae acá.
    def transient?(response)
      response.is_a?(Net::HTTPUnauthorized) ||
        response.is_a?(Net::HTTPForbidden) ||
        response.is_a?(Net::HTTPServerError)
    end

    def transient_message(response)
      cause = response[ERROR_CAUSE_HEADER].presence

      case response
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        'Hacienda rechazó la autenticación al enviar el comprobante ' \
          "(#{describe(response)}). Revise el certificado, el usuario y la contraseña del ATV."
      else
        "Hacienda no pudo recibir el comprobante en este momento (#{describe(response)})." \
          "#{" #{cause}" if cause}"
      end
    end

    # ── Interpretación de la respuesta de la verificación ─────────────────────

    # Cualquier cosa que no sea un 2xx con JSON válido es `TransientError`: ver
    # el comentario de `#check_status` sobre por qué acá NO hay un equivalente
    # a `RejectedError`.
    def interpret_check(response)
      unless response.is_a?(Net::HTTPSuccess)
        cause = response[ERROR_CAUSE_HEADER].presence
        raise TransientError,
              "Hacienda no pudo confirmar el estado del comprobante (#{describe(response)})." \
              "#{" #{cause}" if cause}"
      end

      body = JSON.parse(response.body)
      status = body['ind-estado'].to_s
      xml_base64 = body['respuesta-xml'] if [STATUS_ACCEPTED, STATUS_REJECTED].include?(status)

      CheckResult.new(status: status, xml_base64: xml_base64)
    rescue JSON::ParserError
      raise TransientError, 'Hacienda entregó una respuesta que no es JSON al consultar el estado.'
    end

    # ── HTTP ──────────────────────────────────────────────────────────────────

    def post_form(url, form)
      request(url) do |uri|
        Net::HTTP::Post.new(uri.request_uri).tap do |req|
          req['Content-Type'] = 'application/x-www-form-urlencoded'
          req.body = URI.encode_www_form(form)
        end
      end
    end

    def post_json(url, body)
      request(url) do |uri|
        Net::HTTP::Post.new(uri.request_uri).tap do |req|
          req['Content-Type'] = 'application/json'
          req['Authorization'] = "Bearer #{token}"
          req.body = body.to_json
        end
      end
    end

    def get_json(url)
      request(url) do |uri|
        Net::HTTP::Get.new(uri.request_uri).tap do |req|
          req['Authorization'] = "Bearer #{token}"
        end
      end
    end

    # Todo lo que puede fallar antes de tener una respuesta —DNS, TLS, timeout—
    # sale como `TransientError`: no dice nada del documento.
    def request(url)
      uri = parse(url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      http.request(yield(uri))
    rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError => e
      raise TransientError, "No se pudo contactar a Hacienda en #{uri&.host || url}: #{e.message}"
    end

    def parse(url)
      uri = URI.parse(url)
      return uri if uri.is_a?(URI::HTTP) && uri.host.present?

      raise MissingConfiguration, "La URL de Hacienda #{url.inspect} no es una dirección http(s) válida."
    rescue URI::InvalidURIError
      raise MissingConfiguration, "La URL de Hacienda #{url.inspect} no se puede interpretar."
    end

    # El código y la razón, que es lo único que sirve para diagnosticar. El
    # cuerpo NO va: en un error de Hacienda es una página de error entera.
    def describe(response)
      "HTTP #{response.code} #{response.message}".strip
    end

    # ── Configuración ─────────────────────────────────────────────────────────

    # `Setting.group` solo devuelve las claves CON valor, así que el `fetch`
    # falla exactamente en la que falta y el mensaje la puede nombrar.
    def settings
      @settings ||= Setting.group('HACIENDA_FE')
    end

    def setting(key)
      settings.fetch(key)
    rescue KeyError
      raise MissingConfiguration,
            "Falta el ajuste HACIENDA_FE_#{key} en Configuraciones → Generales, " \
            'necesario para emitir ante Hacienda.'
    end

    # Nombra la compañía: este mensaje lo va a leer alguien averiguando por qué
    # una compañía no emitió, y "falta la contraseña" sin decir de cuál no le
    # sirve de nada.
    def credential(attribute)
      value = company.public_send(attribute).presence
      return value if value

      raise MissingConfiguration,
            "La compañía #{company.name.inspect} (id #{company.id}) no tiene " \
            "#{CREDENTIAL_LABELS.fetch(attribute)} del ATV de Hacienda."
    end
  end
end

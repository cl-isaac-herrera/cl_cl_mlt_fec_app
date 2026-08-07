# frozen_string_literal: true

# ProxyController — reenvía todas las llamadas /api/* al backend externo.
#
# AUTENTICACIÓN (CLAVISCO-PLATFORM-STANDARDS §2.3):
# - El token vive en la session cookie httpOnly, NO en el browser.
# - El proxy adjunta `Authorization: Bearer` desde la sesión y DESCARTA cualquier
#   Authorization que mande el cliente: el browser no puede elegir con qué token
#   se habla con el backend.
# - La UI sigue incluyendo cl-company-id header.
#
# ENRUTAMIENTO POR HEADER 'API':
#   El Stimulus controller incluye el header 'API' en cada request para indicar
#   a cuál backend debe enrutar el proxy. Replica el comportamiento del
#   UrlInterceptor del Angular legacy.
#
#   API: ApiAppUrl  → api_fe_app_url  (usuarios, empresas, permisos, catálogos)
#   API: ApiFEUrl   → api_fe_sync_url (emisión, documentos, Hacienda)
#   (sin header)    → api_fe_app_url  (default)
#
# Nota de path para /api/token:
#   UI llama: /api/token → API espera: /token  (nivel raíz, sin /api)
#   UI llama: /api/Menu  → API espera: /api/Menu (mantiene prefijo /api)
class ProxyController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :allow_browser, raise: false

  # Exige sesión como cualquier otro controller (require_session de
  # ApplicationController): sin cookie válida la solicitud no sale hacia el backend.

  def forward
    # El endpoint de token en el sync server vive en /token (sin prefijo /api).
    # El browser llama /api/token → strippeamos /api para que llegue como /token.
    # Solo aplica cuando el request va al sync server (API: ApiFEUrl).
    path = if request.headers['HTTP_API'] == 'ApiCabysURL'
             # CABYS (Hacienda) espera la query en la raiz: /fe/cabys/?codigo=... o ?q=...
             # El base url ya termina en /fe/cabys/, asi que solo dejamos la query.
             request.fullpath.sub(%r{\A/api/Cabys}, '')
           elsif request.headers['HTTP_API'] == 'ApiFEUrl' && request.fullpath.start_with?('/api/token')
             request.fullpath.sub('/api/token', '/token')
           else
             request.fullpath
           end

    target_url = "#{api_base_url}#{path}"

    Rails.logger.info  "[Proxy] #{request.method} #{target_url}"
    Rails.logger.info  "[Proxy] Content-Type: #{request.content_type}"

    uri        = URI.parse(target_url)
    http       = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == 'https')
    http.read_timeout = 30
    http.open_timeout = 10

    # En desarrollo se deshabilita verificación SSL (issues de CRL / certificados locales)
    http.verify_mode = if Rails.env.development? || ENV['SKIP_SSL_VERIFICATION'] == 'true'
      OpenSSL::SSL::VERIFY_NONE
    else
      OpenSSL::SSL::VERIFY_PEER
    end

    body = request.raw_post.presence
    Rails.logger.info "[Proxy] Body (#{body&.bytesize || 0} bytes): #{body.inspect}"

    http_request      = build_http_request(request.method, uri, forwarded_headers)
    http_request.body = body
    response          = http.request(http_request)

    Rails.logger.info "[Proxy] Response: #{response.code}"
    Rails.logger.error "[Proxy] Error body: #{response.body.to_s[0..500]}" if response.code.to_i >= 400

    # Reenviar headers de paginación al cliente
    response.each_header do |key, value|
      if key.downcase.start_with?('cl-sl-pagination', 'cl-dba-pagination') ||
         key.downcase == 'cl-message' ||
         key.downcase == 'content-disposition'
        self.response.headers[key] = value
      end
    end

    render body: response.body,
           status: response.code.to_i,
           content_type: response['Content-Type'] || 'application/json'

  rescue Net::ReadTimeout, Net::OpenTimeout => e
    Rails.logger.error "[Proxy] Timeout: #{e.message}"
    render json: { error: 'API request timed out' }, status: :gateway_timeout
  rescue StandardError => e
    Rails.logger.error "[Proxy] #{e.class}: #{e.message}"
    render json: { error: "API request failed: #{e.message}" }, status: :bad_gateway
  end

  private

  # Selecciona el backend destino según el header 'API' enviado por el Stimulus controller.
  # Replica exactamente el mapa de apiUrls del UrlInterceptor Angular legacy:
  #
  #   'ApiAppUrl'   → api_fe_app_url  (default cuando no viene header)
  #   'ApiFEUrl'    → api_fe_sync_url
  #   (sin header)  → api_fe_app_url  (mismo default que Angular)
  API_URL_MAP = {
    'ApiAppUrl'   => :api_fe_app_url,
    'ApiFEUrl'    => :api_fe_sync_url,
    'ApiCabysURL' => :api_cabys_url,
  }.freeze

  def api_base_url
    api_header = request.headers['HTTP_API']
    # CABYS: resolver via ENV directamente (no depende del initializer, evita reinicio del server)
    return ENV.fetch('API_CABYS_URL', 'https://api.hacienda.go.cr/fe/cabys/') if api_header == 'ApiCabysURL'

    config_key = API_URL_MAP.fetch(api_header, :api_fe_app_url)
    Rails.application.config.public_send(config_key)
  end

  def build_http_request(method, uri, headers)
    klass = case method.upcase
            when 'GET'     then Net::HTTP::Get
            when 'POST'    then Net::HTTP::Post
            when 'PUT'     then Net::HTTP::Put
            when 'PATCH'   then Net::HTTP::Patch
            when 'DELETE'  then Net::HTTP::Delete
            when 'OPTIONS' then Net::HTTP::Options
            when 'HEAD'    then Net::HTTP::Head
            else Net::HTTP::Get
            end

    req = klass.new(uri.request_uri)
    headers.each { |key, value| req[key] = value }
    req['Host'] = uri.host  # Host correcto del API destino, no localhost:3000
    req
  end

  def forwarded_headers
    headers = {}

    request.headers.each do |key, value|
      if key.start_with?('HTTP_')
        header_name = key.sub(/^HTTP_/, '').split('_').map(&:capitalize).join('-')
        # Mantener headers cl-* en minúsculas (el backend .NET puede ser case-sensitive)
        header_name = header_name.downcase if header_name.start_with?('Cl-')
        headers[header_name] = value
      elsif %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
        headers[key.split('_').map(&:capitalize).join('-')] = value
      end
    end

    # Sin Accept-Encoding → respuestas sin comprimir (evita problemas con gzip/brotli)
    headers.delete('Accept-Encoding')

    # Headers que no deben llegar al backend (igual que Angular legacy: withCredentials: false)
    %w[Cookie Referer Origin Sec-Fetch-Site Sec-Fetch-Mode Sec-Fetch-Dest
       Sec-Ch-Ua Sec-Ch-Ua-Mobile Sec-Ch-Ua-Platform Connection Pragma Cache-Control Host].each do |h|
      headers.delete(h)
    end

    # El Authorization del cliente se descarta SIEMPRE y se reemplaza por el token de
    # la sesión: el browser no elige la credencial con la que se habla al backend.
    # Sin token en sesión no se manda el header (endpoints públicos, ej. OTP).
    headers.delete('Authorization')
    token = session[:access_token]
    headers['Authorization'] = "Bearer #{token}" if token.present?

    Rails.logger.info "[Proxy] Headers: #{headers.except('Authorization').inspect}"
    headers
  end
end

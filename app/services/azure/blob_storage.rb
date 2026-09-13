# frozen_string_literal: true

module Azure
  # Sube un archivo a un contenedor de Azure Blob Storage, autenticado con
  # Shared Key (cuenta + clave), tal como lo hacía el legacy
  # (`CLVS_FE.Common/Utils.cs#BuildAzureBlobClient`, `StorageSharedKeyCredential`).
  #
  #   Azure::BlobStorage.new.upload(
  #     container: 'clvsfe', path: '3101822733/5061...xml',
  #     content: xml_bytes, content_type: 'application/xml'
  #   )
  #   # => "https://miempresa.blob.core.windows.net/clvsfe/3101822733/5061...xml"
  #
  # No usa el SDK oficial de Azure (`azure-storage-blob`): es una gema sin
  # mantenimiento activo. Es una sola operación REST (`Put Blob`) bien
  # documentada, con el mismo criterio que `Hacienda::Client` — `Net::HTTP`
  # puro, sin gemas nuevas para un solo endpoint.
  #
  # ── El algoritmo de firma NO es negociable ──────────────────────────────────
  # "Shared Key for Blob, Queue, and File Services" (no "Shared Key Lite",  que
  # es el formato viejo con otro `StringToSign`). Está verificado contra la
  # documentación oficial de Microsoft (Authorize with Shared Key), línea por
  # línea, no reconstruido de memoria: un canonicalizado distinto en un solo
  # carácter invalida la firma y Azure responde 403 sin decir qué falló.
  class BlobStorage
    class Error < StandardError; end

    # Falta la cuenta o la clave en `settings` (grupo `AZURE_STORAGE`).
    class MissingConfiguration < Error; end

    # La subida falló por algo que no es del archivo: red, timeout, un 5xx de
    # Azure, o una firma rechazada (403) — que casi siempre es reloj
    # desincronizado (Azure exige que la fecha esté a menos de 15 min) y no un
    # error del llamador.
    class TransientError < Error; end

    # Azure rechazó la subida por algo que un reintento igual a sí mismo NUNCA
    # arregla — el contenedor no existe, el nombre de la cuenta está mal, la
    # ruta es inválida. Reintentar esto para siempre (`TransientError`) deja el
    # documento en `Processing` sin que nadie se entere de por qué nunca avanza
    # (ver `SyncIssuedDocumentsJob#transient` vs. `#failed`).
    class RejectedError < Error; end

    API_VERSION = '2021-08-06'
    BLOB_TYPE = 'BlockBlob'

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    def initialize
      @account = setting('ACCOUNT_NAME')
      @key = setting('ACCOUNT_KEY')
    end

    # @param container [String] nombre del contenedor (ya debe existir).
    # @param path [String] ruta dentro del contenedor, sin barra inicial
    #   (`{cédula}/{clave}.xml`).
    # @param content [String] los bytes a subir, ya codificados (no Base64).
    # @param content_type [String]
    # @return [String] la URL del blob (sin SAS — es el mismo formato que el
    #   legacy guardaba: `blobClient.Uri.AbsoluteUri`, de solo lectura para
    #   quien no tenga la clave de la cuenta).
    # @raise [TransientError, RejectedError]
    def upload(container:, path:, content:, content_type:)
      uri = blob_uri(container, path)
      date = Time.now.utc.httpdate

      ms_headers = { 'x-ms-blob-type' => BLOB_TYPE, 'x-ms-date' => date, 'x-ms-version' => API_VERSION }

      request = Net::HTTP::Put.new(uri.request_uri)
      ms_headers.each { |name, value| request[name] = value }
      request['Content-Type'] = content_type
      request['Authorization'] = authorization('PUT', uri, ms_headers, content.bytesize, content_type)
      request.body = content

      response = perform(uri, request)

      return uri.to_s if response.is_a?(Net::HTTPSuccess)

      message = "Azure Storage rechazó la subida (#{describe(response)})."
      raise TransientError, message if transient?(response)

      raise RejectedError, message
    end

    # @param container [String] nombre del contenedor.
    # @param path [String] ruta dentro del contenedor, sin barra inicial.
    # @return [String] los bytes del blob.
    # @raise [TransientError, RejectedError]
    def download(container:, path:)
      uri = blob_uri(container, path)
      date = Time.now.utc.httpdate

      # Sin `x-ms-blob-type`: ese header es propio de `Put Blob`, no de `Get
      # Blob`. Incluirlo igual en el `StringToSign` (como si `#upload`
      # reutilizara `canonicalized_headers` a ciegas) firmaría un header que
      # esta petición nunca manda, y Azure respondería 403 sin decir por qué.
      ms_headers = { 'x-ms-date' => date, 'x-ms-version' => API_VERSION }

      request = Net::HTTP::Get.new(uri.request_uri)
      ms_headers.each { |name, value| request[name] = value }
      # Un GET no lleva body: `Content-Length`/`Content-Type` van vacíos —
      # misma rama del `StringToSign` que ya cubre `#upload` cuando
      # `content_length` es cero.
      request['Authorization'] = authorization('GET', uri, ms_headers, 0, '')

      response = perform(uri, request)

      return response.body if response.is_a?(Net::HTTPSuccess)

      message = "Azure Storage rechazó la descarga (#{describe(response)})."
      raise TransientError, message if transient?(response)

      raise RejectedError, message
    end

    # Borra un blob. La usa `Hacienda::SchemaUpload` para sacar del contenedor
    # el XSD que acaba de quedar reemplazado — el que ningún ajuste apunta ya.
    #
    # **Un blob que no existe NO es un error**: `Delete Blob` responde 404 y acá
    # eso se trata como éxito. Quien llama a este método lo hace para limpiar
    # algo que sobra, así que "ya no está" es exactamente el resultado buscado,
    # y levantar obligaría a cada llamador a distinguir un caso que le da igual.
    #
    # @param container [String]
    # @param path [String] ruta dentro del contenedor, sin barra inicial.
    # @return [void]
    # @raise [TransientError, RejectedError]
    def delete(container:, path:)
      uri = blob_uri(container, path)
      date = Time.now.utc.httpdate

      # Sin `x-ms-blob-type`, por lo mismo que `#download`: ese header es propio
      # de `Put Blob`. Firmar uno que la petición no manda es un 403 sin motivo
      # visible.
      ms_headers = { 'x-ms-date' => date, 'x-ms-version' => API_VERSION }

      request = Net::HTTP::Delete.new(uri.request_uri)
      ms_headers.each { |name, value| request[name] = value }
      request['Authorization'] = authorization('DELETE', uri, ms_headers, 0, '')

      response = perform(uri, request)

      return if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNotFound)

      message = "Azure Storage rechazó el borrado (#{describe(response)})."
      raise TransientError, message if transient?(response)

      raise RejectedError, message
    end

    private

    attr_reader :account, :key

    # 5xx es Azure fallando; 403 es casi siempre reloj desincronizado (ver
    # `TransientError`) y no un problema del contenedor o la ruta. El resto
    # (404 "el contenedor no existe", 400, …) es una subida que este mismo
    # request nunca va a lograr, sin importar cuántas veces se reintente.
    def transient?(response)
      response.is_a?(Net::HTTPServerError) || response.is_a?(Net::HTTPForbidden)
    end

    def blob_uri(container, path)
      encoded_path = path.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')
      URI("https://#{account}.blob.core.windows.net/#{container}/#{encoded_path}")
    end

    def perform(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      http.request(request)
    rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError => e
      raise TransientError, "No se pudo contactar Azure Storage (#{uri.host}): #{e.message}"
    end

    def describe(response)
      "HTTP #{response.code} #{response.message}".strip
    end

    # ── Firma Shared Key ─────────────────────────────────────────────────────
    # Ver "Authorize with Shared Key" de Microsoft. El `StringToSign` de Blob
    # Storage 2009-09-19+ es una secuencia FIJA de doce líneas de headers
    # estándar (vacías si no aplican) más los headers `x-ms-*` canonicalizados
    # y el recurso canonicalizado — en ESE orden exacto.
    def authorization(verb, uri, ms_headers, content_length, content_type)
      standard_headers = [
        verb,
        '', # Content-Encoding
        '', # Content-Language
        content_length.zero? ? '' : content_length.to_s, # Content-Length: vacío si 0
        '', # Content-MD5
        content_type, # Content-Type
        '', # Date: vacío porque la fecha va en x-ms-date
        '', # If-Modified-Since
        '', # If-Match
        '', # If-None-Match
        '', # If-Unmodified-Since
        '' # Range
      ].join("\n")
      string_to_sign = "#{standard_headers}\n#{canonicalized_headers(ms_headers)}#{canonicalized_resource(uri)}"

      signature = Base64.strict_encode64(
        OpenSSL::HMAC.digest('SHA256', Base64.strict_decode64(key), string_to_sign)
      )

      "SharedKey #{account}:#{signature}"
    end

    # Los headers `x-ms-*` de ESTA petición, en minúscula, ordenados
    # lexicográficamente por nombre (`x-ms-blob-type` < `x-ms-date` <
    # `x-ms-version`) — SOLO los que la petición manda de verdad: firmar un
    # header que no se envía (o al revés) invalida la firma y Azure responde
    # 403 sin decir qué falló.
    def canonicalized_headers(ms_headers)
      ms_headers.sort.map { |name, value| "#{name}:#{value}\n" }.join
    end

    # Formato 2009-09-19+: `/{cuenta}/{path sin query}`. Esta subida nunca lleva
    # query string (sin SAS, sin snapshot), así que no hace falta la parte de
    # parámetros ordenados que exige el resto del algoritmo.
    def canonicalized_resource(uri)
      "/#{account}#{uri.path}"
    end

    def setting(key)
      Setting.group('AZURE_STORAGE').fetch(key)
    rescue KeyError
      raise MissingConfiguration,
            "Falta el ajuste AZURE_STORAGE_#{key} en Configuraciones → Generales, " \
            'necesario para guardar los XML de Hacienda.'
    end
  end
end

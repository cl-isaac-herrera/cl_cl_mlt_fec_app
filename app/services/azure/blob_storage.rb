# frozen_string_literal: true

module Azure
  # Sube/descarga/borra archivos en Azure Blob Storage, resolviendo la cuenta y
  # la clave desde `settings` (`Setting.group('AZURE_STORAGE')`, ver
  # `CLAUDE.md` §36) y traduciendo al español los errores.
  #
  #   Azure::BlobStorage.new.upload(
  #     container: 'clvsfe', path: '3101822733/5061...xml',
  #     content: xml_bytes, content_type: 'application/xml'
  #   )
  #   # => "https://miempresa.blob.core.windows.net/clvsfe/3101822733/5061...xml"
  #
  # El algoritmo Shared Key y el `Net::HTTP` puro ya NO viven acá: los provee
  # `Clavisco::Common::Storage::AzureBlobStorage` (submódulo `common`), porque
  # es la misma necesidad de cualquier producto Clavisco que guarde archivos en
  # Azure — no algo propio de FEC. Esta clase es el adaptador de ese cliente
  # genérico a las convenciones de este producto:
  #
  #   - de dónde salen `account`/`key` (la tabla `settings`, no ENV ni
  #     parámetros — ver `.container`/`.workspace`/`#setting` más abajo);
  #   - los mensajes de error en español (`CLAUDE.md` §10): el cliente común es
  #     agnóstico de producto y sus mensajes son en inglés, así que acá se
  #     reconstruyen a partir del `response` HTTP que el error expone
  #     (`Clavisco::Common::Storage::AzureBlobStorage::TransientError#response`
  #     / `RejectedError#response`), no parseando el texto en inglés.
  class BlobStorage
    class Error < StandardError; end

    # Falta la cuenta o la clave en `settings` (grupo `AZURE_STORAGE`).
    class MissingConfiguration < Error; end

    # El ajuste ESTÁ, pero su valor no sirve como segmento de ruta (ver
    # `VALID_SEGMENT`). Hereda de `MissingConfiguration` a propósito: es el mismo
    # desenlace —un problema de configuración que ningún reintento arregla— y así
    # todos los `rescue` que ya existen lo atrapan sin tener que sumarlo uno por
    # uno (`SyncIssuedDocumentsJob#failed`, `CheckSentDocumentsJob#archive_response`).
    class InvalidConfiguration < MissingConfiguration; end

    # Lo que puede ser un segmento de la ruta de un blob cuando el valor no lo
    # elige el código: un ajuste que escribe el operador
    # (`AZURE_STORAGE_WORKSPACE`) o una columna de la base (`companies.uuid`).
    #
    # Sin esto, un `../` o una barra de más no es un error: es una escritura en
    # OTRA carpeta —la de otro producto o la de otra compañía— y nadie se entera
    # hasta que alguien busca el archivo donde tendría que estar. Mismo criterio
    # que `CompanyFiles::Store::VALID_ID_NUMBER` para las rutas del disco (§34).
    VALID_SEGMENT = /\A[A-Za-z0-9._-]+\z/

    # La subida/descarga/borrado falló por algo que no es del archivo: red,
    # timeout, un 5xx de Azure, o una firma rechazada (403) — que casi siempre
    # es reloj desincronizado (Azure exige que la fecha esté a menos de 15 min)
    # y no un error del llamador.
    class TransientError < Error; end

    # Azure rechazó la operación por algo que un reintento igual a sí mismo
    # NUNCA arregla — el contenedor no existe, el nombre de la cuenta está mal,
    # la ruta es inválida. Reintentar esto para siempre (`TransientError`) deja
    # el documento en `Processing` sin que nadie se entere de por qué nunca
    # avanza (ver `SyncIssuedDocumentsJob#transient` vs. `#failed`).
    class RejectedError < Error; end

    # Los dos ajustes que forman la ruta de CUALQUIER blob de este producto, no
    # solo de uno de los dos almacenes. Viven acá y no duplicados en
    # `Documents::XmlArchive` y `Hacienda::SchemaStore` porque son el mismo dato
    # leído con el mismo criterio: dos copias se separan en cuanto una agregue
    # una validación que la otra no tenga.
    #
    # `purpose` es la única parte que cambia entre llamadores, y es la que hace
    # que el mensaje sirva: quien lo lee necesita saber qué dejó de funcionar,
    # no solo qué ajuste falta.
    class << self
      # El contenedor de la cuenta. No es un segmento de ruta (va en la
      # autoridad de la URL, no en el path), así que no pasa por `VALID_SEGMENT`
      # — Azure rechaza un nombre inválido con un 400 que ya se traduce a
      # `RejectedError`.
      def container(purpose:) = setting('CONTAINER', purpose: purpose)

      # La carpeta de PRIMER nivel del producto dentro del contenedor ("fec").
      # Existe porque la cuenta es compartida entre productos de Clavisco: sin
      # ella, `xsd/` y `{uuid}/` colgarían de la raíz y se mezclarían con los de
      # otro producto.
      def workspace(purpose:)
        value = setting('WORKSPACE', purpose: purpose)

        unless value.match?(VALID_SEGMENT)
          raise InvalidConfiguration,
                "El ajuste AZURE_STORAGE_WORKSPACE (#{value.inspect}) no es una carpeta válida: " \
                'solo letras, números, punto, guion y guion bajo.'
        end

        value
      end

      # @raise [MissingConfiguration] el ajuste no existe o está vacío.
      def setting(key, purpose:)
        Setting.group('AZURE_STORAGE').fetch(key)
      rescue KeyError
        raise MissingConfiguration,
              "Falta el ajuste AZURE_STORAGE_#{key} en Configuraciones → Generales, " \
              "necesario para #{purpose}."
      end
    end

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
      client.upload(container: container, path: path, content: content, content_type: content_type)
    rescue Clavisco::Common::Storage::AzureBlobStorage::TransientError => e
      raise TransientError, translate(e, verb: 'la subida')
    rescue Clavisco::Common::Storage::AzureBlobStorage::RejectedError => e
      raise RejectedError, translate(e, verb: 'la subida')
    end

    # @param container [String] nombre del contenedor.
    # @param path [String] ruta dentro del contenedor, sin barra inicial.
    # @return [String] los bytes del blob.
    # @raise [TransientError, RejectedError]
    def download(container:, path:)
      client.download(container: container, path: path)
    rescue Clavisco::Common::Storage::AzureBlobStorage::TransientError => e
      raise TransientError, translate(e, verb: 'la descarga')
    rescue Clavisco::Common::Storage::AzureBlobStorage::RejectedError => e
      raise RejectedError, translate(e, verb: 'la descarga')
    end

    # Borra un blob. La usa `Hacienda::SchemaUpload` para sacar del contenedor
    # el XSD que acaba de quedar reemplazado — el que ningún ajuste apunta ya.
    #
    # **Un blob que no existe NO es un error**: el cliente común ya trata un 404
    # de `Delete Blob` como éxito (ver `Clavisco::Common::Storage
    # ::AzureBlobStorage#delete`) — quien llama a este método lo hace para
    # limpiar algo que sobra, así que "ya no está" es exactamente el resultado
    # buscado.
    #
    # @param container [String]
    # @param path [String] ruta dentro del contenedor, sin barra inicial.
    # @return [void]
    # @raise [TransientError, RejectedError]
    def delete(container:, path:)
      client.delete(container: container, path: path)
    rescue Clavisco::Common::Storage::AzureBlobStorage::TransientError => e
      raise TransientError, translate(e, verb: 'el borrado')
    rescue Clavisco::Common::Storage::AzureBlobStorage::RejectedError => e
      raise RejectedError, translate(e, verb: 'el borrado')
    end

    private

    attr_reader :account, :key

    def client
      @client ||= Clavisco::Common::Storage::AzureBlobStorage.new(account: account, key: key)
    end

    # Reconstruye el mensaje en español a partir del `response` HTTP que trae
    # el error del cliente común, no de su `#message` (en inglés) — así el
    # texto no depende de que la librería compartida no cambie su redacción.
    #
    # `response` es `nil` cuando la falla fue de conectividad (timeout, DNS…):
    # ahí no hay HTTP que describir, así que se usa `#cause` — la excepción de
    # bajo nivel (`Timeout::Error`, `SocketError`…) que Ruby encadena
    # automáticamente cuando el cliente común hace `raise TransientError, "…"`
    # dentro de su propio `rescue` — en vez de repetir la frase en inglés que
    # ese cliente arma para SU `#message`.
    def translate(error, verb:)
      return "No se pudo contactar Azure Storage: #{error.cause&.message || error.message}" unless error.response

      "Azure Storage rechazó #{verb} (HTTP #{error.response.code} #{error.response.message})."
    end

    def setting(key)
      self.class.setting(key, purpose: 'guardar los archivos de Hacienda')
    end
  end
end

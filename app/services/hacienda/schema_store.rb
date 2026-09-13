# frozen_string_literal: true

module Hacienda
  # Entrega el esquema XSD de Hacienda de un tipo de comprobante, ya compilado y
  # listo para validar, sin que el archivo exista en el disco del servidor.
  #
  #   schema = Hacienda::SchemaStore.for_doc_type(DocType::FE)
  #   errors = schema.validate(Nokogiri::XML(xml))
  #
  # Es la contraparte de los nueve `appSettings` del .NET
  # (`CLVS_FE.API/Web.config`: `FEXSDPath`, `NCXSDPath`, … `ACCEPTXSDMailParser`),
  # que apuntaban a rutas absolutas del disco de aquel servidor
  # (`C:\inetpub\wwwroot\…\Files\XSD\FacturaElectronica_V4.4.xsd`) y que
  # `Validations.cs` pasaba tal cual a `settings.Schemas.Add(null, SchemaPath)`.
  #
  # ── Por qué NO van al disco, a diferencia de los archivos de compañía ───────
  # `CLAUDE.md` §34 manda el certificado, el logo y el `.rpt` al disco porque
  # **otro proceso los abre por su ruta**: el servicio de firma, el generador del
  # PDF, el de correo. Con el XSD no pasa eso — el único consumidor es esta
  # aplicación, y lo que necesita no es un archivo sino un esquema compilado en
  # memoria. Guardarlo en disco obligaría a que cada servidor de la instalación
  # tuviera su propia copia sincronizada a mano; en Azure hay una sola, la misma
  # que ya usa `Documents::XmlArchive`.
  #
  # ── El ajuste guarda la RUTA DEL BLOB, no una URL ──────────────────────────
  # `settings.value` queda con `xsd/{CODE}/{digest}/{nombre original}.xsd`. Tres
  # cosas salen de esa forma:
  #
  #   · el **digest** del contenido hace que subir un archivo distinto cambie la
  #     ruta, y con ella la llave del caché: un proceso que tenía compilado el
  #     esquema viejo lo descarta solo, sin reiniciar nada ni avisarle a nadie;
  #   · el **nombre original** sobrevive, así que la pantalla puede mostrar
  #     "FacturaElectronica_V4.4.xsd" y no un hash;
  #   · no se guarda la URL completa justamente para no repetir acá el
  #     conocimiento de cómo se arma —y cómo se vuelve a partir— una URL de
  #     blob, que hoy vive en un solo lugar (`Documents::XmlArchive`).
  #
  # ── El caché es POR PROCESO y se invalida solo ─────────────────────────────
  # Un `Nokogiri::XML::Schema` no se puede serializar, así que `Rails.cache` no
  # es una opción: el caché es un Hash de clase protegido por un Mutex. Cada
  # llamada lee el ajuste (un SELECT sobre un índice único) y compara la ruta
  # con la que tiene compilada; solo baja de Azure y recompila cuando cambió.
  # Ese SELECT por llamada es el precio de que un `sidekiq` que lleva días
  # arriba se entere de que alguien subió un XSD nuevo desde la pantalla.
  #
  # ── ⚠️ El XSD tiene que ser AUTOCONTENIDO ──────────────────────────────────
  # Un esquema construido desde un String no tiene ruta base, así que `libxml2`
  # **no resuelve ningún `xs:import` ni `xs:include`** — ni relativo ni remoto
  # (Nokogiri compila con `NONET`, y de todas formas salir a la red a buscar un
  # esquema en medio de una emisión no es aceptable). Los XSD publicados por
  # Hacienda traen un `<xs:import>` de `xmldsig-core-schema.xsd` para la firma;
  # el legacy lo dejó **comentado** en sus copias, y es lo que hay que hacer con
  # el archivo que se sube (o inlinear el esquema importado).
  #
  # Por eso `SchemaUpload` compila el archivo ANTES de guardarlo: un XSD con un
  # import sin resolver se rechaza en la pantalla, con el mensaje de libxml2, en
  # vez de fallar en medio de una emisión.
  class SchemaStore
    class Error < StandardError; end

    # No hay archivo cargado para ese tipo de comprobante.
    class NotConfigured < Error; end

    # El archivo está cargado pero no se pudo compilar como esquema.
    class InvalidSchema < Error; end

    GROUP_CODE = 'HACIENDA_XSD'
    CODE_PREFIX = "#{GROUP_CODE}_".freeze

    EXTENSION = '.xsd'
    CONTENT_TYPE = 'application/xml'

    # Tope de tamaño. No es una regla de negocio: existe para que el campo no
    # sea una vía para llenar el contenedor. El más grande de los nueve del
    # legacy (`FacturaElectronica_V4.4.xsd`) no llega a 200 KB.
    MAX_BYTES = 2.megabytes

    # Prefijo de los blobs dentro del contenedor de `AZURE_STORAGE_CONTAINER`.
    # Los XML de comprobante cuelgan de `{cédula}/`, así que no se pisan.
    BLOB_PREFIX = 'xsd'

    # El catálogo completo, en el orden en que lo pinta la pantalla.
    #
    # `doc_type` es `nil` en los dos últimos a propósito: los mensajes de
    # receptor (`05`, `06`, `07`) NO tienen un esquema cada uno. El legacy los
    # valida a los tres con el mismo archivo (`ACCEPTXSD`) y elige la variante
    # por el ORIGEN del mensaje, no por su código: `ACCEPTXSDMailParser` cuando
    # el mensaje se extrajo de un correo (`Validations.cs` L248-256, el
    # parámetro `fromMailParser`). Por eso son dos ajustes y no tres.
    #
    # `legacy_key` es la llave del `appSettings` del .NET que reemplaza cada
    # uno. No es decorativa: es lo que le dice a quien migra una instalación qué
    # archivo del servidor viejo va en cada campo de la pantalla.
    SCHEMAS = [
      { code: "#{CODE_PREFIX}01", doc_type: DocType::FE,
        label: 'Factura electrónica', legacy_key: 'FEXSDPath' },
      { code: "#{CODE_PREFIX}02", doc_type: DocType::ND,
        label: 'Nota de débito electrónica', legacy_key: 'NDXSDPath' },
      { code: "#{CODE_PREFIX}03", doc_type: DocType::NC,
        label: 'Nota de crédito electrónica', legacy_key: 'NCXSDPath' },
      { code: "#{CODE_PREFIX}04", doc_type: DocType::TE,
        label: 'Tiquete electrónico', legacy_key: 'TEXSDPath' },
      { code: "#{CODE_PREFIX}08", doc_type: DocType::FEC,
        label: 'Factura electrónica de compra', legacy_key: 'FECXSDPath' },
      { code: "#{CODE_PREFIX}09", doc_type: DocType::FEE,
        label: 'Factura electrónica de exportación', legacy_key: 'FEEXSDPath' },
      { code: "#{CODE_PREFIX}10", doc_type: DocType::REP,
        label: 'Recibo electrónico de pago', legacy_key: 'REPXSDPath' },
      { code: "#{CODE_PREFIX}MENSAJE_RECEPTOR", doc_type: nil,
        label: 'Mensaje de receptor', legacy_key: 'ACCEPTXSD' },
      { code: "#{CODE_PREFIX}MENSAJE_RECEPTOR_MAIL_PARSER", doc_type: nil,
        label: 'Mensaje de receptor obtenido del correo', legacy_key: 'ACCEPTXSDMailParser' }
    ].freeze

    CODES = SCHEMAS.pluck(:code).freeze

    RECEIVER_MESSAGE_CODE = "#{CODE_PREFIX}MENSAJE_RECEPTOR".freeze
    RECEIVER_MESSAGE_MAIL_PARSER_CODE = "#{CODE_PREFIX}MENSAJE_RECEPTOR_MAIL_PARSER".freeze

    DOC_TYPE_CODES = SCHEMAS.filter_map { |s| [s[:doc_type], s[:code]] if s[:doc_type] }.to_h.freeze

    LABELS = SCHEMAS.to_h { |s| [s[:code], s[:label]] }.freeze

    # `code => [ruta del blob, esquema compilado]`. Llave por proceso; ver el
    # encabezado.
    @cache = {}
    @mutex = Mutex.new

    class << self
      # ¿Es uno de los nueve `code` del catálogo? Lo usa el controller antes de
      # tocar nada: así un `code` de otro grupo —o inventado— no puede llegar a
      # escribir un ajuste con una ruta de blob.
      def code?(code) = CODES.include?(code)

      def label(code) = LABELS[code]

      # El esquema de un tipo de comprobante.
      #
      # @param doc_type [String] código de Hacienda (`DocType::FE`, …). Los tres
      #   mensajes de receptor (`05`/`06`/`07`) resuelven al mismo esquema.
      # @param from_mail_parser [Boolean] solo para los mensajes de receptor:
      #   `true` elige la variante del mensaje extraído de un correo, igual que
      #   el parámetro `fromMailParser` del legacy.
      # @return [Nokogiri::XML::Schema]
      # @raise [NotConfigured, InvalidSchema, Azure::BlobStorage::Error]
      def for_doc_type(doc_type, from_mail_parser: false)
        fetch(code_for(doc_type, from_mail_parser: from_mail_parser))
      end

      # @param doc_type [String]
      # @return [String] el `code` del ajuste que guarda ese esquema.
      # @raise [NotConfigured] el tipo no tiene esquema en el catálogo.
      def code_for(doc_type, from_mail_parser: false)
        normalized = DocType.normalize(doc_type)

        if DocType.receiver_message?(normalized)
          return from_mail_parser ? RECEIVER_MESSAGE_MAIL_PARSER_CODE : RECEIVER_MESSAGE_CODE
        end

        DOC_TYPE_CODES.fetch(normalized) do
          raise NotConfigured,
                "No hay un esquema XSD asociado al tipo de comprobante #{doc_type.inspect}."
        end
      end

      # El esquema guardado bajo ese `code`, compilado y cacheado.
      #
      # @param code [String]
      # @return [Nokogiri::XML::Schema]
      # @raise [NotConfigured, InvalidSchema, Azure::BlobStorage::Error]
      def fetch(code)
        path = Setting.value_for(code)

        if path.blank?
          raise NotConfigured,
                "No se encuentra el archivo XSD configurado para #{label(code) || code}. " \
                'Cárguelo en Configuraciones → Generales → Esquemas XSD de Hacienda.'
        end

        cached = @mutex.synchronize { @cache[code] }
        return cached.last if cached && cached.first == path

        schema = compile(Azure::BlobStorage.new.download(container: container, path: path), code: code)
        @mutex.synchronize { @cache[code] = [path, schema] }

        schema
      end

      # Compila un XSD desde sus bytes, sin tocar el disco.
      #
      # Es lo que hace que el archivo no tenga que existir en el servidor, y es
      # también la validación de la carga: `SchemaUpload` la llama ANTES de
      # subir nada, así que un archivo que no sea un XSD válido —o que tenga un
      # `xs:import` sin resolver— se rechaza en la pantalla.
      #
      # @param xsd [String] los bytes del esquema.
      # @param code [String, nil] solo para el mensaje de error.
      # @return [Nokogiri::XML::Schema]
      # @raise [InvalidSchema]
      def compile(xsd, code: nil)
        Nokogiri::XML::Schema(xsd)
      rescue Nokogiri::XML::SyntaxError, ArgumentError, RuntimeError => e
        subject = code ? "el esquema XSD de #{label(code) || code}" : 'el esquema XSD'
        raise InvalidSchema,
              "No se pudo leer #{subject}: #{e.message.to_s.squish}"
      end

      # La ruta del blob de un archivo recién subido.
      #
      # El digest del contenido va en la ruta a propósito: es lo que hace que
      # subir un archivo distinto produzca una ruta distinta, y con eso el caché
      # de todos los procesos se invalide solo. Dieciséis caracteres del SHA-256
      # alcanzan de sobra para nueve archivos que cambian una vez por año.
      #
      # @return [String] `xsd/{CODE}/{digest}/{nombre}.xsd`
      def blob_path(code:, file_name:, content:)
        digest = Digest::SHA256.hexdigest(content)[0, 16]

        "#{BLOB_PREFIX}/#{code}/#{digest}/#{file_name}"
      end

      # El nombre del archivo tal como lo subió el operador, para la pantalla.
      #
      # @param path [String, nil] la ruta guardada en el ajuste.
      # @return [String, nil]
      def file_name(path) = path.to_s.split('/').last.presence

      # "clvsfe" — el mismo contenedor de los XML de comprobante. Los XSD
      # cuelgan de `xsd/` y los comprobantes de `{cédula}/`, así que comparten
      # contenedor sin pisarse, y el operador configura una sola cuenta.
      def container
        Setting.group('AZURE_STORAGE').fetch('CONTAINER')
      rescue KeyError
        raise Azure::BlobStorage::MissingConfiguration,
              'Falta el ajuste AZURE_STORAGE_CONTAINER en Configuraciones → Generales, ' \
              'necesario para guardar los esquemas XSD de Hacienda.'
      end

      # Vacía el caché de ESTE proceso. La usan los specs y `SchemaUpload`
      # después de reemplazar un archivo: el proceso que subió el XSD no tiene
      # por qué esperar a que el ajuste cambie de ruta para dejar de servir el
      # anterior.
      def clear_cache!
        @mutex.synchronize { @cache = {} }
      end
    end
  end
end

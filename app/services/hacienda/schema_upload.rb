# frozen_string_literal: true

module Hacienda
  # Reemplaza el archivo XSD de un tipo de comprobante: valida lo que se subió,
  # lo guarda en Azure y deja el ajuste apuntando al blob nuevo.
  #
  #   Hacienda::SchemaUpload.new(code: 'HACIENDA_XSD_01', upload: params[:File]).call
  #   # => "xsd/HACIENDA_XSD_01/9f86d081884c7d65/FacturaElectronica_V4.4.xsd"
  #
  # Es la contraparte de escritura de `SchemaStore`, separada por la misma razón
  # que `Certificates::ExpirationReader` está separado de `CompanyFiles::Store`
  # (`CLAUDE.md` §34): leer un esquema pasa en cada emisión y tiene que ser
  # barato; escribirlo pasa una vez por instalación y tiene que ser cuidadoso.
  #
  # ── El orden de las operaciones ────────────────────────────────────────────
  # Es el de §34, con Azure en lugar del disco:
  #
  #   1. validar la extensión, el tamaño y —lo que de verdad importa— que el
  #      archivo COMPILE como esquema, antes de escribir nada;
  #   2. subir el blob nuevo;
  #   3. actualizar el ajuste. Si falla, se borra el blob recién subido: no lo
  #      apunta nadie;
  #   4. recién entonces borrar el anterior, y solo si la ruta cambió — subir
  #      dos veces el MISMO archivo da el mismo digest y la misma ruta, así que
  #      "el anterior" y "el nuevo" son el mismo blob.
  #
  # Compilar en el paso 1 es lo que convierte un fallo de producción en un error
  # de pantalla: un XSD con un `xs:import` sin resolver (ver el encabezado de
  # `SchemaStore`) se rechaza acá, con el mensaje de libxml2, y no en medio de la
  # emisión de un comprobante.
  class SchemaUpload
    # No se pudo guardar por algo que el operador puede corregir: la extensión,
    # el tamaño, o que el archivo no sea un esquema válido.
    class Error < StandardError; end

    # Se admite lo que el operador pueda haber bajado del sitio de Hacienda sin
    # renombrar. El nombre se limpia igual antes de que forme parte de la ruta.
    VALID_FILE_NAME = /\A[A-Za-z0-9._-]+\z/

    # @param code [String] uno de `SchemaStore::CODES`.
    # @param upload [ActionDispatch::Http::UploadedFile]
    def initialize(code:, upload:)
      @code = code
      @upload = upload
    end

    # @return [String] la ruta del blob que quedó guardada en el ajuste.
    # @raise [Error] el archivo no sirve.
    # @raise [SchemaStore::InvalidSchema] el archivo no compila como esquema.
    # @raise [Azure::BlobStorage::Error] Azure no está configurado o rechazó la subida.
    def call
      content = read

      # Compilar ANTES de subir: si el archivo no sirve, no llegó a tocar Azure.
      SchemaStore.compile(content, code: code)

      setting = load_setting
      previous = setting.value
      path = SchemaStore.blob_path(code: code, file_name: file_name, content: content)

      storage.upload(container: container, path: path, content: content, content_type: SchemaStore::CONTENT_TYPE)

      begin
        setting.update_value!(path)
      rescue ActiveRecord::RecordInvalid => e
        # El blob quedó escrito y ninguna fila lo apunta.
        discard(path)
        raise Error, e.record.errors.full_messages.to_sentence
      end

      # Este proceso ya no tiene por qué servir el esquema anterior. Los demás
      # se enteran solos: la ruta cambió y su caché la compara en cada lectura.
      SchemaStore.clear_cache!

      discard(previous) if previous.present? && previous != path

      path
    end

    private

    attr_reader :code, :upload

    def read
      raise Error, 'Seleccione un archivo XSD para continuar.' if upload.blank?

      validate_extension!
      validate_size!

      # `rewind` antes de leer: si algo más ya recorrió el tempfile (una
      # validación, un log), el puntero quedó al final y `read` devolvería "".
      upload.rewind if upload.respond_to?(:rewind)
      content = upload.respond_to?(:read) ? upload.read : upload.to_s
      raise Error, 'El archivo XSD está vacío.' if content.blank?

      content
    end

    # El nombre lo elige quien sube el archivo y termina formando parte de la
    # ruta del blob, así que se limpia acá: se descarta cualquier carpeta que
    # traiga y se reemplaza todo lo que no sea alfanumérico, punto, guion o
    # guion bajo. Sin esto, un nombre con `/` cambiaría a qué blob se escribe.
    def file_name
      raw = upload.original_filename.to_s.split(%r{[/\\]}).last.to_s.strip
      name = raw.gsub(/[^A-Za-z0-9._-]+/, '_')

      raise Error, 'El nombre del archivo XSD no es válido.' unless name.match?(VALID_FILE_NAME)
      raise Error, 'El nombre del archivo XSD no es válido.' if name == SchemaStore::EXTENSION

      name
    end

    def validate_extension!
      extension = File.extname(upload.original_filename.to_s).downcase
      return if extension == SchemaStore::EXTENSION

      raise Error, "Seleccione un archivo con extensión #{SchemaStore::EXTENSION}."
    end

    def validate_size!
      max = SchemaStore::MAX_BYTES
      return unless upload.respond_to?(:size) && upload.size.to_i > max

      raise Error,
            'El archivo XSD supera el tamaño máximo permitido ' \
            "(#{ActiveSupport::NumberHelper.number_to_human_size(max)})."
    end

    # `unscoped`: el catálogo lo siembra `db/seeds.rb`, y un ajuste dado de baja
    # tiene que poder reconfigurarse desde la pantalla (`CLAUDE.md` §28).
    def load_setting
      Setting.unscoped.find_by(code: code) ||
        raise(Error, "El ajuste #{code} no existe en el catálogo de la instalación.")
    end

    # Borra un blob que ya no apunta nadie. Nunca levanta: se llama cuando el
    # dato bueno ya quedó guardado, y no poder borrar el anterior deja basura en
    # el contenedor, no un ajuste incorrecto.
    def discard(path)
      storage.delete(container: container, path: path)
    rescue Azure::BlobStorage::Error => e
      Rails.logger.warn("[#{self.class}] no se pudo borrar el blob #{path}: #{e.message}")
    end

    def storage = @storage ||= Azure::BlobStorage.new

    def container = @container ||= SchemaStore.container
  end
end

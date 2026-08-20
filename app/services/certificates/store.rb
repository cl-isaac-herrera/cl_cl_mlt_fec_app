# frozen_string_literal: true

module Certificates
  # Guarda y borra el certificado digital de una compañía en el disco del
  # servidor, bajo `{FILES_BASE_PATH}/{cédula}/{archivo.p12}`.
  #
  # ## Por qué en disco y no en Active Storage
  #
  # El `.p12` no lo lee solo esta aplicación: el servicio de firma lo abre **por
  # su ruta** (`new X509Certificate2(CertPath, CertPin)`) cada vez que firma un
  # XML, y hasta monta un watcher sobre el archivo. Por eso `companies.cert_path`
  # guarda una ruta absoluta y no un identificador: es un contrato entre dos
  # procesos que comparten sistema de archivos. Un blob con nombre de hash —o un
  # bucket— dejaría al firmador sin poder abrirlo.
  #
  # El .NET hacía lo mismo pero armaba la carpeta con el grupo y el `ShortName` de
  # la compañía, dos cosas que esta versión eliminó (`CLAUDE.md` §31 y el campo sin
  # columna). La cédula las reemplaza: identifica a la compañía ante Hacienda, ya
  # está en la tabla y es justamente lo que el nombre del certificado tiene que
  # contener.
  #
  # ## Lo que NO hace
  #
  # No lee el certificado ni valida el PIN — eso es `Certificates::ExpirationReader`,
  # y el controller lo llama ANTES de guardar, para que un PIN equivocado no deje
  # un archivo tirado en el disco.
  class Store
    # Subclase para poder distinguir en el log de dónde salió, aunque el
    # controller las trate igual: las dos son cosas que el usuario puede corregir.
    Error = Class.new(Certificates::Error)

    ALLOWED_EXTENSIONS = %w[.p12 .pfx].freeze

    # La cédula arma un nombre de carpeta. Se valida aunque venga de la base:
    # si algún día se importa un valor con `..` o con separadores, el `File.join`
    # escribiría fuera de la raíz.
    VALID_ID_NUMBER = /\A[A-Za-z0-9-]+\z/

    # Separador de ruta, de los dos. La base es una ruta de Windows y Ruby en
    # Linux no reconoce `\`, así que partir por ambos es lo único que funciona en
    # los dos lados (y con las rutas heredadas del .NET, que son de Windows).
    PATH_SEPARATOR = %r{[/\\]}

    # El nombre de archivo de una ruta guardada, para mostrar en el formulario.
    # No usa `File.basename` justamente por lo de arriba.
    #
    # @return [String, nil]
    def self.file_name(path)
      path.to_s.split(PATH_SEPARATOR).last.presence
    end

    def initialize(company)
      @company = company
    end

    # Escribe el archivo y devuelve su ruta absoluta, la que va a `cert_path`.
    #
    # Sobrescribe si ya había uno con el mismo nombre: es el mismo certificado
    # recargado, y dejar copias numeradas solo haría que nadie sepa cuál usa el
    # firmador.
    #
    # @param upload [ActionDispatch::Http::UploadedFile]
    # @return [String] ruta absoluta del archivo guardado.
    # @raise [Error] si falta la cédula, la extensión no sirve o el disco falla.
    def save!(upload)
      path = File.join(directory, file_name_for(upload))

      FileUtils.mkdir_p(directory)
      File.open(path, 'wb') do |destination|
        source = upload.respond_to?(:tempfile) ? upload.tempfile : upload
        source.binmode if source.respond_to?(:binmode)
        source.rewind  if source.respond_to?(:rewind)
        IO.copy_stream(source, destination)
      end

      path
    rescue SystemCallError, IOError => e
      # `File.open` en modo 'wb' ya truncó (o creó) el archivo antes de fallar:
      # dejarlo sería peor que no tenerlo, porque el firmador encontraría un .p12
      # a medias.
      remove(path)
      raise Error, "No se pudo guardar el certificado en el servidor: #{e.message}"
    end

    # Borra un archivo que esta clase haya guardado.
    #
    # **Solo toca lo que está dentro de la raíz configurada.** Una compañía
    # importada del .NET tiene una ruta de aquel servidor, que esta aplicación no
    # administra: borrarla sería destruir el certificado que el firmador está
    # usando, desde una pantalla que no sabe nada de esa carpeta.
    #
    # Nunca levanta: se llama después de que el guardado ya salió bien, y no poder
    # borrar el anterior deja basura, no un dato incorrecto.
    def remove(path)
      return if path.blank?
      return unless inside_base?(path)
      return unless File.exist?(path)

      File.delete(path)
    rescue SystemCallError => e
      Rails.logger.warn("[Certificates::Store] no se pudo borrar #{path}: #{e.message}")
    end

    # Ruta absoluta del certificado de la compañía, si el archivo existe de verdad.
    # Una compañía importada apunta al disco del servidor .NET, así que tener
    # `cert_path` no garantiza que el archivo esté acá.
    #
    # @return [String, nil]
    def readable_path
      path = @company.cert_path
      return nil if path.blank?
      return nil unless File.file?(path)

      path
    end

    private

    def base_path = Rails.application.config.files_base_path.to_s

    def directory
      id_number = @company.issuer_id_number.to_s.strip

      if id_number.blank?
        raise Error, 'La compañía debe tener número de identificación antes de cargar el certificado.'
      end
      raise Error, 'El número de identificación de la compañía no es válido.' unless id_number.match?(VALID_ID_NUMBER)

      File.join(base_path, id_number)
    end

    # El nombre lo elige quien sube el archivo, así que se limpia antes de que
    # toque el disco: se descarta cualquier carpeta que traiga y se reemplaza todo
    # lo que no sea alfanumérico, punto, guion o guion bajo.
    def file_name_for(upload)
      raw  = upload.original_filename.to_s.split(PATH_SEPARATOR).last.to_s.strip
      name = raw.gsub(/[^A-Za-z0-9._-]+/, '_')
      extension = File.extname(name).downcase

      raise Error, 'Seleccione un certificado con extensión válida (.p12 o .pfx).' unless ALLOWED_EXTENSIONS.include?(extension)
      raise Error, 'El nombre del certificado no es válido.' if name == extension

      name
    end

    def inside_base?(path)
      base = File.expand_path(base_path)
      File.expand_path(path).start_with?("#{base}#{File::SEPARATOR}")
    rescue ArgumentError
      false
    end
  end
end

# frozen_string_literal: true

module CompanyFiles
  # Guarda y borra un archivo de una compañía en el disco del servidor, bajo
  # `{FILES_BASE_PATH}/{cédula}/{archivo}`.
  #
  # Es la mecánica compartida de los tres archivos que tiene una compañía: el
  # certificado digital (`Certificates::Store`), el logo
  # (`Attachments::LogoStore`) y el formato de impresión
  # (`Attachments::PrintFormatStore`). Cada subclase solo declara en qué columna
  # vive la ruta, qué extensiones acepta, cuánto puede pesar y cómo se nombra el
  # archivo en los mensajes.
  #
  # ## Por qué en disco y no en Active Storage
  #
  # Ninguno de los tres lo lee solo esta aplicación:
  #
  # - el `.p12` lo abre **por su ruta** el servicio de firma
  #   (`new X509Certificate2(CertPath, CertPin)`) cada vez que firma un XML, y
  #   hasta monta un watcher sobre el archivo;
  # - el `.rpt` lo abre el generador del PDF (`CreatePdf(DocId, FEPrintFormat)`),
  #   que además lo copia a una carpeta temporal por su ruta;
  # - el logo lo adjunta el servicio de correo (`new Attachment(companyLogoPath)`)
  #   para incrustarlo en el cuerpo del mensaje.
  #
  # Por eso las tres columnas guardan una ruta absoluta y no un identificador: es
  # un contrato entre procesos que comparten sistema de archivos. Un blob con
  # nombre de hash —o un bucket— dejaría a esos servicios sin poder abrirlos.
  #
  # El .NET armaba la carpeta con el grupo y el `ShortName` de la compañía, dos
  # cosas que esta versión eliminó (`CLAUDE.md` §31 y el campo sin columna). La
  # cédula las reemplaza: identifica a la compañía ante Hacienda y ya está en la
  # tabla. Los tres archivos comparten esa carpeta y no se pisan entre sí, porque
  # cada uno valida su propia extensión y cada columna se lee aparte.
  #
  # ## Lo que NO hace
  #
  # No abre el archivo ni valida su contenido. Para el certificado eso es
  # `Certificates::ExpirationReader`, y el controller lo llama ANTES de guardar,
  # para que un PIN equivocado no deje un archivo tirado en el disco.
  class Store
    # ── Contrato de las subclases ────────────────────────────────────────────
    #
    # Se leen con `self.class::` y no como constante suelta a propósito: la
    # búsqueda de una constante sin prefijo es LÉXICA, así que acá adentro
    # resolvería siempre la de esta clase base y nunca la de la subclase.

    # Extensiones aceptadas, en minúscula y con el punto.
    ALLOWED_EXTENSIONS = [].freeze

    # Columna de `companies` donde vive la ruta.
    PATH_COLUMN = nil

    # Cómo se nombra el archivo en los mensajes de error. Los tres son
    # masculinos, así que las frases arrancan con "un …" / "el …".
    NOUN = 'archivo'

    # Nombre con el que queda el archivo en disco, sin la extensión. `nil`
    # conserva el que subió el usuario (limpiado); un valor lo fuerza, así que
    # `logo corporativo v3.PNG` termina como `logo.png`.
    FIXED_BASENAME = nil

    # Tope de tamaño. No es una regla de negocio: existe para que el campo no sea
    # una vía para llenar el disco del servidor.
    MAX_BYTES = 1.megabyte

    # La cédula arma un nombre de carpeta. Se valida aunque venga de la base: si
    # algún día se importa un valor con `..` o con separadores, el `File.join`
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

    # Escribe el archivo y devuelve su ruta absoluta, la que va a la columna.
    #
    # Sobrescribe si ya había uno con el mismo nombre: es el mismo archivo
    # recargado, y dejar copias numeradas solo haría que nadie sepa cuál está
    # usando el servicio que lo lee.
    #
    # @param upload [ActionDispatch::Http::UploadedFile]
    # @return [String] ruta absoluta del archivo guardado.
    # @raise [Error] si falta la cédula, la extensión no sirve, el archivo pesa
    #   de más o el disco falla.
    def save!(upload)
      ensure_within_size_limit!(upload)
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
      # dejarlo sería peor que no tenerlo, porque el servicio que lo lee
      # encontraría un archivo a medias.
      remove(path)
      raise Error, "No se pudo guardar el #{noun} en el servidor: #{e.message}"
    end

    # Borra un archivo que esta clase haya guardado.
    #
    # **Solo toca lo que está dentro de la raíz configurada.** Una compañía
    # importada del .NET tiene una ruta de aquel servidor, que esta aplicación no
    # administra: borrarla sería destruir el archivo que ese servicio está
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
      Rails.logger.warn("[#{self.class}] no se pudo borrar #{path}: #{e.message}")
    end

    # Ruta absoluta del archivo de la compañía, si el archivo existe de verdad.
    # Una compañía importada apunta al disco del servidor .NET, así que tener la
    # columna llena no garantiza que el archivo esté acá.
    #
    # @return [String, nil]
    def readable_path
      path = @company[self.class::PATH_COLUMN]
      return nil if path.blank?
      return nil unless File.file?(path)

      path
    end

    private

    def noun = self.class::NOUN

    def base_path = Rails.application.config.files_base_path.to_s

    def directory
      id_number = @company.issuer_id_number.to_s.strip

      if id_number.blank?
        raise Error, "La compañía debe tener número de identificación antes de cargar el #{noun}."
      end
      raise Error, 'El número de identificación de la compañía no es válido.' unless id_number.match?(VALID_ID_NUMBER)

      File.join(base_path, id_number)
    end

    # El nombre lo elige quien sube el archivo, así que se limpia antes de que
    # toque el disco: se descarta cualquier carpeta que traiga y se reemplaza todo
    # lo que no sea alfanumérico, punto, guion o guion bajo.
    #
    # Con `FIXED_BASENAME` el nombre no se conserva en absoluto: se descarta y
    # queda `{FIXED_BASENAME}{extensión}`. Ahí no hace falta el chequeo de "nombre
    # no válido" — el resultado siempre lo es.
    def file_name_for(upload)
      raw  = upload.original_filename.to_s.split(PATH_SEPARATOR).last.to_s.strip
      name = raw.gsub(/[^A-Za-z0-9._-]+/, '_')
      extension = File.extname(name).downcase

      unless self.class::ALLOWED_EXTENSIONS.include?(extension)
        raise Error, "Seleccione un #{noun} con extensión válida (#{extension_list})."
      end

      fixed = self.class::FIXED_BASENAME
      return "#{fixed}#{extension}" if fixed

      raise Error, "El nombre del #{noun} no es válido." if name == extension

      name
    end

    # ".p12 o .pfx", ".jpg, .jpeg o .png", ".rpt" — la lista tal como se le
    # muestra al usuario.
    def extension_list
      self.class::ALLOWED_EXTENSIONS.to_sentence(two_words_connector: ' o ', last_word_connector: ' o ')
    end

    def ensure_within_size_limit!(upload)
      max = self.class::MAX_BYTES
      return unless upload.respond_to?(:size) && upload.size.to_i > max

      raise Error,
            "El #{noun} supera el tamaño máximo permitido " \
            "(#{ActiveSupport::NumberHelper.number_to_human_size(max)})."
    end

    def inside_base?(path)
      base = File.expand_path(base_path)
      File.expand_path(path).start_with?("#{base}#{File::SEPARATOR}")
    rescue ArgumentError
      false
    end
  end
end

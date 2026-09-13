# frozen_string_literal: true

module Api
  # Los archivos XSD con los que se valida cada comprobante contra el esquema de
  # Hacienda (pantalla Configuraciones → Generales, sección "Esquemas XSD de
  # Hacienda").
  #
  #   GET /api/hacienda_schemas/HACIENDA_XSD_01   → baja el archivo cargado
  #   PUT /api/hacienda_schemas/HACIENDA_XSD_01   → lo reemplaza (multipart)
  #
  # ── Por qué NO es `PATCH /api/settings/:code` ──────────────────────────────
  # El valor de estos nueve ajustes es la ruta de un blob, y esa ruta **la
  # decide el servidor**: la arma `Hacienda::SchemaStore.blob_path` con el
  # digest del contenido. Aceptarla del cuerpo es exactamente lo que `CLAUDE.md`
  # §34 prohíbe para `cert_path` y `logo_path`, y por el mismo motivo — el
  # cliente escribiría en una columna que otro proceso lee como dirección de un
  # archivo. Así que el recurso que la pantalla manipula no es el ajuste sino el
  # **esquema**, y su cuerpo es multipart con el archivo.
  #
  # El ajuste sigue existiendo y `GET /api/settings` sigue devolviendo su valor:
  # es de donde la pantalla saca el nombre del archivo cargado. Lo que no se
  # puede es escribirlo desde ahí.
  #
  # ── PUT y no POST ─────────────────────────────────────────────────────────
  # Cada `code` tiene UN esquema y subir uno reemplaza el anterior por completo.
  # Mandar dos veces el mismo archivo deja el sistema igual —mismo digest, misma
  # ruta, ni siquiera cambia el ajuste—, que es lo que PUT promete (§28).
  #
  # El permiso es `Configurations_General_Access`, el mismo que abre la pantalla
  # y el mismo que exige `Api::SettingsController`; la decisión de no inventar un
  # permiso de escritura aparte está anotada en `TODOS.md`.
  class HaciendaSchemasController < AuthorizedController
    before_action -> { require_permission!(PERMISSION) }
    before_action :load_code

    PERMISSION = 'Configurations_General_Access'

    # GET /api/hacienda_schemas/:code
    #
    # Devuelve el archivo tal como se cargó, con su nombre original. Es el botón
    # "Descargar" de la sección: lo que sirve para confirmar QUÉ esquema está
    # usando la instalación, que es justo lo que la ruta del blob no dice a
    # simple vista.
    def show
      path = Setting.value_for(@code)

      if path.blank?
        return render json: ApiResponse.not_found(not_configured_message).to_h, status: :not_found
      end

      content = Azure::BlobStorage.new.download(container: Hacienda::SchemaStore.container, path: path)

      send_data content,
                filename: Hacienda::SchemaStore.file_name(path) || "#{@code.downcase}.xsd",
                type: Hacienda::SchemaStore::CONTENT_TYPE,
                disposition: 'attachment'
    rescue Azure::BlobStorage::Error => e
      render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
    end

    # PUT /api/hacienda_schemas/:code
    #
    # Cuerpo multipart con la parte `File`.
    def update
      path = Hacienda::SchemaUpload.new(code: @code, upload: params[:File]).call

      render json: ApiResponse.success(serialize(path),
                                       message: 'Esquema XSD actualizado con éxito.').to_h
    rescue Hacienda::SchemaUpload::Error, Hacienda::SchemaStore::InvalidSchema => e
      # Lo que el operador puede corregir: la extensión, el tamaño, o un archivo
      # que no compila como esquema.
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue Azure::BlobStorage::Error => e
      # Azure sin configurar o rechazando la subida no es un error del archivo
      # que eligió el operador: es la instalación, y el mensaje lo dice.
      render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
    end

    private

    # El `code` tiene que ser uno de los nueve del catálogo. Sin este guard, un
    # `code` de otro grupo dejaría una ruta de blob en un ajuste que se lee como
    # otra cosa — una URL de Hacienda, una contraseña — y nadie se enteraría
    # hasta que ese ajuste se usara.
    def load_code
      @code = params[:code].to_s
      return if Hacienda::SchemaStore.code?(@code)

      render json: ApiResponse.not_found('El esquema XSD no existe.').to_h, status: :not_found
    end

    def not_configured_message
      "No se encuentra el archivo XSD configurado para #{Hacienda::SchemaStore.label(@code)}."
    end

    # Se devuelve lo que quedó guardado, no lo que vino en el cuerpo: el nombre
    # del archivo lo limpia el servidor antes de que forme parte de la ruta, así
    # que la pantalla necesita el estado real para pintar el campo.
    def serialize(path)
      {
        Code: @code,
        Label: Hacienda::SchemaStore.label(@code),
        FileName: Hacienda::SchemaStore.file_name(path),
        Value: path
      }
    end
  end
end

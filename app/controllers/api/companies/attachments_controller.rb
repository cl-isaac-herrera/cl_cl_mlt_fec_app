# frozen_string_literal: true

module Api
  module Companies
    # Sección "Adjuntos de la compañía" del formulario de compañías: el logo y el
    # formato de impresión.
    #
    # Un endpoint por sección, igual que `GeneralController` y
    # `TaxAuthorityController`: en la pantalla cada sección tiene su botón
    # "Actualizar" y su loader, así que a nivel de proceso también son
    # independientes. Este PATCH escribe **solo** las dos columnas de su sección
    # y no puede tocar los datos generales ni el certificado ni siquiera si
    # vinieran en el cuerpo.
    #
    # Reemplaza el `PATCH /api/Companies?groupId=N&action=3` del .NET, que
    # mandaba las 42 columnas de las dos tablas del legado en cada guardado — y
    # que, desde que los secretos de Hacienda dejaron de volver al cliente,
    # guardar esta sección le borraba al .NET el PIN del certificado y la
    # contraseña del token (el formulario los manda vacíos porque no los conoce).
    #
    # ## El cuerpo es multipart
    #
    # Los dos campos de la sección son archivos. Las dos partes son opcionales y
    # **la parte ausente significa "dejalo como está"**: guardar la sección para
    # cambiar el logo no puede tocar el formato de impresión, porque el
    # formulario muestra su nombre pero no vuelve a subir el archivo.
    #
    # | Cuerpo                     | Efecto                                  |
    # |----------------------------|-----------------------------------------|
    # | sin partes                 | no cambia nada                          |
    # | `Logo` con archivo         | reemplaza el logo, borra el anterior    |
    # | `PrintFormat` con archivo  | reemplaza el formato, borra el anterior |
    #
    # **No hay forma de vaciar una de las dos columnas desde acá**, y es
    # deliberado: el servicio de emisión levanta si la compañía no tiene formato
    # de impresión ("No se ha configurado un formato de impresion para FE"), así
    # que un campo que se pueda dejar en blanco la dejaría sin poder emitir. Para
    # volver al formato por defecto está el botón "Restablecer formato", que todavía
    # no se migró porque necesita el formato por defecto de la aplicación
    # (`TODOS.md` → Compañías).
    #
    # ## La ruta la deriva el servidor
    #
    # `logo_path` y `print_format_path` **no se aceptan del cuerpo**, por lo mismo
    # que `cert_path`: la columna guarda la ruta absoluta que otro proceso abre
    # —el servicio de correo el logo, el generador del PDF el `.rpt`— y el
    # formulario solo muestra el nombre del archivo. Guardar lo que había en
    # pantalla dejaba `logo.png` a secas en una columna que se lee como ruta.
    # Las dos las arma `CompanyFiles::Store` con la raíz configurada y la cédula.
    class AttachmentsController < AuthorizedController
      # El alcance lo comparte con la lectura (`GET /api/companies/:id`): si no
      # resolvieran el mismo conjunto, el formulario abriría una compañía que este
      # guardado después rechaza (`CLAUDE.md` §28).
      include VisibleCompanies

      # El permiso se resuelve ANTES de buscar el registro: si se hiciera al
      # revés, un 404 le confirmaría a quien no tiene permiso qué ids existen.
      before_action :authorize_action
      before_action :load_company

      # Los dos adjuntos: cómo se llama su parte en el cuerpo, en qué columna vive
      # su ruta, quién lo guarda y con qué clave se devuelve su nombre.
      # `::Attachments` con el prefijo del root: sin él, la búsqueda arrancaría
      # dentro de `Api::Companies` y este controller se llama justamente
      # `AttachmentsController`.
      ATTACHMENTS = [
        { param: :Logo,        column: :logo_path,
          store: ::Attachments::LogoStore,        key: :LogoFileName },
        { param: :PrintFormat, column: :print_format_path,
          store: ::Attachments::PrintFormatStore, key: :PrintFormatFileName }
      ].freeze

      # PATCH /api/companies/:company_id/attachments
      #
      # Cuerpo multipart con `Logo` y/o `PrintFormat`.
      def update
        previous = @company.slice(*ATTACHMENTS.map { |a| a[:column].to_s })

        begin
          attributes = saved_attributes
        rescue CompanyFiles::Error => e
          # Si el primero se escribió y el segundo falló, el primero no lo apunta
          # nadie: se borra antes de contestar.
          discard(@written)
          return render_error(e.message)
        end

        unless @company.update(attributes)
          discard(attributes)
          return render_invalid
        end

        # Los anteriores recién se borran cuando los nuevos ya están en disco y la
        # fila apunta a ellos. Al revés, un fallo a mitad de camino dejaba a la
        # compañía sin logo ni formato y sin forma de recuperarlos.
        remove_replaced(previous, attributes)

        render json: ApiResponse.success(serialize(@company),
                                         message: 'Adjuntos actualizados con éxito.').to_h
      end

      private

      def authorize_action
        require_permission!('Configurations_Companies_Update')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end

      # Escribe en disco los archivos que vinieron y devuelve las columnas a
      # actualizar. Sin partes en el cuerpo devuelve `{}` y el PATCH queda en un
      # no-op exitoso: es el mismo criterio que las otras dos secciones, donde un
      # cuerpo sin claves no se distingue de "el usuario no cambió nada".
      #
      # `@written` acumula lo ya escrito para poder deshacerlo si algo falla más
      # adelante.
      #
      # @raise [CompanyFiles::Error]
      def saved_attributes
        @written = []

        ATTACHMENTS.each_with_object({}) do |attachment, attributes|
          upload = params[attachment[:param]]
          next if upload.blank?

          path = attachment[:store].new(@company).save!(upload)
          @written << [attachment[:column], path]
          attributes[attachment[:column]] = path
        end
      end

      # Borra archivos recién escritos que no quedaron referenciados por ninguna
      # fila. Recibe el hash de columna => ruta, o los pares de `@written`.
      def discard(written)
        written.to_a.each { |column, path| store_for(column).new(@company).remove(path) }
      end

      # Borra el archivo que acaba de ser reemplazado, y solo si de verdad cambió:
      # subir dos veces el mismo nombre sobrescribe en su lugar, y ahí la ruta
      # vieja y la nueva son la misma.
      def remove_replaced(previous, attributes)
        attributes.each do |column, path|
          old = previous[column.to_s]
          next if old.blank? || old == path

          store_for(column).new(@company).remove(old)
        end
      end

      def store_for(column)
        ATTACHMENTS.find { |attachment| attachment[:column] == column }.fetch(:store)
      end

      # Se devuelve la sección tal como quedó guardada, no lo que vino en el
      # cuerpo: el servidor decide dónde queda el archivo y con qué nombre (lo
      # limpia antes de que toque el disco), y el formulario necesita el estado
      # real para volver a marcar la sección como "sin cambios".
      #
      # El NOMBRE del archivo y no la ruta: la ruta absoluta en el servidor es
      # infraestructura, y el cliente ya no puede escribirla.
      #
      # ⚠️ Estas dos claves tienen que ser las mismas que devuelve
      # `Api::CompaniesController#serialize_detail` para esta sección. Si una se
      # agrega en un lado y no en el otro, el formulario muestra un campo que este
      # PATCH ignora: el usuario lo edita, guarda, y no pasa nada — sin error.
      # `spec/requests/api/company_attachments_spec.rb` compara las dos listas.
      def serialize(company)
        ATTACHMENTS.each_with_object({}) do |attachment, names|
          names[attachment[:key]] = CompanyFiles::Store.file_name(company[attachment[:column]])
        end
      end

      def render_invalid
        render_error(@company.errors.full_messages.to_sentence)
      end

      def render_error(message)
        render json: ApiResponse.error(message).to_h, status: :unprocessable_content
      end
    end
  end
end

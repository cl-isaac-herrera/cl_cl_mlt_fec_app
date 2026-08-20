# frozen_string_literal: true

module Api
  module Companies
    # Descarga del formato de impresión (`.rpt`) de una compañía (botón
    # "Descargar formato" de la sección "Adjuntos de la compañía").
    #
    # Reemplaza `GET /api/companies/:id/print-format` del .NET — con la ruta en
    # `snake_case`, que es la convención de los endpoints migrados
    # (`CLAUDE.md` §28). Se puede migrar ahora porque el archivo ya lo guarda esta
    # aplicación (`Attachments::PrintFormatStore`); antes vivía en el disco del
    # servidor .NET.
    #
    # `resource` singular y sin id: una compañía tiene un formato de impresión, no
    # una colección.
    #
    # ## Por qué no hay `destroy`
    #
    # El botón "Restablecer formato" de la pantalla sigue yendo al .NET. Ahí
    # "restablecer" **no** era vaciar la columna: copiaba el formato por defecto
    # —el del grupo— a la carpeta de la compañía y apuntaba la columna al archivo
    # nuevo. Vaciarla no es un equivalente: el servicio de emisión levanta si la
    # compañía no tiene formato ("No se ha configurado un formato de impresion
    # para FE"), así que la dejaría sin poder emitir.
    #
    # En esta versión no hay grupos (`CLAUDE.md` §31), y el formato por defecto de
    # la aplicación vive en las configuraciones generales, que todavía no tienen
    # tabla. Hasta que la tengan no hay de dónde copiar, y por eso el reset queda
    # pendiente en vez de migrado a medias (`TODOS.md` → Compañías).
    class PrintFormatController < AuthorizedController
      include VisibleCompanies

      before_action :authorize_action
      before_action :load_company

      NOT_FOUND = 'El formato de impresión de la compañía no está disponible en el servidor.'

      # GET /api/companies/:company_id/print_format
      def show
        path = ::Attachments::PrintFormatStore.new(@company).readable_path

        # Sin archivo en disco no es un 500 ni un error del servidor: o la
        # compañía nunca cargó uno, o su `print_format_path` apunta al servidor
        # .NET del que se importó y este no lo tiene.
        return render json: ApiResponse.not_found(NOT_FOUND).to_h, status: :not_found if path.nil?

        send_file path,
                  filename:    CompanyFiles::Store.file_name(path),
                  type:        'application/x-rpt',
                  disposition: 'attachment'
      end

      private

      # Los dos permisos que el .NET ya evaluaba para esta descarga: el global
      # habilita bajar el formato de cualquier compañía y el normal, el de las
      # propias. Acá el ALCANCE lo resuelve `VisibleCompanies` con su propio
      # permiso, así que los dos autorizan la misma lectura sobre el conjunto que
      # el solicitante puede ver — de ahí el `any` (`CLAUDE.md` §28).
      def authorize_action
        require_any_permission!('Configurations_Companies_DownloadFEPrintFormat',
                                'Configurations_Companies_DownloadFEPrintFormatInAllCompanies')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end
    end
  end
end

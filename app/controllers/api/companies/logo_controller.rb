# frozen_string_literal: true

module Api
  module Companies
    # Descarga del logo de una compañía (botón "Descargar logo" de la sección
    # "Adjuntos de la compañía").
    #
    # Reemplaza `GET /api/companies/:id/logo` del .NET. Se puede migrar ahora
    # porque el archivo ya lo guarda esta aplicación (`Attachments::LogoStore`);
    # antes vivía en el disco del servidor .NET.
    #
    # `resource` singular y sin id: una compañía tiene un logo, no una colección
    # (`CLAUDE.md` §28).
    class LogoController < AuthorizedController
      include VisibleCompanies

      before_action :authorize_action
      before_action :load_company

      NOT_FOUND = 'El logo de la compañía no está disponible en el servidor.'

      # Los tipos que acepta el store, para no deducir el Content-Type del nombre
      # del archivo con una tabla abierta.
      CONTENT_TYPES = { '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.png' => 'image/png' }.freeze

      # GET /api/companies/:company_id/logo
      def show
        path = ::Attachments::LogoStore.new(@company).readable_path

        # Sin archivo en disco no es un 500 ni un error del servidor: o la
        # compañía nunca cargó uno, o su `logo_path` apunta al servidor .NET del
        # que se importó y este no lo tiene.
        return render json: ApiResponse.not_found(NOT_FOUND).to_h, status: :not_found if path.nil?

        send_file path,
                  filename:    CompanyFiles::Store.file_name(path),
                  type:        CONTENT_TYPES.fetch(File.extname(path).downcase, 'application/octet-stream'),
                  disposition: 'attachment'
      end

      private

      # Los dos permisos que el .NET ya evaluaba para esta descarga: el global
      # habilita bajar el logo de cualquier compañía y el normal, el de las
      # propias. Acá el ALCANCE lo resuelve `VisibleCompanies` con su propio
      # permiso, así que los dos autorizan la misma lectura sobre el conjunto que
      # el solicitante puede ver — de ahí el `any` (`CLAUDE.md` §28).
      def authorize_action
        require_any_permission!('Configurations_Companies_DownloadLogo',
                                'Configurations_Companies_DownloadLogoInAllCompanies')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module Companies
    # Descarga del certificado digital de una compañía (botón "Descargar
    # certificado" de la sección "Hacienda (ATV)").
    #
    # Reemplaza `GET /api/companies/:id/certificate` del .NET. Se puede migrar
    # ahora porque el archivo ya lo guarda esta aplicación
    # (`Certificates::Store`); antes vivía en el disco del servidor .NET.
    #
    # `resource` singular y sin id: una compañía tiene un certificado, no una
    # colección (`CLAUDE.md` §28).
    class CertificateController < AuthorizedController
      include VisibleCompanies

      before_action :authorize_action
      before_action :load_company

      NOT_FOUND = 'El certificado de la compañía no está disponible en el servidor.'

      # GET /api/companies/:company_id/certificate
      def show
        path = Certificates::Store.new(@company).readable_path

        # Sin archivo en disco no es un 500 ni un error del servidor: o la
        # compañía nunca cargó uno, o su `cert_path` apunta al servidor .NET del
        # que se importó y este no lo tiene.
        return render json: ApiResponse.not_found(NOT_FOUND).to_h, status: :not_found if path.nil?

        send_file path,
                  filename: Certificates::Store.file_name(path),
                  type:     'application/x-pkcs12',
                  disposition: 'attachment'
      end

      private

      # El mismo permiso que edita la sección: el `.p12` con su PIN es la
      # identidad de la compañía ante Hacienda, así que descargarlo no es una
      # lectura más — quien puede bajarlo es quien puede cambiarlo.
      def authorize_action
        require_permission!('Configurations_Companies_Update')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end
    end
  end
end

# frozen_string_literal: true

module Api
  # Prueba unas credenciales de SAP contra el Service Layer de una compañía, antes
  # de que el usuario las guarde en su perfil.
  #
  # Reemplaza `POST /api/Connections/validate-user-credentials`. Es un `create`
  # porque cada llamado produce una validación nueva: el verbo va en el método
  # HTTP y el path nombra el recurso, no la acción.
  class SapCredentialValidationsController < AuthorizedController
    # POST /api/sap_credential_validations
    def create
      # skip_permission_check! — el usuario está probando sus propias credenciales.
      # La autorización que sí importa es contra qué compañía puede probarlas, y se
      # valida abajo con el mismo criterio que el selector: la asignación.
      skip_permission_check!

      # A diferencia del resto de endpoints, la compañía viaja en el cuerpo y no
      # sale de la sesión: la pantalla deja elegir contra cuál probar, que puede no
      # ser la activa. Por eso se valida que esté asignada al usuario.
      company = Company.assigned_to(Current.user.id).find_by(id: params[:CompanyId])

      unless company
        return render json: ApiResponse.forbidden('La compañía no está asignada a este usuario').to_h,
                      status: :forbidden
      end

      result = Sap::CredentialValidator.new(
        company:      company,
        sap_user:     params[:SapUser],
        sap_password: params[:SapPass]
      ).call

      # Credenciales inválidas no son un error de la petición: la respuesta es 200
      # con `Data: false` y el motivo en `Message`, igual que el API .NET.
      render json: ApiResponse.success(result.valid?, message: result.message).to_h
    end
  end
end

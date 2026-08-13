# frozen_string_literal: true

module Api
  # Prueba unas credenciales de SAP contra el Service Layer de una compañía, antes
  # de guardarlas.
  #
  # Reemplaza `POST /api/Connections/validate-user-credentials`. Es un `create`
  # porque cada llamado produce una validación nueva: el verbo va en el método
  # HTTP y el path nombra el recurso, no la acción.
  #
  # Sirve a dos pantallas con dueños distintos: el perfil propio
  # (/configurations/user-profile) y la edición de otro usuario
  # (/configurations/users). `UserId` es lo que las separa.
  class SapCredentialValidationsController < AuthorizedController
    # POST /api/sap_credential_validations
    def create
      target = target_user
      return if performed?

      # A diferencia del resto de endpoints, la compañía viaja en el cuerpo y no
      # sale de la sesión: la pantalla deja elegir contra cuál probar, que puede no
      # ser la activa. Por eso se valida que esté asignada al dueño de las
      # credenciales — probar contra una compañía que no es suya no prueba nada.
      company = Company.assigned_to(target.id).find_by(id: params[:CompanyId])

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

    private

    # Dueño de las credenciales que se están probando. Sin `UserId` es el propio
    # usuario; con `UserId` es otro, y eso ya es administrar usuarios.
    #
    # @return [User, nil] nil cuando ya se respondió (403/404).
    def target_user
      requested = params[:UserId]

      if requested.blank? || requested.to_s == Current.user.id.to_s
        # skip_permission_check! — el usuario está probando sus propias
        # credenciales. La autorización que sí importa es contra qué compañía
        # puede probarlas, y se valida arriba con el mismo criterio que el
        # selector: la asignación.
        skip_permission_check!
        return Current.user
      end

      require_permission!('Configurations_Users_Update')
      return nil if performed?

      # `unscoped`: también se editan las credenciales de un usuario dado de baja.
      user = User.unscoped.find_by(id: requested)
      return user if user

      render json: ApiResponse.not_found('El usuario no existe.').to_h, status: :not_found
      nil
    end
  end
end

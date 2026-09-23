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

      if use_saved_credentials?
        validate_saved_credentials(target, company)
      else
        validate_form_credentials(target, company)
      end
    end

    private

    # `UseSavedCredentials: true` reverifica lo que YA está guardado, sin que el
    # formulario haya cambiado nada: el perfil habilita "Probar credenciales"
    # aunque no haya edición cuando el usuario ya tiene usuario y contraseña
    # configurados (botón deshabilitado en cualquier otro caso — ver
    # `#syncTestCredentialsBtn` en `user_profile_controller.js`).
    #
    # A diferencia del modo normal, acá el resultado se persiste de una vez: no
    # hay ningún cambio pendiente que "Actualizar" vaya a guardar después, así
    # que no tendría sentido pedirle al usuario que pase por ahí solo para
    # confirmar una verificación que ya se hizo contra lo guardado.
    def validate_saved_credentials(target, company)
      if target.sap_user.blank? || target.sap_password.blank?
        return render json: ApiResponse.success(
          false, message: 'No hay credenciales de SAP guardadas para verificar.'
        ).to_h
      end

      result = Sap::CredentialValidator.for_company(
        company:      company,
        sap_user:     target.sap_user,
        sap_password: target.sap_password
      ).call

      if result.valid?
        # `sap_credentials_just_verified`: el mismo atributo virtual que usa
        # `Api::ProfilesController#update` — el modelo lo traduce a
        # `sap_credentials_verified = true` en el `before_save` (ver `User`).
        target.sap_credentials_just_verified = true
        target.save!
      else
        # Nada cambió en el formulario, así que ninguno de los dos campos está
        # "dirty": el `before_save` del modelo no reacciona solo a esto, y hay
        # que apagar la marca a mano — lo guardado ya no es de fiar.
        target.update!(sap_credentials_verified: false)
      end

      render json: ApiResponse.success(result.valid?, message: result.message).to_h
    end

    def validate_form_credentials(target, company)
      result = Sap::CredentialValidator.for_company(
        company:      company,
        sap_user:     params[:SapUser],
        sap_password: params[:SapPass]
      ).call

      # Lo que el guardado va a consultar para marcar `sap_credentials_verified`.
      # Un intento fallido borra la verificación anterior: manda lo último que se
      # probó, igual que el estado del botón en la pantalla.
      if result.valid?
        Sap::CredentialVerification.remember(session, user: target,
                                                      sap_user: params[:SapUser], sap_password: params[:SapPass])
      else
        Sap::CredentialVerification.forget(session)
      end

      # Credenciales inválidas no son un error de la petición: la respuesta es 200
      # con `Data: false` y el motivo en `Message`, igual que el API .NET.
      render json: ApiResponse.success(result.valid?, message: result.message).to_h
    end

    def use_saved_credentials?
      ActiveModel::Type::Boolean.new.cast(params[:UseSavedCredentials])
    end

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

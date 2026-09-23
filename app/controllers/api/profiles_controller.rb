# frozen_string_literal: true

module Api
  # Perfil del usuario autenticado: su nombre y sus credenciales de SAP.
  #
  # Reemplaza `GET /api/User/GetUserInfo` y `PATCH /api/User/profile-info` del API
  # .NET por un solo recurso singular — el verbo va en el método HTTP, no en el
  # path, y el recurso es uno solo porque siempre es el perfil del que pide.
  # Ningún endpoint recibe el id del usuario: sale de la sesión, así que nadie
  # puede leer ni escribir el perfil ajeno.
  class ProfilesController < AuthorizedController
    # GET /api/profile
    def show
      # skip_permission_check! — son los datos del propio usuario. Exigir un permiso
      # para leer el perfil propio dejaría a un usuario sin roles sin poder ni
      # configurar sus credenciales de SAP.
      skip_permission_check!

      render json: ApiResponse.success(serialize(Current.user)).to_h
    end

    # PATCH /api/profile
    def update
      # skip_permission_check! — escribe el perfil del propio usuario de la sesión
      # y ningún id ajeno viaja (ver abajo: siempre `Current.user`). Exigir un
      # permiso dejaría a un usuario sin roles sin poder configurar sus
      # credenciales de SAP, que es lo primero que necesita hacer.
      skip_permission_check!

      user = Current.user
      user.name     = profile_params[:Name].to_s.strip    if profile_params.key?(:Name)
      user.sap_user = profile_params[:SapUser].to_s.strip if profile_params.key?(:SapUser)

      # Contraseña en blanco = sin cambio. El formulario siempre carga el campo
      # vacío (nunca se devuelve la contraseña guardada), así que tomarlo literal
      # borraría la credencial cada vez que alguien cambia solo el nombre.
      user.sap_password = profile_params[:SapPass] if profile_params[:SapPass].present?

      # Probar las credenciales ya no es requisito para guardar: lo que decide es si
      # las que quedan guardadas coinciden con las que pasaron la prueba en esta
      # sesión. Si no coinciden y cambiaron, el modelo apaga la marca.
      verified = Sap::CredentialVerification.confirmed?(session, user: user,
                                                                 sap_user: user.sap_user, sap_password: user.sap_password)
      user.sap_credentials_just_verified = verified

      unless user.save
        return render json: ApiResponse.error(user.errors.full_messages.to_sentence).to_h,
                      status: :unprocessable_content
      end

      Sap::CredentialVerification.forget(session) if verified

      render json: ApiResponse.success(serialize(user), message: 'Información actualizada.').to_h
    end

    private

    def profile_params
      params.permit(:Name, :SapUser, :SapPass)
    end

    # Claves en PascalCase, igual que el resto de respuestas que consume el frontend.
    #
    # La contraseña de SAP nunca sale: se expone solo si hay una guardada, que es
    # todo lo que la pantalla necesita saber para decidir si pedirla de nuevo.
    def serialize(user)
      {
        Id:                     user.id,
        Name:                   user.name,
        Email:                  user.email,
        SapUser:                user.sap_user,
        HasSapPassword:         user.sap_password.present?,
        SapCredentialsVerified: user.sap_credentials_verified
      }
    end
  end
end

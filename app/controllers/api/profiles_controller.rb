# frozen_string_literal: true

module Api
  # Perfil del usuario autenticado: sus credenciales de SAP y el tipo de OC.
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
      skip_permission_check!

      user = Current.user
      user.sap_user              = profile_params[:SapUser].to_s.strip     if profile_params.key?(:SapUser)
      user.doc_number_preference = profile_params[:DocNumberPreference].presence if profile_params.key?(:DocNumberPreference)

      # Contraseña en blanco = sin cambio. El formulario siempre carga el campo
      # vacío (nunca se devuelve la contraseña guardada), así que tomarlo literal
      # borraría la credencial cada vez que alguien cambia solo el tipo de OC.
      user.sap_password = profile_params[:SapPass] if profile_params[:SapPass].present?

      unless user.save
        return render json: ApiResponse.error(user.errors.full_messages.to_sentence).to_h,
                      status: :unprocessable_content
      end

      render json: ApiResponse.success(serialize(user), message: 'Información actualizada.').to_h
    end

    private

    def profile_params
      params.permit(:SapUser, :SapPass, :DocNumberPreference)
    end

    # Claves en PascalCase, igual que el resto de respuestas que consume el frontend.
    #
    # La contraseña de SAP nunca sale: se expone solo si hay una guardada, que es
    # todo lo que la pantalla necesita saber para decidir si pedirla de nuevo.
    def serialize(user)
      {
        Id:                  user.id,
        Name:                user.name,
        Email:               user.email,
        SapUser:             user.sap_user,
        HasSapPassword:      user.sap_password.present?,
        DocNumberPreference: user.doc_number_preference
      }
    end
  end
end

# frozen_string_literal: true

module Api
  # Prueba las credenciales de LICENCIA de una conexión contra su Service Layer,
  # desde el formulario de conexiones y antes de guardarlas.
  #
  # Es el hermano de `SapCredentialValidationsController` y la diferencia es de
  # quién son las credenciales:
  #
  # | | `sap_credential_validations` | `sap_license_validations` |
  # |---|---|---|
  # | Credenciales | `users.sap_user` — de una persona | `connections.sap_license` — del servidor |
  # | Destino | la conexión de la compañía elegida | la URL que se está escribiendo |
  # | Base de SAP | `companies.sap_db` de esa compañía | la escribe quien configura |
  # | Permiso | ninguno / administrar usuarios | administrar conexiones |
  #
  # Un `create` porque cada llamado produce una validación nueva: el verbo va en
  # el método HTTP y el path nombra el recurso (`CLAUDE.md` §28).
  #
  # ── Por qué NO cuelga de `/api/connections/:id` ──────────────────────────────
  # El botón también existe al CREAR, cuando todavía no hay id. Los valores que se
  # prueban son los del formulario, no los guardados — probar los guardados
  # después de escribir otros diría que las credenciales sirven cuando lo que se
  # está por guardar es distinto. `ConnectionId` es opcional y solo sirve para
  # rellenar lo que el formulario no puede mandar: la contraseña ya guardada,
  # que el servidor nunca devuelve.
  class SapLicenseValidationsController < AuthorizedController
    # POST /api/sap_license_validations
    #
    # Cuerpo: { ConnectionId?, SlUrl, SapLicense, SapLicensePassword?, CompanyDb }
    def create
      # Los dos permisos autorizan por separado: el botón está en el panel de
      # creación y en el de edición, y quien puede llenar el formulario puede
      # probar lo que llenó (`CLAUDE.md` §28, `require_any_permission!`).
      require_any_permission!('Configurations_Connections_Create',
                              'Configurations_Connections_Update')
      return if performed?

      result = validator.call

      # Credenciales inválidas no son un error de la petición: 200 con
      # `Data: false` y el motivo en `Message`, igual que el otro validador.
      render json: ApiResponse.success(result.valid?, message: result.message).to_h
    end

    private

    def validator
      Sap::CredentialValidator.new(
        base_url:         base_url,
        company_db:       params[:CompanyDb],
        sap_user:         params[:SapLicense],
        sap_password:     sap_password,
        # El motivo tiene que apuntar al campo del formulario: acá no hay
        # compañía a la que culpar, y el default no dice dónde ponerla.
        missing_messages: { base_url: 'Ingrese la URL del Service Layer antes de probar.' }
      )
    end

    # La conexión guardada, cuando se está editando una. `nil` al crear.
    def connection
      return @connection if defined?(@connection)

      @connection = params[:ConnectionId].present? ? Connection.find_by(id: params[:ConnectionId]) : nil
    end

    # Lo que se prueba es lo que está en el formulario. La conexión guardada solo
    # cubre el hueco: si alguien abre el panel y prueba sin tocar la URL, el campo
    # sí trae el valor cargado, pero un `SlUrl` vacío no tiene por qué mandar la
    # prueba a la nada cuando el registro ya sabe a dónde apunta.
    def base_url
      params[:SlUrl].presence || connection&.sl_url
    end

    # Vacía significa "usar la guardada", igual que en el PATCH de la conexión: el
    # servidor nunca devuelve la contraseña, así que el campo siempre carga en
    # blanco y exigirla obligaría a reescribirla para poder probar la URL.
    #
    # Al crear no hay guardada y el validador corta con "Ingrese el usuario y la
    # contraseña de SAP", que es el motivo correcto.
    def sap_password
      params[:SapLicensePassword].presence || connection&.sap_license_password
    end
  end
end

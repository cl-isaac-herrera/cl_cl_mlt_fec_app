# frozen_string_literal: true

module Api
  # Prueba las credenciales de una bandeja de correo enviando un mensaje de
  # prueba, desde el formulario de bandejas y antes de guardarlas.
  #
  # Reemplaza `POST /api/EmailConfig/ValidateEmailConfig` del servidor de
  # sincronización .NET. Un `create` porque cada llamado produce una validación
  # nueva: el verbo va en el método HTTP y el path nombra el recurso (§28).
  #
  # ── Por qué NO cuelga de `/api/email_configs/:id` ───────────────────────────
  # El botón también existe al CREAR, cuando todavía no hay id, y lo que se
  # prueba son los valores del FORMULARIO: probar los guardados después de
  # escribir otros diría que las credenciales sirven cuando lo que se está por
  # guardar es distinto. Es el mismo criterio (y el mismo contrato) que
  # `Api::SapLicenseValidationsController`.
  #
  # `EmailConfigId` es opcional y solo rellena lo que el formulario no puede
  # mandar: la contraseña ya guardada, que el servidor nunca devuelve.
  class EmailCredentialValidationsController < AuthorizedController
    # POST /api/email_credential_validations
    #
    # Cuerpo: { EmailConfigId?, Email, Password?, Host, Port, Ssl,
    #           SenderAddress?, RecipientEmail }
    def create
      # Los dos permisos autorizan por separado: el botón está en el panel de
      # creación y en el de edición, y quien puede llenar el formulario puede
      # probar lo que llenó (`CLAUDE.md` §28, `require_any_permission!`).
      require_any_permission!('Configurations_EmailInbox_Create',
                              'Configurations_EmailInbox_Update')
      return if performed?

      result = validator.call

      # Credenciales inválidas no son un error de la petición: 200 con
      # `Data: false` y el motivo en `Message`, igual que los validadores de SAP.
      render json: ApiResponse.success(result.valid?, message: result.message).to_h
    end

    private

    def validator
      EmailConfigs::CredentialValidator.new(email_config: candidate,
                                            recipient: params[:RecipientEmail].to_s)
    end

    # La bandeja tal como está EN PANTALLA. Se arma en memoria y no se guarda: es
    # el objeto que el validador necesita para abrir la conexión SMTP, no un
    # registro. `EmailConfig.new` da además `from_header` sin duplicar la regla de
    # cómo se compone el remitente.
    def candidate
      EmailConfig.new(
        email:          params[:Email].to_s.strip,
        host:           params[:Host].to_s.strip,
        port:           params[:Port].to_s.strip.presence&.to_i,
        ssl:            ActiveModel::Type::Boolean.new.cast(params[:Ssl]),
        sender_address: params[:SenderAddress].to_s.strip.presence,
        password:       password
      )
    end

    # Vacía significa "usar la guardada", igual que en el PATCH de la bandeja: el
    # servidor nunca devuelve la contraseña, así que el campo siempre carga en
    # blanco y exigirla obligaría a reescribirla para poder probar un cambio de
    # host.
    #
    # Al crear no hay guardada y el validador corta con "Ingrese la contraseña de
    # la bandeja para poder probarla", que es el motivo correcto.
    def password
      params[:Password].presence || stored_email_config&.password
    end

    # `unscoped`: probar una bandeja dada de baja es legítimo — es el paso previo
    # a reactivarla.
    def stored_email_config
      return @stored_email_config if defined?(@stored_email_config)

      @stored_email_config =
        params[:EmailConfigId].present? ? EmailConfig.unscoped.find_by(id: params[:EmailConfigId]) : nil
    end
  end
end

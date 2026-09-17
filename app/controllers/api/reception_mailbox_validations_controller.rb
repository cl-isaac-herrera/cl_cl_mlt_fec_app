# frozen_string_literal: true

module Api
  # Prueba las credenciales de una bandeja de RECEPCIÓN abriendo una sesión
  # IMAP, desde el panel de "Bandejas de recepción" y antes de guardarlas.
  #
  # Un `create` porque cada llamado produce una validación nueva (§28). No
  # cuelga de `/api/reception_mailboxes/:id`: el botón también existe al
  # CREAR, cuando todavía no hay id, y lo que se prueba son los valores del
  # FORMULARIO — mismo criterio y mismo contrato que
  # `Api::EmailCredentialValidationsController`/`Api::SapLicenseValidationsController`.
  class ReceptionMailboxValidationsController < AuthorizedController
    # POST /api/reception_mailbox_validations
    #
    # Cuerpo: { Id?, MailServer, Email, Port, UseToken, Password?,
    #           Url?, GrantType?, Scope?, ClientId?, ClientSecret? }
    def create
      require_any_permission!('Configurations_MailParser_Create',
                              'Configurations_MailParser_Update')
      return if performed?

      result = ReceptionMailboxes::CredentialValidator.new(mailbox: candidate).call

      # Credenciales inválidas no son un error de la petición: 200 con
      # `Data: false` y el motivo en `Message`, igual que los demás validadores.
      render json: ApiResponse.success(result.valid?, message: result.message).to_h
    end

    private

    # La bandeja tal como está EN PANTALLA. Se arma en memoria y no se guarda.
    def candidate
      ReceptionMailbox.new(
        mail_server: params[:MailServer].to_s.strip,
        email: params[:Email].to_s.strip,
        port: params[:Port].to_s.strip.presence&.to_i,
        use_token: ActiveModel::Type::Boolean.new.cast(params[:UseToken]),
        password: password,
        url: params[:Url].to_s.strip,
        grant_type: params[:GrantType].to_s.strip,
        scope: params[:Scope].to_s.strip,
        client_id: params[:ClientId].to_s.strip,
        client_secret: client_secret
      )
    end

    # Vacío significa "usar el guardado", igual que en el PATCH de la bandeja:
    # el servidor nunca devuelve el secreto, así que el campo siempre carga en
    # blanco. Al crear no hay guardado, y el validador corta con el motivo
    # correcto ("Ingrese la contraseña...").
    def password
      params[:Password].presence || stored_mailbox&.password
    end

    def client_secret
      params[:ClientSecret].presence || stored_mailbox&.client_secret
    end

    # `unscoped`: probar una bandeja dada de baja es legítimo — es el paso
    # previo a reactivarla.
    def stored_mailbox
      return @stored_mailbox if defined?(@stored_mailbox)

      @stored_mailbox = params[:Id].present? ? ReceptionMailbox.unscoped.find_by(id: params[:Id]) : nil
    end
  end
end

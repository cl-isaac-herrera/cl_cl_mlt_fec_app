# frozen_string_literal: true

module Documents
  # Envía el correo de recepción electrónica de un documento (aceptado o
  # rechazado por Hacienda) por la bandeja SMTP asignada a la compañía
  # (`Company#email_config`).
  #
  # No usa ActionMailer: esta app carga Rails a la carta
  # (`config/application.rb` no requiere `action_mailer/railtie`), y lo único
  # que hace falta acá es un mensaje HTML puntual con credenciales SMTP
  # DISTINTAS por compañía — la gema `mail` (Gemfile) alcanza sin la capa
  # completa de ActionMailer (vistas, layouts, previews, config global de
  # entrega), que no aplica a un solo mensaje por fila de la cola.
  #
  # ⚠️ Sin adjuntos: la generación de PDF del comprobante (el legacy
  # `CLVS_FE.Mails/Common.cs#SendMail` la adjunta) queda pendiente — ver el
  # comentario de `SendElectronicReceiptJob`.
  class ReceiptMailer
    # La compañía no tiene bandeja de correo asignada (`Company#email_config`).
    class MissingConfiguration < StandardError; end

    SUBJECT = 'Mensaje de recepción de documento electrónico'

    # @param company [Company] de acá sale la bandeja SMTP (`email_config`).
    # @param to [String] destinatario. Un solo correo (ver `Sap::MailQueue`,
    #   `U_OutputTo` ya trae solo la posición 0 del receptor).
    # @param cc [String, nil] direcciones separadas por `;`.
    # @param bcc [String, nil] direcciones separadas por `;`.
    # @param body_html [String] cuerpo del mensaje.
    def initialize(company:, to:, body_html:, cc: nil, bcc: nil)
      @company   = company
      @to        = to
      @cc        = cc
      @bcc       = bcc
      @body_html = body_html
    end

    # @raise [MissingConfiguration] sin bandeja de correo asignada.
    def call
      # `Mail.new do … end` evalúa el bloque CONTRA el mensaje (`instance_eval`),
      # así que ahí adentro `self` es el `Mail::Message` y no esta instancia —
      # `email_config`/`addresses` no se podrían llamar dentro de ese bloque.
      # Armar el mensaje con asignaciones evita ese problema.
      message = Mail.new
      message.from    = email_config.from_header
      message.to      = addresses(to)
      message.cc      = addresses(cc)  if cc.present?
      message.bcc     = addresses(bcc) if bcc.present?
      message.subject = SUBJECT

      message.html_part = Mail::Part.new
      message.html_part.content_type = 'text/html; charset=UTF-8'
      message.html_part.body = body_html

      message.delivery_method(:smtp, smtp_settings)
      message.deliver!
    end

    private

    attr_reader :company, :to, :cc, :bcc, :body_html

    def email_config
      company.email_config || raise(MissingConfiguration, "#{company.name} no tiene una bandeja de correo asignada.")
    end

    # `;` es el separador que ya usa SAP (`RcprCorreoElectronico`,
    # `companies.email_cc`) y el que arma `Sap::MailQueue`/`CheckSentDocumentsJob`.
    def addresses(raw)
      return [] if raw.blank?

      raw.split(';').map(&:strip).reject(&:blank?)
    end

    def smtp_settings
      {
        address: email_config.host,
        port: email_config.port,
        user_name: email_config.email,
        password: email_config.password,
        authentication: :plain,
        enable_starttls_auto: email_config.ssl
      }
    end
  end
end

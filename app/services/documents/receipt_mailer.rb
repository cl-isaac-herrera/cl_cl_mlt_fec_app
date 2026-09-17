# frozen_string_literal: true

module Documents
  # Envía el correo de recepción electrónica de un documento (aceptado o
  # rechazado por Hacienda) por la bandeja SMTP asignada a la compañía
  # (`Company#email_config`).
  #
  # El CONTENIDO lo arma `Documents::ReceiptMailBody`; acá solo se resuelve DE
  # DÓNDE sale el correo (la bandeja de la compañía) y se delega el armado
  # MIME + la entrega SMTP en `Clavisco::Common::Mailing::SmtpMailer`
  # (submódulo `common`) — esa mecánica ya no es específica de FEC: cualquier
  # producto Clavisco que mande correo transaccional con credenciales SMTP por
  # tenant la necesita igual.
  #
  # ⚠️ Sin PDF: la generación del PDF del comprobante (el legacy
  # `CLVS_FE.Mails/Common.cs#SendMail` la adjunta) queda pendiente — ver el
  # comentario de `SendElectronicReceiptJob`. Los XML (enviado y respuesta) SÍ
  # se adjuntan, vía `attachments:`.
  class ReceiptMailer
    # La compañía no tiene bandeja de correo asignada (`Company#email_config`).
    class MissingConfiguration < StandardError; end

    SUBJECT = 'Mensaje de recepción de documento electrónico'

    # @param company [Company] de acá sale la bandeja SMTP (`email_config`).
    # @param to [String] destinatario. Un solo correo (ver `Sap::MailQueue`,
    #   `U_OutputTo` ya trae solo la posición 0 del receptor).
    # @param body_html [String] cuerpo del mensaje.
    # @param body_text [String, nil] la alternativa en texto plano. Sin ella el
    #   mensaje va solo como HTML, lo que penaliza en los filtros de spam.
    # @param cc [String, nil] direcciones separadas por `;`.
    # @param bcc [String, nil] direcciones separadas por `;`.
    # @param subject [String]
    # @param inline_images [Hash{String=>String}] `cid` → ruta en disco. Cada
    #   entrada se incrusta como adjunto `inline` y queda referenciable desde el
    #   HTML como `<img src="cid:{cid}">`. Quien arma el HTML es quien decide
    #   qué va acá (`ReceiptMailBody#inline_images`).
    # @param attachments [Array<Hash>] `{ filename:, content:, mime_type: }` —
    #   los XML del comprobante, ver `SendElectronicReceiptJob`.
    def initialize(company:, to:, body_html:, body_text: nil, cc: nil, bcc: nil, subject: SUBJECT,
                   inline_images: {}, attachments: [])
      @company       = company
      @to            = to
      @cc            = cc
      @bcc           = bcc
      @subject       = subject
      @body_html     = body_html
      @body_text     = body_text
      @inline_images = inline_images
      @attachments   = attachments
    end

    # @raise [MissingConfiguration] sin bandeja de correo asignada.
    def call
      Clavisco::Common::Mailing::SmtpMailer.new(
        smtp: smtp_settings,
        from: email_config.from_header,
        to: to,
        cc: cc,
        bcc: bcc,
        subject: subject,
        body_html: body_html,
        body_text: body_text,
        inline_images: inline_images,
        attachments: attachments
      ).call
    end

    private

    attr_reader :company, :to, :cc, :bcc, :subject, :body_html, :body_text, :inline_images, :attachments

    def email_config
      company.email_config || raise(MissingConfiguration, "#{company.name} no tiene una bandeja de correo asignada.")
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

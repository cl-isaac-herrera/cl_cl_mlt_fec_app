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
  # ⚠️ Sin PDF: la generación del PDF del comprobante (el legacy
  # `CLVS_FE.Mails/Common.cs#SendMail` la adjunta) queda pendiente — ver el
  # comentario de `SendElectronicReceiptJob`. Los XML (enviado y respuesta) SÍ
  # se adjuntan, vía `attachments:`.
  class ReceiptMailer
    # La compañía no tiene bandeja de correo asignada (`Company#email_config`).
    class MissingConfiguration < StandardError; end

    SUBJECT = 'Mensaje de recepción de documento electrónico'

    # El `cid` con el que el logo queda embebido — `body_html` lo referencia
    # como `<img src="cid:logo">`, sin conocer la ruta del archivo en disco.
    LOGO_CID = 'logo'

    # @param company [Company] de acá sale la bandeja SMTP (`email_config`) y,
    #   si existe (`Attachments::LogoStore#readable_path`), el logo embebido.
    # @param to [String] destinatario. Un solo correo (ver `Sap::MailQueue`,
    #   `U_OutputTo` ya trae solo la posición 0 del receptor).
    # @param cc [String, nil] direcciones separadas por `;`.
    # @param bcc [String, nil] direcciones separadas por `;`.
    # @param body_html [String] cuerpo del mensaje.
    # @param attachments [Array<Hash>] `{ filename:, content:, mime_type: }` —
    #   los XML del comprobante, ver `SendElectronicReceiptJob`.
    def initialize(company:, to:, body_html:, cc: nil, bcc: nil, attachments: [])
      @company     = company
      @to          = to
      @cc          = cc
      @bcc         = bcc
      @body_html   = body_html
      @attachments = attachments
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

      # Adjuntos y logo ANTES del `html_part`: la gema `mail` arma
      # `multipart/mixed` (adjuntos) envolviendo `multipart/related` (inline)
      # envolviendo `multipart/alternative` (el cuerpo) solo si las partes se
      # agregan en ese orden — agregarlas después del `html_part` las deja
      # fuera de esa estructura y el cliente de correo no las muestra bien.
      attach_files(message)
      embed_logo(message)

      message.html_part = Mail::Part.new
      message.html_part.content_type = 'text/html; charset=UTF-8'
      message.html_part.body = body_html

      message.delivery_method(:smtp, smtp_settings)
      message.deliver!
    end

    private

    attr_reader :company, :to, :cc, :bcc, :body_html, :attachments

    def attach_files(message)
      attachments.each do |attachment|
        message.attachments[attachment.fetch(:filename)] = {
          mime_type: attachment.fetch(:mime_type),
          content: attachment.fetch(:content)
        }
      end
    end

    # Sin logo legible (compañía importada sin archivo local, o sin logo
    # cargado): no se agrega nada, y `body_html` no debe traer el `<img>`.
    def embed_logo(message)
      path = Attachments::LogoStore.new(company).readable_path
      return if path.nil?

      message.attachments.inline[LOGO_CID] = File.binread(path)
    end

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

# frozen_string_literal: true

module Documents
  # Envía el correo de recepción electrónica de un documento (aceptado o
  # rechazado por Hacienda) por la bandeja SMTP asignada a la compañía
  # (`Company#email_config`).
  #
  # El CONTENIDO lo arma `Documents::ReceiptMailBody`; acá solo se ensambla el
  # mensaje MIME y se entrega.
  #
  # No usa ActionMailer: esta app carga Rails a la carta
  # (`config/application.rb` no requiere `action_mailer/railtie`), y lo único
  # que hace falta acá es un mensaje puntual con credenciales SMTP DISTINTAS
  # por compañía — la gema `mail` (Gemfile) alcanza sin la capa completa de
  # ActionMailer (vistas, layouts, previews, config global de entrega), que no
  # aplica a un solo mensaje por fila de la cola.
  #
  # ⚠️ Sin PDF: la generación del PDF del comprobante (el legacy
  # `CLVS_FE.Mails/Common.cs#SendMail` la adjunta) queda pendiente — ver el
  # comentario de `SendElectronicReceiptJob`. Los XML (enviado y respuesta) SÍ
  # se adjuntan, vía `attachments:`.
  class ReceiptMailer
    # La compañía no tiene bandeja de correo asignada (`Company#email_config`).
    class MissingConfiguration < StandardError; end

    SUBJECT = 'Mensaje de recepción de documento electrónico'

    # Los formatos que puede tener una imagen incrustada: los tres que acepta
    # `Attachments::LogoStore` para el logo de la compañía, más el PNG del pie.
    # El tipo se declara explícitamente y NO se deduce del nombre del archivo
    # dentro de la gema — ver `#inline_image_part`.
    IMAGE_MIME_TYPES = { '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg' }.freeze

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
      # `Mail.new do … end` evalúa el bloque CONTRA el mensaje (`instance_eval`),
      # así que ahí adentro `self` es el `Mail::Message` y no esta instancia —
      # `email_config`/`addresses` no se podrían llamar dentro de ese bloque.
      # Armar el mensaje con asignaciones evita ese problema.
      message = Mail.new
      message.from    = email_config.from_header
      message.to      = addresses(to)
      message.cc      = addresses(cc)  if cc.present?
      message.bcc     = addresses(bcc) if bcc.present?
      message.subject = subject

      # El cuerpo (con sus imágenes incrustadas) primero y los adjuntos después:
      # así quedan como hermanos dentro del `multipart/mixed` que arma la gema,
      # con el cuerpo de primero — que es el orden en que un cliente de correo
      # espera encontrarlos.
      message.add_part(content_part)
      attach_files(message)

      message.delivery_method(:smtp, smtp_settings)
      message.deliver!
    end

    private

    attr_reader :company, :to, :cc, :bcc, :subject, :body_html, :body_text, :inline_images, :attachments

    # La estructura que termina armando esto, con logo y adjuntos:
    #
    #   multipart/mixed
    #   ├── multipart/related
    #   │   ├── multipart/alternative
    #   │   │   ├── text/plain
    #   │   │   └── text/html
    #   │   └── image/png  (inline, Content-ID: <company-logo>)
    #   ├── application/xml
    #   └── application/xml
    #
    # Las imágenes incrustadas tienen que ir en un `multipart/related` JUNTO al
    # HTML que las referencia; colgadas del `multipart/mixed`, al lado de los
    # adjuntos, Outlook no resuelve los `cid:` y las pinta como imagen rota.
    def content_part
      return alternative_part if inline_images.empty?

      related = Mail::Part.new
      related.content_type = 'multipart/related'
      related.add_part(alternative_part)
      inline_images.each { |cid, path| related.add_part(inline_image_part(cid, path)) }
      related
    end

    # `multipart/alternative` con el texto plano PRIMERO: el orden lo fija el
    # RFC 2046 §5.1.4 — de peor a mejor —, y el cliente muestra la última parte
    # que sabe pintar. Al revés, un cliente que entiende las dos mostraría el
    # texto plano.
    def alternative_part
      return html_part if body_text.blank?

      alternative = Mail::Part.new
      alternative.content_type = 'multipart/alternative'
      alternative.add_part(text_part)
      alternative.add_part(html_part)
      alternative
    end

    def html_part
      part = Mail::Part.new
      part.content_type = 'text/html; charset=UTF-8'
      part.body = body_html
      part
    end

    def text_part
      part = Mail::Part.new
      part.content_type = 'text/plain; charset=UTF-8'
      part.body = body_text
      part
    end

    # Una imagen incrustada, referenciable desde el HTML como `cid:{cid}`.
    #
    # ⚠️ Tres detalles que parecen de estilo y NO lo son — cada uno rompe la
    # imagen por su lado, y los tres estaban mal antes de este cambio:
    #
    # 1. `content_id` va con los ángulos (`<logo>`) y explícito. Sin asignarlo,
    #    la gema genera uno aleatorio (`<6aa46063…@HOST.mail>`) al serializar, y
    #    el `cid:logo` del HTML no le apunta a nada: el cliente muestra el ícono
    #    de imagen rota con el `alt`.
    # 2. El `content_type` se declara acá. Deducirlo del nombre del adjunto solo
    #    funciona si el nombre trae extensión: con `logo` a secas la gema decide
    #    `text/plain`, y ningún cliente pinta como imagen una parte que dice ser
    #    texto.
    # 3. NO se toca `content_transfer_encoding`. Fijarlo en `base64` a mano hace
    #    que la gema interprete el body como si YA viniera codificado y lo
    #    decodifique: los bytes del PNG salen convertidos en basura, sin ningún
    #    error. Sola elige `base64` para binario y los preserva intactos.
    def inline_image_part(cid, path)
      file_name = File.basename(path)

      part = Mail::Part.new
      part.content_type        = "#{image_mime_type(path)}; name=\"#{file_name}\""
      part.content_disposition = "inline; filename=\"#{file_name}\""
      part.content_id          = "<#{cid}>"
      part.body                = File.binread(path)
      part
    end

    def image_mime_type(path)
      IMAGE_MIME_TYPES.fetch(File.extname(path).downcase, 'application/octet-stream')
    end

    def attach_files(message)
      attachments.each do |attachment|
        message.attachments[attachment.fetch(:filename)] = {
          mime_type: attachment.fetch(:mime_type),
          content: attachment.fetch(:content)
        }
      end
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

# frozen_string_literal: true

module Documents
  # Arma el cuerpo del correo de recepción electrónica: la versión HTML (el
  # diseño, en `app/views/documents/receipt_mail.html.erb`), la versión en texto
  # plano y la lista de imágenes que el HTML referencia por `cid:`.
  #
  #   rendered = Documents::ReceiptMailBody.new(company: company, doc_type: '01', info: info).call
  #   rendered.html           # => "<!DOCTYPE html>…"
  #   rendered.text           # => "ACME S.A.\n\nSu comprobante…"
  #   rendered.inline_images  # => { 'company-logo' => 'C:/…/logo.png', 'clavisco-logo' => '…' }
  #
  # ── Por qué `inline_images` sale de acá y no del mailer ──────────────────
  # El HTML es el único que sabe qué `cid:` terminó referenciando: si la
  # compañía no tiene logo legible, el `<img>` del encabezado no se emite y no
  # hay nada que incrustar. Antes el mailer decidía por su cuenta si adjuntaba
  # el logo y el cuerpo asumía que lo había hecho — dos decisiones que tenían
  # que coincidir, tomadas en archivos distintos. Acá se toma UNA vez: quien
  # escribe el `<img src="cid:x">` es quien declara `x` en `inline_images`, y
  # el mailer se limita a incrustar lo que se le pasa.
  #
  # No usa ActionMailer por lo mismo que `ReceiptMailer` (ver ahí): la app carga
  # Rails a la carta y no incluye `action_mailer/railtie`. ERB alcanza.
  class ReceiptMailBody
    TEMPLATE_PATH = Rails.root.join('app/views/documents/receipt_mail.html.erb')

    # El logo de Clavisco del pie. Va en `app/assets/images` —y se lee por su
    # ruta en el repo, no por la URL del asset pipeline— porque el correo lo
    # incrusta como adjunto `inline` (`cid:`) y no como una imagen remota: un
    # `<img src="https://…">` lo bloquea por defecto casi todo cliente de
    # correo, que es justamente el problema que se está arreglando.
    #
    # Al venir del repositorio, viaja con cada deploy y no depende de que
    # alguien lo copie al servidor (a diferencia del logo de la COMPAÑÍA, que sí
    # es un archivo por instalación — `CLAUDE.md` §34).
    FOOTER_LOGO_PATH = Rails.root.join('app/assets/images/email-footer-logo.png')

    COMPANY_LOGO_CID = 'company-logo'
    FOOTER_LOGO_CID  = 'clavisco-logo'

    # El logo de la compañía se escala para caber en esta caja. Las dos medidas
    # se emiten como atributos `width`/`height` del `<img>` porque Outlook (motor
    # de Word) ignora `max-width`/`max-height` de CSS: sin ellos, un logo de
    # 1080 px de ancho se pinta a tamaño completo y rompe la tarjeta.
    LOGO_MAX_WIDTH  = 200
    LOGO_MAX_HEIGHT = 48

    # El logo del pie sí tiene medidas conocidas (1080×108, relación 10:1), así
    # que no hace falta medirlo en tiempo de ejecución. Las dos tienen que
    # mantener esa relación: son los atributos `width`/`height` del `<img>`, y
    # descuadrarlas deforma la imagen en Outlook.
    FOOTER_LOGO_WIDTH  = 200
    FOOTER_LOGO_HEIGHT = 20

    ACCEPTED = { label: 'Aceptado', bg: '#e8f5ee', fg: '#3a7d52' }.freeze
    REJECTED = { label: 'Rechazado', bg: '#fdecea', fg: '#c0392b' }.freeze

    Rendered = Data.define(:subject, :html, :text, :inline_images)

    # @param company [Company]
    # @param doc_type [String] código de Hacienda del documento.
    # @param info [Documents::Row] lo que trajo `Sap::MailDocumentInfo`.
    def initialize(company:, doc_type:, info:)
      @company  = company
      @doc_type = doc_type
      @info     = info
    end

    # @return [Rendered]
    def call
      Rendered.new(subject: subject, html: html, text: text, inline_images: inline_images)
    end

    private

    attr_reader :company, :doc_type, :info

    # El asunto dice el desenlace y de cuál comprobante, que es lo que se
    # necesita para encontrar el correo después en la bandeja. El remitente ya
    # identifica a la compañía, así que no se repite acá.
    def subject
      consecutivo = info.string('U_CL_FEC_NumConsecutivo')
      base        = "Comprobante electrónico #{status[:label].downcase} por Hacienda"

      consecutivo.present? ? "#{base} · #{consecutivo}" : base
    end

    def html
      ERB.new(TEMPLATE_PATH.read, trim_mode: '-').result(binding)
    end

    # La alternativa en texto plano. No es opcional ni decorativa: un mensaje
    # `text/html` sin parte `text/plain` puntúa peor en los filtros de spam, y
    # este correo es transaccional — tiene que llegar.
    def text
      rows  = details
      rows += [['Monto', "#{amount[:value]} #{amount[:currency]}".strip]] if amount
      rows += [['Clave numérica', clave]] if clave.present?
      width = rows.map { |label, _| label.length }.max.to_i

      lines  = [issuer, '', headline.upcase, '', lead, '']
      lines += rows.map { |label, value| "#{label.ljust(width)} : #{value}" }
      lines += ['', attachments_note] if attachments_note
      lines += ['', 'Este es un mensaje automático, por favor no responda.', 'Facturación electrónica — Clavisco']

      lines.join("\n")
    end

    # Solo los `cid:` que el HTML realmente emitió. El del pie siempre está (es
    # del repo); el de la compañía, únicamente si hay un archivo legible.
    def inline_images
      images = { FOOTER_LOGO_CID => FOOTER_LOGO_PATH.to_s }
      images[COMPANY_LOGO_CID] = company_logo_path if company_logo_path
      images
    end

    def company_logo_path
      return @company_logo_path if defined?(@company_logo_path)

      @company_logo_path = Attachments::LogoStore.new(company).readable_path
    end

    # ── Datos del comprobante ────────────────────────────────────────────────

    def issuer
      company.email_sender_name
    end

    def accepted?
      info.integer('U_CL_FEC_Status') == Sap::MailDocumentInfo::ACCEPTED_STATUS
    end

    def status
      accepted? ? ACCEPTED : REJECTED
    end

    def headline
      accepted? ? 'Su comprobante electrónico fue aceptado' : 'Su comprobante electrónico fue rechazado'
    end

    def lead
      verb = accepted? ? 'aceptó' : 'rechazó'

      "#{issuer} le informa que el Ministerio de Hacienda #{verb} el siguiente comprobante electrónico."
    end

    # Las filas del detalle, ya formateadas y sin las que no tienen valor: una
    # celda vacía en el correo se lee como un dato que se perdió.
    #
    # La clave NO está acá: son 50 dígitos que no caben en una fila de dos
    # columnas sin desbordar el ancho del correo, así que la plantilla la pinta
    # aparte, a lo ancho y en monoespaciada.
    def details
      [
        ['Tipo de documento', DocType.label(doc_type)],
        ['Consecutivo', info.string('U_CL_FEC_NumConsecutivo')],
        ['Fecha de emisión', emission_date],
        ['Receptor', info.string('CardName')]
      ].reject { |_, value| value.blank? }
    end

    def clave
      info.string('U_CL_FEC_Clave')
    end

    # `U_CL_FEC_FechaEmision` llega como texto de SAP, en ISO
    # (`2026-09-06T09:06:00Z`). Se reescribe al formato de `CLAUDE.md` §5
    # (`yyyy-MM-dd HH:mm:ss`) tomando los dígitos tal cual, SIN convertir de
    # zona horaria: el sufijo `Z` del UDF no significa que el dato esté en UTC
    # —lo escribe SAP con la hora local del documento— y convertirlo correría la
    # hora seis horas, o el día entero en un comprobante de la madrugada.
    def emission_date
      raw = info.string('U_CL_FEC_FechaEmision')
      return nil if raw.blank?

      match = raw.match(/\A(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}:\d{2}))?/)
      return raw if match.nil?

      [match[1], match[2]].compact.join(' ')
    end

    def amount
      total = info.decimal('DocTotal')
      return nil if total.nil?

      formatted = ActiveSupport::NumberHelper.number_to_currency(total, unit: '', precision: 2, format: '%n')

      { value: formatted.strip, currency: info.string('DocCurrency').to_s.strip }
    end

    def attachments_note
      return nil if clave.blank?

      'Se adjuntan el comprobante electrónico y el mensaje de respuesta de Hacienda, en formato XML.'
    end

    # ── Helpers de la plantilla ──────────────────────────────────────────────

    # El logo de la compañía escalado a `LOGO_MAX_WIDTH`×`LOGO_MAX_HEIGHT`
    # conservando la proporción. `nil` si no se pudieron leer las medidas, y ahí
    # la plantilla emite el `<img>` sin `width`/`height` — se ve peor en Outlook,
    # pero se ve.
    def company_logo_size
      return nil if company_logo_path.nil?

      width, height = Images::Dimensions.of(company_logo_path)
      return nil if width.nil? || height.nil? || width.zero? || height.zero?

      scale = [LOGO_MAX_WIDTH.fdiv(width), LOGO_MAX_HEIGHT.fdiv(height), 1.0].min

      { width: (width * scale).round, height: (height * scale).round }
    end

    # Los `cid:` se exponen como métodos y no se referencian como constantes
    # desde la plantilla: el ERB se evalúa con `binding`, y la resolución de
    # constantes ahí adentro no es la del cuerpo de esta clase.
    def company_logo_cid
      COMPANY_LOGO_CID
    end

    def footer_logo_cid
      FOOTER_LOGO_CID
    end

    def footer_logo_width
      FOOTER_LOGO_WIDTH
    end

    def footer_logo_height
      FOOTER_LOGO_HEIGHT
    end

    def h(value)
      ERB::Util.html_escape(value)
    end
  end
end

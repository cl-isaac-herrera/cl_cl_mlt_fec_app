# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::ReceiptMailer do
  let(:email_config) do
    EmailConfig.create!(email: 'facturas@acme.test', password: 's3cr3t', host: 'smtp.acme.test', port: 587,
                        ssl: true, sender_address: 'Facturación Electrónica')
  end
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', email_config: email_config) }

  # `#call` entrega con `Mail::Message#deliver!`, sobre un objeto que arma
  # `Mail.new` adentro del método: no hay forma de inyectarlo desde afuera. Se
  # intercepta la entrega para no intentar una conexión SMTP real y se captura
  # el mensaje para inspeccionar cómo quedó armado.
  def capture_delivery
    sent = nil
    allow_any_instance_of(Mail::Message).to receive(:deliver!) { |message| sent = message }
    yield
    sent
  end

  it 'levanta MissingConfiguration si la compañía no tiene bandeja asignada' do
    company.update!(email_config: nil)
    mailer = described_class.new(company: company, to: 'x@test.com', body_html: '<p>hola</p>')

    expect { mailer.call }.to raise_error(described_class::MissingConfiguration, /no tiene una bandeja de correo/)
  end

  it 'arma el remitente con el nombre visible y el correo real de la bandeja' do
    message = capture_delivery do
      described_class.new(company: company, to: 'cliente@test.com', body_html: '<p>hola</p>').call
    end

    from_address = message.header[:from].addrs.first
    expect(from_address.address).to eq('facturas@acme.test')
    expect(from_address.display_name).to eq('Facturación Electrónica')
  end

  it 'manda el destinatario y el asunto fijo' do
    message = capture_delivery do
      described_class.new(company: company, to: 'cliente@test.com', body_html: '<p>hola</p>').call
    end

    expect(message.to).to eq(['cliente@test.com'])
    expect(message.subject).to eq(described_class::SUBJECT)
  end

  it 'separa Cc y Bcc por punto y coma' do
    message = capture_delivery do
      described_class.new(company: company, to: 'a@test.com', cc: 'b@test.com;c@test.com', bcc: 'd@test.com',
                          body_html: '<p>hola</p>').call
    end

    expect(message.cc).to eq(['b@test.com', 'c@test.com'])
    expect(message.bcc).to eq(['d@test.com'])
  end

  it 'no agrega Cc ni Bcc cuando no vienen' do
    message = capture_delivery do
      described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>').call
    end

    expect(message.cc).to be_nil
    expect(message.bcc).to be_nil
  end

  it 'usa el cuerpo HTML recibido, sin adjuntos ni logo (la compañía no tiene uno)' do
    message = capture_delivery do
      described_class.new(company: company, to: 'a@test.com', body_html: '<p>contenido</p>').call
    end

    expect(message.html_part.body.to_s).to eq('<p>contenido</p>')
    expect(message.attachments).to be_empty
  end

  describe 'adjuntos' do
    it 'agrega los archivos de attachments: con su mime_type' do
      message = capture_delivery do
        described_class.new(
          company: company, to: 'a@test.com', body_html: '<p>hola</p>',
          attachments: [{ filename: 'comprobante-506.xml', mime_type: 'application/xml', content: '<Factura/>' }]
        ).call
      end

      attachment = message.attachments.find { |a| a.filename == 'comprobante-506.xml' }
      expect(attachment).not_to be_nil
      expect(attachment.content_type).to include('application/xml')
      expect(attachment.body.to_s).to eq('<Factura/>')
    end
  end

  describe 'imágenes incrustadas' do
    # Bytes que NO sobreviven a un round-trip mal codificado: el PNG de prueba
    # lleva el rango completo 0x00–0xFF justamente para que una corrupción se
    # note (ver el tercer ejemplo).
    let(:png_bytes) { [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + (0..255).to_a.pack('C*') }
    let(:logo_path) { Rails.root.join('tmp/receipt_mailer_spec_logo.png') }

    before { logo_path.binwrite(png_bytes) }
    after  { logo_path.delete if logo_path.exist? }

    def deliver_with_logo
      capture_delivery do
        described_class.new(company: company, to: 'a@test.com', body_html: '<p><img src="cid:logo"></p>',
                            inline_images: { 'logo' => logo_path.to_s }).call
      end
    end

    # El defecto original: sin `content_id` explícito la gema genera uno
    # aleatorio al serializar (`<6aa46063…@HOST.mail>`) y el `cid:logo` del HTML
    # no le apunta a nada — el cliente muestra el ícono de imagen rota.
    it 'le pone al adjunto el Content-ID que el HTML referencia' do
      inline = Mail.read_from_string(deliver_with_logo.to_s).attachments.find(&:inline?)

      expect(inline.content_id).to eq('<logo>')
      expect(inline.url).to eq('cid:logo')
    end

    # Sin esto la gema deduce el tipo del nombre del adjunto y, con un nombre
    # sin extensión, decide `text/plain`: ningún cliente pinta como imagen una
    # parte que dice ser texto.
    it 'declara el tipo de la imagen según su extensión' do
      inline = Mail.read_from_string(deliver_with_logo.to_s).attachments.find(&:inline?)

      expect(inline.content_type).to start_with('image/png')
      expect(inline.inline?).to be(true)
    end

    # Fijar `content_transfer_encoding` a mano hace que la gema tome el body
    # como si YA viniera codificado y lo decodifique: los bytes salen
    # convertidos en basura, sin ningún error.
    it 'preserva los bytes de la imagen intactos' do
      inline = Mail.read_from_string(deliver_with_logo.to_s).attachments.find(&:inline?)

      expect(inline.body.decoded.b).to eq(png_bytes)
    end

    # Las imágenes incrustadas tienen que quedar en un `multipart/related` junto
    # al HTML que las referencia. Colgadas del `multipart/mixed`, al lado de los
    # adjuntos, Outlook no resuelve los `cid:`.
    it 'arma multipart/related con el cuerpo y la imagen adentro' do
      message = capture_delivery do
        described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>', body_text: 'hola',
                            inline_images: { 'logo' => logo_path.to_s },
                            attachments: [{ filename: 'x.xml', mime_type: 'application/xml', content: '<X/>' }]).call
      end

      expect(message.mime_type).to eq('multipart/mixed')
      expect(message.parts.map(&:mime_type)).to eq(['multipart/related', 'application/xml'])

      related = message.parts.first
      expect(related.parts.map(&:mime_type)).to eq(['multipart/alternative', 'image/png'])
      expect(related.parts.first.parts.map(&:mime_type)).to eq(['text/plain', 'text/html'])
    end

    it 'no agrega nada cuando no se le pasan imágenes' do
      message = capture_delivery do
        described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>').call
      end

      expect(message.attachments).to be_empty
    end
  end

  describe 'alternativa en texto plano' do
    it 'agrega la parte de texto antes de la de HTML' do
      message = capture_delivery do
        described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>', body_text: 'hola').call
      end

      alternative = message.parts.first
      expect(alternative.mime_type).to eq('multipart/alternative')
      # El orden lo fija el RFC 2046 §5.1.4: de peor a mejor. Al revés, un
      # cliente que entiende las dos mostraría el texto plano.
      expect(alternative.parts.map(&:mime_type)).to eq(['text/plain', 'text/html'])
      expect(message.text_part.body.to_s).to eq('hola')
      expect(message.html_part.body.to_s).to eq('<p>hola</p>')
    end

    it 'manda solo HTML cuando no se le pasa texto' do
      message = capture_delivery do
        described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>').call
      end

      expect(message.all_parts.map(&:mime_type)).to eq(['text/html'])
    end
  end

  it 'usa el asunto recibido cuando se le pasa uno' do
    message = capture_delivery do
      described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>',
                          subject: 'Comprobante electrónico aceptado por Hacienda · 001').call
    end

    expect(message.subject).to eq('Comprobante electrónico aceptado por Hacienda · 001')
  end

  it 'entrega por SMTP con las credenciales de la bandeja de la compañía' do
    message = capture_delivery do
      described_class.new(company: company, to: 'a@test.com', body_html: '<p>hola</p>').call
    end

    expect(message.delivery_method).to be_a(Mail::SMTP)
    expect(message.delivery_method.settings).to include(
      address: 'smtp.acme.test', port: 587, user_name: 'facturas@acme.test', password: 's3cr3t',
      authentication: :plain, enable_starttls_auto: true
    )
  end
end

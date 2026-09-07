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

  it 'usa el cuerpo HTML recibido, sin adjuntos' do
    message = capture_delivery do
      described_class.new(company: company, to: 'a@test.com', body_html: '<p>contenido</p>').call
    end

    expect(message.html_part.body.to_s).to eq('<p>contenido</p>')
    expect(message.attachments).to be_empty
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

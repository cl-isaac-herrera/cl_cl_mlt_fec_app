# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SendElectronicReceiptJob do
  let(:connection) do
    Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/',
                       sap_license: 'licencia', sap_license_password: 'secreto')
  end
  let!(:company) do
    Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id)
  end
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }
  let(:mail_row) { Documents::Row.new('Code' => '7', 'U_OutputTo' => 'cliente@test.com', 'U_OutputCC' => nil) }
  let(:mail_queue) { instance_double(Sap::MailQueue, find: mail_row, update_status: nil) }
  let(:mailer) { instance_double(Documents::ReceiptMailer, call: nil) }

  before do
    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    allow(Sap::MailQueue).to receive(:new).and_return(mail_queue)
    allow(Documents::ReceiptMailer).to receive(:new).and_return(mailer)
    allow(Documents::MailQueue).to receive(:mark)
  end

  def queue(*entries)
    allow(Documents::MailQueue).to receive(:pending).and_return(entries)
  end

  def entry(id: 1, doc_entry: 25, doc_type: DocType::FE, sap_db: 'SBO_ACME')
    Documents::MailQueue::Entry.new(id: id, doc_entry: doc_entry, doc_type: doc_type, sap_db: sap_db)
  end

  describe 'cola vacía' do
    it 'no toca SAP' do
      queue

      described_class.perform_now

      expect(Sap::CompanyClient).not_to have_received(:for)
    end
  end

  describe 'envío exitoso' do
    it 'busca el detalle en la UDT por DocEntry y DocType' do
      queue(entry)

      described_class.perform_now

      expect(mail_queue).to have_received(:find).with(doc_entry: 25, doc_type: DocType::FE)
    end

    it 'envía el correo con los destinatarios de la UDT' do
      queue(entry)

      described_class.perform_now

      expect(Documents::ReceiptMailer).to have_received(:new)
        .with(company: company, to: 'cliente@test.com', cc: nil, bcc: nil, body_html: anything)
      expect(mailer).to have_received(:call)
    end

    it 'marca Enviado en la UDT y en la cola externa' do
      queue(entry)

      described_class.perform_now

      expect(mail_queue).to have_received(:update_status)
        .with(code: '7', status: Documents::MailQueue::STATUS_SENT, details: nil, email: anything)
      expect(Documents::MailQueue).to have_received(:mark)
        .with(entry, status: Documents::MailQueue::STATUS_SENT)
    end
  end

  describe 'sin compañía configurada' do
    it 'marca Error en la cola externa, sin tocar SAP' do
      queue(entry(sap_db: 'SBO_FANTASMA'))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Documents::MailQueue).to have_received(:mark)
        .with(anything, status: Documents::MailQueue::STATUS_ERROR)
      expect(Sap::CompanyClient).not_to have_received(:for)
    end
  end

  describe 'sin fila en la UDT' do
    it 'marca Error en la cola externa' do
      queue(entry)
      allow(mail_queue).to receive(:find).and_return(nil)
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(mailer).not_to have_received(:call)
      expect(Documents::MailQueue).to have_received(:mark)
        .with(entry, status: Documents::MailQueue::STATUS_ERROR)
    end
  end

  describe 'sin bandeja de correo asignada' do
    it 'marca Error en la UDT y en la cola externa' do
      queue(entry)
      allow(mailer).to receive(:call)
        .and_raise(Documents::ReceiptMailer::MissingConfiguration, 'ACME S.A. no tiene una bandeja de correo asignada.')
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(mail_queue).to have_received(:update_status)
        .with(code: '7', status: Documents::MailQueue::STATUS_ERROR, details: /no tiene una bandeja/, email: nil)
      expect(Documents::MailQueue).to have_received(:mark)
        .with(entry, status: Documents::MailQueue::STATUS_ERROR)
    end
  end

  describe 'un error inesperado al enviar' do
    it 'marca Error en los dos lados y sigue con el resto de la cola' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))
      call_count = 0
      allow(mailer).to receive(:call) do
        call_count += 1
        raise 'SMTP rechazó la conexión' if call_count == 1
      end
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error

      expect(Sentry).to have_received(:capture_exception).once
      expect(Documents::MailQueue).to have_received(:mark)
        .with(anything, status: Documents::MailQueue::STATUS_ERROR).once
      expect(Documents::MailQueue).to have_received(:mark)
        .with(anything, status: Documents::MailQueue::STATUS_SENT).once
    end
  end

  describe 'base de documentos sin configurar' do
    it 'avisa y termina sin fallar' do
      allow(Documents::MailQueue).to receive(:pending).and_raise(ExternalDb::ConfigurationError, 'Faltan ajustes')
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/sin conexión a la base de documentos/)
    end

    it 'deja fallar cuando la base no responde' do
      allow(Documents::MailQueue).to receive(:pending).and_raise(ExternalDb::ConnectionError, 'servidor caído')

      expect { described_class.perform_now }.to raise_error(ExternalDb::ConnectionError)
    end
  end
end

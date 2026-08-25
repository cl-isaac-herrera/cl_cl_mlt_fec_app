# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SyncIssuedDocumentsJob do
  let(:connection) do
    Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/',
                       sap_license: 'licencia', sap_license_password: 'secreto')
  end
  let!(:company) do
    Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id)
  end
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  before do
    filter = '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)'
    %w[HEADER LINES OTHER_CHARGES PAYMENT_METHODS REFERENCES OTHERS].each do |name|
      SlResource.create!(code: Sap::DocumentDetails.const_get(name),
                         resource: "view.svc/#{name}_B1SLQuery", query_params: filter, page_size: 0)
    end

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    allow(client).to receive(:get) { |path| path.match?(/HEADER/) ? [{ 'Clave' => '506123' }] : [] }
  end

  def queue(*entries)
    allow(Documents::PendingQueue).to receive(:pending).and_return(entries)
  end

  def entry(id: 1, doc_entry: 25, doc_type: DocType::FE, sap_db: 'SBO_ACME')
    Documents::PendingQueue::Entry.new(id: id, doc_entry: doc_entry, doc_type: doc_type, sap_db: sap_db)
  end

  describe 'cola vacía' do
    it 'no toca SAP' do
      queue

      described_class.perform_now

      expect(Sap::CompanyClient).not_to have_received(:for)
    end
  end

  describe 'documento procesable' do
    it 'consulta el detalle y arma el objeto unificado' do
      queue(entry)
      allow(Documents::UnifiedBuilder).to receive(:new).and_call_original

      described_class.perform_now

      expect(Documents::UnifiedBuilder).to have_received(:new)
        .with(hash_including(company: company, doc_type: '01'))
    end

    # Una sesión de SAP por compañía, no una por documento: el pool del Client
    # indexa por compañía y `Sap::CompanyClient.for` revalida la configuración.
    it 'reutiliza el client entre documentos de la misma compañía' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))

      described_class.perform_now

      expect(Sap::CompanyClient).to have_received(:for).once
    end
  end

  describe 'aislamiento de errores' do
    # Un documento que falla no puede dejar sin procesar a los que siguen.
    it 'sigue con el resto cuando uno revienta' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))
      call_count = 0
      allow(client).to receive(:get) do |path|
        call_count += 1
        raise 'SAP se cayó' if call_count == 1

        path.match?(/HEADER/) ? [{ 'Clave' => '506123' }] : []
      end
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error
      expect(Sentry).to have_received(:capture_exception).once
    end

    it 'omite el documento cuyo tipo no conoce' do
      queue(entry(doc_type: '99'))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(/tipo de documento desconocido/)
      expect(Sap::CompanyClient).not_to have_received(:for)
    end

    it 'omite el documento de una base de SAP sin compañía configurada' do
      queue(entry(sap_db: 'SBO_FANTASMA'))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(/no hay compañía activa con sap_db/)
    end

    it 'omite la compañía sin credenciales de licencia sin tratarlo como error' do
      queue(entry)
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'faltan credenciales')
      allow(Rails.logger).to receive(:warn)
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(/faltan credenciales/)
      expect(Sentry).not_to have_received(:capture_exception)
    end
  end

  describe 'base de documentos sin configurar' do
    # Corre cada dos minutos: dejarla fallar acumularía una ejecución fallida y un
    # evento en Sentry cada dos minutos, para siempre.
    it 'avisa y termina sin fallar' do
      allow(Documents::PendingQueue).to receive(:pending)
        .and_raise(ExternalDb::ConfigurationError, 'Faltan ajustes')
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/sin conexión a la base de documentos/)
    end

    # Una base caída sí es un fallo: la ejecución fallida es la señal correcta.
    it 'deja fallar cuando la base no responde' do
      allow(Documents::PendingQueue).to receive(:pending)
        .and_raise(ExternalDb::ConnectionError, 'servidor caído')

      expect { described_class.perform_now }.to raise_error(ExternalDb::ConnectionError)
    end
  end
end

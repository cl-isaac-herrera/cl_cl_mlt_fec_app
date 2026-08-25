# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::CompanyClient do
  let(:connection) do
    Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/',
                       sap_license: 'licencia', sap_license_password: 'secreto')
  end
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id) }

  describe '.for' do
    it 'arma el client con la URL de la conexión y la base de la compañía' do
      client = described_class.for(company)

      expect(client.base_url).to include('sap.test')
      expect(client.session_key).to include('SBO_ACME')
    end

    # Las credenciales salen de la CONEXIÓN y no de `users.sap_user`: el job corre
    # sin `Current.user`. Ver la migración 20260825140000.
    it 'usa las credenciales de licencia de la conexión' do
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_call_original

      described_class.for(company)

      expect(Clavisco::ServiceLayer::Client).to have_received(:new)
        .with(hash_including(username: 'licencia', password: 'secreto'))
    end

    # El pool del Client indexa por `owner|company_db|username`. Con un owner
    # constante, todos los documentos de una compañía reutilizan un solo /Login
    # (CLAVISCO-PLATFORM-STANDARDS §2.7); con un UUID por llamada se gastaría una
    # licencia de SAP por documento.
    it 'comparte la sesión entre llamadas de la misma compañía' do
      expect(described_class.for(company).session_key).to eq(described_class.for(company).session_key)
    end

    it 'separa la sesión de dos compañías del mismo servidor' do
      otra = Company.create!(name: 'Otra', sap_db: 'SBO_OTRA', connection_id: connection.id)

      expect(described_class.for(company).session_key).not_to eq(described_class.for(otra).session_key)
    end
  end

  # Todos estos cortan ANTES de hablar con SAP: es configuración que falta, no un
  # rechazo del Service Layer. El mensaje nombra la compañía porque lo va a leer
  # alguien revisando por qué una compañía no emitió.
  describe 'configuración incompleta' do
    it 'avisa cuando la compañía no tiene conexión' do
      company.update!(connection_id: nil)

      expect { described_class.for(company) }
        .to raise_error(described_class::MissingConfiguration, /no tiene una conexión de SAP/)
    end

    it 'avisa cuando la compañía no tiene base de SAP' do
      company.update!(sap_db: nil)

      expect { described_class.for(company) }
        .to raise_error(described_class::MissingConfiguration, /no tiene base de datos de SAP/)
    end

    it 'avisa cuando la conexión no tiene credenciales de licencia' do
      connection.update!(sap_license: nil, sap_license_password: nil)

      expect { described_class.for(company.reload) }
        .to raise_error(described_class::MissingConfiguration, /credenciales de licencia/)
    end

    # Medio configurada es peor que sin configurar: SAP rechazaría el login y el
    # error se leería como "credenciales inválidas" en vez de "faltó llenarlas".
    it 'exige las dos mitades de la credencial' do
      connection.update!(sap_license: 'licencia', sap_license_password: nil)

      expect { described_class.for(company.reload) }
        .to raise_error(described_class::MissingConfiguration, /credenciales de licencia/)
    end

    it 'incluye el nombre y el id de la compañía en el mensaje' do
      company.update!(connection_id: nil)

      expect { described_class.for(company) }
        .to raise_error(/ACME S.A.*id #{company.id}/)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::UserClient do
  let(:connection) { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/') }
  let(:company)    { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id) }
  let(:user) do
    User.create!(email: 'ana@example.com', sap_user: 'ana.sap', sap_password: 'secreto')
  end

  describe '.for' do
    it 'arma el client con la URL de la conexión y la base de la compañía' do
      client = described_class.for(company, user: user)

      expect(client.base_url).to include('sap.test')
      expect(client.session_key).to include('SBO_ACME')
    end

    # Las credenciales salen del USUARIO y no de la conexión: a diferencia de
    # `Sap::CompanyClient` (procesos de fondo sin `Current.user`), acá SÍ hay
    # una persona detrás del click y su acción en SAP debe poder atribuírsele.
    it 'usa las credenciales propias del usuario, no las de licencia de la conexión' do
      connection.update!(sap_license: 'licencia', sap_license_password: 'otro-secreto')
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_call_original

      described_class.for(company, user: user)

      expect(Clavisco::ServiceLayer::Client).to have_received(:new)
        .with(hash_including(username: 'ana.sap', password: 'secreto'))
    end

    # El pool del Client indexa por `owner|company_db|username`. Con un owner
    # estable por PERSONA, las acciones de un mismo usuario sobre la misma
    # compañía reutilizan un solo /Login (CLAVISCO-PLATFORM-STANDARDS §2.7).
    it 'comparte la sesión entre llamadas del mismo usuario' do
      expect(described_class.for(company, user: user).session_key)
        .to eq(described_class.for(company, user: user).session_key)
    end

    it 'separa la sesión de dos usuarios distintos sobre la misma compañía' do
      otro = User.create!(email: 'beto@example.com', sap_user: 'beto.sap', sap_password: 'secreto2')

      expect(described_class.for(company, user: user).session_key)
        .not_to eq(described_class.for(company, user: otro).session_key)
    end
  end

  # Todos estos cortan ANTES de hablar con SAP: es configuración que falta, no
  # un rechazo del Service Layer.
  describe 'configuración incompleta' do
    it 'avisa cuando la compañía no tiene conexión' do
      company.update!(connection_id: nil)

      expect { described_class.for(company, user: user) }
        .to raise_error(described_class::MissingConfiguration, /no tiene una conexión de SAP/)
    end

    it 'avisa cuando la compañía no tiene base de SAP' do
      company.update!(sap_db: nil)

      expect { described_class.for(company, user: user) }
        .to raise_error(described_class::MissingConfiguration, /no tiene base de datos de SAP/)
    end

    it 'avisa cuando el usuario no tiene credenciales propias de SAP' do
      user.update!(sap_user: nil, sap_password: nil)

      expect { described_class.for(company, user: user) }
        .to raise_error(described_class::MissingConfiguration, /no tiene credenciales de SAP/)
    end

    # Medio configurada es peor que sin configurar: SAP rechazaría el login y
    # el error se leería como "credenciales inválidas" en vez de "faltó
    # llenarlas" — mismo criterio que `Sap::CompanyClient`.
    it 'exige las dos mitades de la credencial' do
      user.update!(sap_user: 'ana.sap', sap_password: nil)

      expect { described_class.for(company, user: user) }
        .to raise_error(described_class::MissingConfiguration, /no tiene credenciales de SAP/)
    end

    it 'incluye el correo del usuario en el mensaje' do
      user.update!(sap_user: nil, sap_password: nil)

      expect { described_class.for(company, user: user) }
        .to raise_error(/ana@example\.com/)
    end
  end
end

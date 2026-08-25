# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::CompanyDirectory do
  let(:connection) { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/') }

  def company(name:, sap_db:)
    Company.create!(name: name, sap_db: sap_db, connection_id: connection.id)
  end

  describe '#fetch' do
    it 'resuelve la compañía por su base de SAP' do
      acme = company(name: 'ACME', sap_db: 'SBO_ACME')

      expect(described_class.load.fetch('SBO_ACME')).to eq(acme)
    end

    # `SAPDB` lo devuelve el procedimiento de la cola; `companies.sap_db` lo
    # escribió una persona en un formulario. Que coincidan en la caja es una
    # casualidad, y si no coinciden el documento se queda pendiente para siempre
    # sin ningún error que lo explique.
    it 'no distingue mayúsculas ni espacios sobrantes' do
      acme = company(name: 'ACME', sap_db: 'SBO_ACME')
      directory = described_class.load

      expect(directory.fetch('sbo_acme')).to eq(acme)
      expect(directory.fetch('  SBO_Acme  ')).to eq(acme)
    end

    it 'devuelve nil cuando no hay compañía para esa base' do
      company(name: 'ACME', sap_db: 'SBO_ACME')

      expect(described_class.load.fetch('SBO_OTRA')).to be_nil
    end

    # Una compañía dada de baja no emite. Lo garantiza el `default_scope` de
    # SoftDeletable, pero se verifica acá porque el día que alguien agregue un
    # `unscoped` a la consulta, el síntoma sería que vuelve a emitir en silencio.
    it 'ignora las compañías dadas de baja' do
      company(name: 'ACME', sap_db: 'SBO_ACME').update!(is_active: false)

      expect(described_class.load.fetch('SBO_ACME')).to be_nil
    end

    it 'ignora las compañías sin base de SAP' do
      Company.create!(name: 'Sin base')

      expect(described_class.load.size).to eq(0)
    end
  end

  describe 'bases duplicadas' do
    # Dos compañías no pueden ser la misma base de SAP. Elegir en silencio
    # mandaría los documentos de una con los datos de la otra.
    it 'se queda con la primera y lo avisa' do
      first  = company(name: 'ACME', sap_db: 'SBO_ACME')
      second = company(name: 'ACME Duplicada', sap_db: 'sbo_acme')

      allow(Rails.logger).to receive(:warn)
      directory = described_class.load

      expect(directory.fetch('SBO_ACME')).to eq(first)
      expect(directory.fetch('SBO_ACME')).not_to eq(second)
      expect(Rails.logger).to have_received(:warn).with(/más de una compañía/)
    end
  end

  describe '#known_databases' do
    # El mensaje de "no hay compañía para esta base" tiene que decir contra qué
    # se comparó, o no es accionable.
    it 'lista las bases configuradas' do
      company(name: 'ACME', sap_db: 'SBO_ACME')
      company(name: 'Otra', sap_db: 'SBO_OTRA')

      expect(described_class.load.known_databases).to eq(%w[SBO_ACME SBO_OTRA])
    end
  end
end

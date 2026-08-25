# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::PendingQueue do
  # Un doble del cliente ODBC: acá se prueba cómo se interpreta lo que devuelve el
  # procedimiento, no la conexión a la base de documentos.
  let(:client) { instance_double(ExternalDb::Client) }

  def stub_procedure(rows)
    allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
    allow(client).to receive(:call).with(described_class::PROCEDURE).and_return(rows)
  end

  describe '.pending' do
    it 'invoca el procedimiento de la cola sobre el grupo de ajustes ODBC' do
      stub_procedure([])

      described_class.pending

      expect(client).to have_received(:call).with('CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS')
    end

    it 'mapea las cuatro columnas del procedimiento' do
      stub_procedure([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME' }])

      entry = described_class.pending.first

      expect(entry.id).to eq(7)
      expect(entry.doc_entry).to eq(25)
      expect(entry.doc_type).to eq('01')
      expect(entry.sap_db).to eq('SBO_ACME')
    end

    # HANA devuelve los identificadores en mayúsculas; el mismo código sirve a las
    # dos instalaciones.
    it 'lee las columnas aunque vengan en otra caja' do
      stub_procedure([{ 'ID' => 7, 'DOCENTRY' => 25, 'DOCTYPE' => '01', 'SAPDB' => 'SBO_ACME' }])

      expect(described_class.pending.first.doc_entry).to eq(25)
    end

    it 'normaliza el tipo que perdió el cero adelante' do
      stub_procedure([{ 'Id' => 1, 'DocEntry' => 2, 'DocType' => '1', 'SAPDB' => 'X' }])

      expect(described_class.pending.first.doc_type).to eq('01')
    end

    # Una fila rota es problema de quien la insertó; el resto de la cola sí se
    # puede procesar.
    it 'omite las filas incompletas con un aviso, sin tumbar la corrida' do
      stub_procedure([
                       { 'Id' => 1, 'DocEntry' => nil, 'DocType' => '01', 'SAPDB' => 'X' },
                       { 'Id' => 2, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'X' }
                     ])
      allow(Rails.logger).to receive(:warn)

      entries = described_class.pending

      expect(entries.map(&:id)).to eq([2])
      expect(Rails.logger).to have_received(:warn).with(/fila incompleta/)
    end
  end

  describe 'Entry' do
    # El tipo desconocido NO se descarta: la fila está bien formada y el documento
    # existe. Lo que falta es saber cómo armarlo, y eso lo reporta el job.
    it 'conserva el tipo desconocido y lo marca como tal' do
      stub_procedure([{ 'Id' => 1, 'DocEntry' => 2, 'DocType' => '99', 'SAPDB' => 'X' }])

      entry = described_class.pending.first

      expect(entry.doc_type).to eq('99')
      expect(entry).not_to be_known_type
    end

    it 'se identifica en el log sin exponer datos del negocio' do
      stub_procedure([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME' }])

      expect(described_class.pending.first.to_s).to eq('cola#7 SBO_ACME/01/DocEntry 25')
    end
  end
end

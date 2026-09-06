# frozen_string_literal: true

require 'rails_helper'

# `ruby-odbc` está `require: false` en el Gemfile (§37): normalmente lo carga
# `ExternalDb::Client.require_odbc!` la primera vez que se conecta de verdad,
# pero acá se stubea `ExternalDb::Pool.with` entero, así que ese camino nunca
# corre. Sin este require, `ODBC::TimeStamp` no existe y las filas de más
# abajo no se pueden armar.
require 'odbc'

RSpec.describe Documents::AttemptDetails do
  # Un doble del cliente ODBC: acá se prueba cómo se interpreta lo que devuelve
  # el procedimiento, no la conexión a la base de documentos.
  let(:client) { instance_double(ExternalDb::Client) }

  def stub_procedure(rows)
    allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
    allow(client).to receive(:call).and_return(rows)
  end

  describe '.for' do
    it 'manda SAPDB, DocEntry y DocType posicionales, en ese orden' do
      stub_procedure([])

      described_class.for(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01')

      expect(client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_SLT_DOCUMENTATTEMPS', ['SBO_ACME', 25, '01']
      )
    end

    # Es un SELECT puro: no reclama ni modifica nada, así que confirmar no
    # aporta nada y revertir (el default del conector, §37) no pierde nada.
    it 'no confirma la transacción — no hace falta' do
      stub_procedure([])

      described_class.for(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01')

      expect(client).to have_received(:call).with(anything, anything)
    end

    # El driver ODBC entrega `datetime2` como `ODBC::TimeStamp`, no como
    # `Time`/`DateTime` — es el caso real (ver la nota de `#format_created_at`:
    # su `#to_s` filtraba la fracción cruda en nanosegundos al panel).
    it 'mapea las tres columnas del procedimiento' do
      stub_procedure([{ 'CreatedAt' => ODBC::TimeStamp.new(2026, 9, 5, 10, 3, 12, 813_000_000),
                        'StatusCode' => 4, 'Details' => 'SAP no respondió' }])

      attempt = described_class.for(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01').first

      expect(attempt.created_at).to eq('2026-09-05 10:03:12')
      expect(attempt.status_code).to eq(4)
      expect(attempt.details).to eq('SAP no respondió')
    end

    it 'acepta también un Time/DateTime nativo (por si el driver cambiara de tipo)' do
      stub_procedure([{ 'CreatedAt' => Time.new(2026, 9, 5, 10, 3, 12), 'StatusCode' => 4, 'Details' => nil }])

      attempt = described_class.for(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01').first

      expect(attempt.created_at).to eq('2026-09-05 10:03:12')
    end

    # HANA devuelve los identificadores en mayúsculas; el mismo código sirve a
    # las dos instalaciones.
    it 'lee las columnas aunque vengan en otra caja' do
      stub_procedure([{ 'CREATEDAT' => ODBC::TimeStamp.new(2026, 9, 5, 0, 0, 0, 0), 'STATUSCODE' => 6,
                        'DETAILS' => 'ok' }])

      attempt = described_class.for(sap_db: 'X', doc_entry: 1, doc_type: '01').first

      expect(attempt.status_code).to eq(6)
      expect(attempt.details).to eq('ok')
    end

    it 'conserva el orden en que los devolvió el procedimiento' do
      stub_procedure([
                       { 'CreatedAt' => Time.new(2026, 1, 1), 'StatusCode' => 0, 'Details' => nil },
                       { 'CreatedAt' => Time.new(2026, 1, 2), 'StatusCode' => 4, 'Details' => 'falló' }
                     ])

      attempts = described_class.for(sap_db: 'X', doc_entry: 1, doc_type: '01')

      expect(attempts.map(&:status_code)).to eq([0, 4])
    end

    it 'sin intentos devuelve un arreglo vacío' do
      stub_procedure([])

      expect(described_class.for(sap_db: 'X', doc_entry: 1, doc_type: '01')).to eq([])
    end

    it 'Details nulo se conserva como nil, no como cadena vacía' do
      stub_procedure([{ 'CreatedAt' => Time.new(2026, 1, 1), 'StatusCode' => 0, 'Details' => nil }])

      expect(described_class.for(sap_db: 'X', doc_entry: 1, doc_type: '01').first.details).to be_nil
    end
  end
end

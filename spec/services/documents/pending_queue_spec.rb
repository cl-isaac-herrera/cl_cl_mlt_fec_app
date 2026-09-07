# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::PendingQueue do
  # Un doble del cliente ODBC: acá se prueba cómo se interpreta lo que devuelve el
  # procedimiento, no la conexión a la base de documentos.
  let(:client) { instance_double(ExternalDb::Client) }

  def stub_procedure(rows)
    allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
    allow(client).to receive(:call).and_return(rows)
  end

  describe '.mark_error' do
    let(:entry) do
      described_class::Entry.new(id: 7, doc_entry: 25, doc_type: '01', sap_db: 'SBO_ACME')
    end

    def stub_update
      allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
      allow(client).to receive(:call).and_return([])
    end

    # Los seis parámetros van posicionales y en el orden que declara el
    # procedimiento: @Id, @DocEntry, @DocType, @SAPDB, @Details, @StatusCode.
    # Los identificadores viajan aunque @Id ya alcance para la fila, porque el
    # procedimiento los usa para resolver el duplicado en espera.
    it 'manda los seis parámetros en orden, con el estado Error' do
      stub_update

      described_class.mark_error(entry, 'SAP no respondió')

      expect(client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_UPT_DOCUMENT',
        [7, 25, '01', 'SBO_ACME', 'SAP no respondió', described_class::STATUS_ERROR],
        commit: true
      )
    end

    # Sin confirmar, el conector revierte el UPDATE al salir y el estado no queda.
    it 'confirma la transacción' do
      stub_update

      described_class.mark_error(entry, 'motivo')

      expect(client).to have_received(:call).with(anything, anything, commit: true)
    end

    # Un backtrace entero convierte la cola en un depósito de basura, y no aporta
    # nada que el log no tenga mejor.
    it 'recorta un motivo desmedido' do
      stub_update

      described_class.mark_error(entry, 'x' * 5_000)

      expect(client).to have_received(:call) do |_proc, binds, **|
        expect(binds[4].length).to eq(described_class::MAX_DETAILS)
        expect(binds[4]).to end_with('…')
      end
    end
  end

  describe '.pending' do
    it 'invoca el procedimiento de la cola sobre el grupo de ajustes ODBC' do
      stub_procedure([])

      described_class.pending

      expect(client).to have_received(:call).with('CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS', any_args)
    end

    # El procedimiento es un `UPDATE … OUTPUT` que reclama las filas: sin
    # confirmar, el conector revierte la marca al salir y la misma tanda se
    # reprocesa en cada corrida.
    it 'confirma la transacción, porque el procedimiento reclama los documentos' do
      stub_procedure([])

      described_class.pending

      expect(client).to have_received(:call).with(anything, [], commit: true)
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

  describe '.pending_check' do
    it 'invoca el procedimiento de verificación sobre el grupo de ajustes ODBC' do
      stub_procedure([])

      described_class.pending_check

      expect(client).to have_received(:call).with('CL_D_CL_MLT_FEC_SLT_PENDINGCHECKDOCUMENTS', [])
    end

    # A diferencia de `.pending`, es un SELECT puro: no reclama filas, así que
    # no hay nada que confirmar.
    it 'no manda commit: true — no hay ningún UPDATE que confirmar' do
      stub_procedure([])

      described_class.pending_check

      expect(client).to have_received(:call).with(anything, anything)
    end

    it 'mapea las cuatro columnas del procedimiento' do
      stub_procedure([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME' }])

      entry = described_class.pending_check.first

      expect(entry.id).to eq(7)
      expect(entry.doc_entry).to eq(25)
      expect(entry.doc_type).to eq('01')
      expect(entry.sap_db).to eq('SBO_ACME')
    end

    it 'omite las filas incompletas con un aviso, sin tumbar la corrida' do
      stub_procedure([{ 'Id' => 1, 'DocEntry' => nil, 'DocType' => '01', 'SAPDB' => 'X' }])
      allow(Rails.logger).to receive(:warn)

      expect(described_class.pending_check).to eq([])
      expect(Rails.logger).to have_received(:warn).with(/fila incompleta en CL_D_CL_MLT_FEC_SLT_PENDINGCHECKDOCUMENTS/)
    end
  end

  describe '.mark' do
    let(:entry) do
      described_class::Entry.new(id: 7, doc_entry: 25, doc_type: '01', sap_db: 'SBO_ACME')
    end

    def stub_update
      allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
      allow(client).to receive(:call).and_return([])
    end

    # A diferencia de `.mark_sent`/`.mark_error` (que fijan el estado), esta es
    # la que usa `CheckSentDocumentsJob`: el estado varía según lo que conteste
    # Hacienda (`Sent` si sigue en tránsito, `Accepted`/`Rejected` si ya se
    # resolvió).
    it 'manda el estado y el detalle que reciba, sin fijar ninguno' do
      stub_update

      described_class.mark(entry, status: described_class::STATUS_ACCEPTED, details: nil)

      expect(client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_UPT_DOCUMENT',
        [7, 25, '01', 'SBO_ACME', nil, described_class::STATUS_ACCEPTED],
        commit: true
      )
    end
  end

  describe '.reprocess' do
    def stub_update(rows)
      allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
      allow(client).to receive(:call).and_return(rows)
    end

    # Los cuatro parámetros van posicionales y en el orden que declara el
    # procedimiento: @DocEntry, @SAPDB, @DocType, @Details. La validación de
    # que el documento esté Rejected vive en el SP, no acá.
    it 'manda los cuatro parámetros en orden' do
      stub_update([{ 'Id' => 7 }])

      described_class.reprocess(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', details: 'motivo')

      expect(client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_UPT_REPROCESSDOCUMENT',
        [25, 'SBO_ACME', '01', 'motivo'],
        commit: true
      )
    end

    it 'confirma la transacción, porque el procedimiento escribe' do
      stub_update([{ 'Id' => 7 }])

      described_class.reprocess(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', details: 'motivo')

      expect(client).to have_received(:call).with(anything, anything, commit: true)
    end

    it 'devuelve true cuando el procedimiento reencoló una fila' do
      stub_update([{ 'Id' => 7 }])

      expect(
        described_class.reprocess(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', details: 'motivo')
      ).to be(true)
    end

    # El SP no devuelve fila cuando el documento no existe en la cola o ya no
    # estaba Rejected — las dos se reportan igual, sin adivinar cuál pasó.
    it 'devuelve false cuando el procedimiento no reencoló nada' do
      stub_update([])

      expect(
        described_class.reprocess(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', details: 'motivo')
      ).to be(false)
    end

    it 'recorta un motivo desmedido' do
      stub_update([{ 'Id' => 7 }])

      described_class.reprocess(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', details: 'x' * 5_000)

      expect(client).to have_received(:call) do |_proc, binds, **|
        expect(binds[3].length).to eq(described_class::MAX_DETAILS)
        expect(binds[3]).to end_with('…')
      end
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

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::MailQueue do
  let(:client) { instance_double(ExternalDb::Client) }

  def stub_call(rows = [])
    allow(ExternalDb::Pool).to receive(:with).with(described_class::GROUP_CODE).and_yield(client)
    allow(client).to receive(:call).and_return(rows)
  end

  describe '.pending' do
    it 'invoca el procedimiento de la cola sobre el grupo de ajustes ODBC' do
      stub_call([])

      described_class.pending

      expect(client).to have_received(:call).with('CL_D_CL_MLT_FEC_SLT_PENDINGMAILS', any_args)
    end

    # Es un `UPDATE … OUTPUT` que reclama las filas: sin confirmar, el conector
    # revierte la marca al salir y la misma tanda se reprocesa cada corrida.
    it 'confirma la transacción, porque el procedimiento reclama los correos' do
      stub_call([])

      described_class.pending

      expect(client).to have_received(:call).with(anything, [], commit: true)
    end

    it 'mapea las cinco columnas del procedimiento' do
      stub_call([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME', 'UdtCode' => 9 }])

      entry = described_class.pending.first

      expect(entry.id).to eq(7)
      expect(entry.doc_entry).to eq(25)
      expect(entry.doc_type).to eq('01')
      expect(entry.sap_db).to eq('SBO_ACME')
      expect(entry.udt_code).to eq(9)
    end

    it 'lee las columnas aunque vengan en otra caja (HANA)' do
      stub_call([{ 'ID' => 7, 'DOCENTRY' => 25, 'DOCTYPE' => '01', 'SAPDB' => 'SBO_ACME', 'UDTCODE' => 9 }])

      entry = described_class.pending.first

      expect(entry.doc_entry).to eq(25)
      expect(entry.udt_code).to eq(9)
    end

    # `UdtCode` es `int` en las dos bases, pero un driver ODBC puede devolver un
    # numérico como texto. El entero es el tipo con el que el resto del flujo
    # compara, así que la conversión no se delega al llamador.
    it 'devuelve el UdtCode como entero aunque el driver lo dé como texto' do
      stub_call([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME', 'UdtCode' => '9' }])

      expect(described_class.pending.first.udt_code).to eq(9)
    end

    it 'omite las filas incompletas con un aviso, sin tumbar la corrida' do
      stub_call([
                  { 'Id' => 1, 'DocEntry' => nil, 'DocType' => '01', 'SAPDB' => 'X' },
                  { 'Id' => 2, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'X' }
                ])
      allow(Rails.logger).to receive(:warn)

      entries = described_class.pending

      expect(entries.map(&:id)).to eq([2])
      expect(Rails.logger).to have_received(:warn).with(/fila incompleta/)
    end

    # Una fila encolada antes de que existiera la columna se reclama igual: qué
    # hacer con ella lo decide el job (la marca en Error, con su motivo), no esta
    # capa — descartarla acá la dejaría reclamada para siempre, en Enviando.
    it 'no descarta la fila sin UdtCode' do
      stub_call([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME', 'UdtCode' => nil }])

      entry = described_class.pending.first

      expect(entry.id).to eq(7)
      expect(entry.udt_code).to be_nil
    end
  end

  describe '.create' do
    it 'manda SAPDB, DocEntry, DocType, UdtCode y Type en ese orden' do
      stub_call([])

      described_class.create(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', udt_code: 9)

      expect(client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_CRT_MAILTOQUEUE', ['SBO_ACME', 25, '01', 9, Sap::MailQueue::TYPE_SEND], commit: true
      )
    end

    # El `Type` es lo que le dice al procedimiento que NO aplique el dedupe: un
    # reenvío inserta aunque el intento anterior siga vivo.
    it 'manda el tipo Reenvío cuando se lo pide' do
      stub_call([])

      described_class.create(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01', udt_code: 10,
                             type: Sap::MailQueue::TYPE_RESEND)

      expect(client).to have_received(:call).with(
        anything, ['SBO_ACME', 25, '01', 10, Sap::MailQueue::TYPE_RESEND], commit: true
      )
    end
  end

  describe '.mark' do
    let(:entry) do
      described_class::Entry.new(id: 7, doc_entry: 25, doc_type: '01', sap_db: 'SBO_ACME', udt_code: 9)
    end

    it 'manda el Id y el estado, sin historial de intentos' do
      stub_call([])

      described_class.mark(entry, status: described_class::STATUS_SENT)

      expect(client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_UPT_MAIL', [7, described_class::STATUS_SENT], commit: true
      )
    end
  end

  describe 'Entry#to_s' do
    it 'se identifica en el log sin exponer datos del negocio' do
      stub_call([{ 'Id' => 7, 'DocEntry' => 25, 'DocType' => '01', 'SAPDB' => 'SBO_ACME' }])

      expect(described_class.pending.first.to_s).to eq('correo#7 SBO_ACME/01/DocEntry 25')
    end
  end
end

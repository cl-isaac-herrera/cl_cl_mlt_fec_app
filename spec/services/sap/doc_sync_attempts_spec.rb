# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::DocSyncAttempts do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # `find_or_initialize_by` y no `create!`: las dos filas ya vienen en el esquema
  # de test, insertadas por la migración que completa el catálogo
  # (`20260910160000_add_doc_sync_attempts_sl_resources.rb`).
  def upsert_resource(code, query_params: nil)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: 'U_CL_FEC_DOCSYNCATTMP', query_params: query_params,
                     page_size: 0, is_active: true)
    end
  end

  before do
    upsert_resource('createDocSyncAttempt')
    upsert_resource(
      'getDocSyncAttempts',
      query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=U_CreatedAt desc'
    )
  end

  subject(:attempts) { described_class.new(client: client) }

  describe '#create' do
    it 'manda la llave del documento, el estado y el motivo' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      attempts.create(doc_entry: 25, doc_type: '01',
                      status: Documents::PendingQueue::STATUS_ERROR, details: 'SAP no respondió')

      expect(client).to have_received(:post).with('U_CL_FEC_DOCSYNCATTMP', body: hash_including(
        'U_DocEntry' => 25,
        'U_DocType' => '01',
        'U_Status' => Documents::PendingQueue::STATUS_ERROR,
        'U_Details' => 'SAP no respondió'
      ))
    end

    # ISO 8601 con offset, el mismo formato que `Sap::MailQueue` y que el resto
    # de las fechas de las UDTs (`db_Alpha(25)`, ver el README de los schemas).
    it 'sella el intento con la fecha en ISO 8601' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      attempts.create(doc_entry: 25, doc_type: '01', status: Documents::PendingQueue::STATUS_SENT)

      expect(client).to have_received(:post) do |_path, body:|
        expect(body['U_CreatedAt']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/)
      end
    end

    it 'devuelve el Code que asignó SAP' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      expect(
        attempts.create(doc_entry: 25, doc_type: '01', status: Documents::PendingQueue::STATUS_SENT)
      ).to eq('9')
    end

    # `NULL` significa "no hay nada que contar" y es distinto de un detalle en
    # blanco: es el caso de una pasada de verificación sin novedad.
    it 'conserva el nil del motivo, sin convertirlo en cadena vacía' do
      allow(client).to receive(:post).and_return({})

      attempts.create(doc_entry: 25, doc_type: '01', status: Documents::PendingQueue::STATUS_SENT)

      expect(client).to have_received(:post).with(anything, body: hash_including('U_Details' => nil))
    end

    # Un backtrace entero convierte el historial en un depósito de basura, y no
    # aporta nada que el log no tenga mejor.
    it 'recorta un motivo desmedido' do
      allow(client).to receive(:post).and_return({})

      attempts.create(doc_entry: 25, doc_type: '01',
                      status: Documents::PendingQueue::STATUS_ERROR, details: 'x' * 5_000)

      expect(client).to have_received(:post) do |_path, body:|
        expect(body['U_Details'].length).to eq(described_class::MAX_DETAILS)
        expect(body['U_Details']).to end_with('…')
      end
    end
  end

  describe '#list' do
    # `SAPDB` no es parte de la llave: la compañía la determina la base de SAP
    # contra la que se consulta.
    it 'resuelve el path del catálogo con DocEntry y DocType sustituidos' do
      allow(client).to receive(:get).and_return([])

      attempts.list(doc_entry: 25, doc_type: '01')

      expect(client).to have_received(:get).with(
        "U_CL_FEC_DOCSYNCATTMP?$filter=(U_DocEntry eq 25 and U_DocType eq '01')&$orderby=U_CreatedAt desc"
      )
    end

    it 'devuelve un Attempt por fila, con el estado como entero' do
      allow(client).to receive(:get).and_return(
        [{ 'U_CreatedAt' => '2026-09-05T10:03:12-06:00', 'U_Status' => '4', 'U_Details' => 'SAP no respondió' },
         { 'U_CreatedAt' => '2026-09-05T09:00:00-06:00', 'U_Status' => 3, 'U_Details' => nil }]
      )

      result = attempts.list(doc_entry: 25, doc_type: '01')

      expect(result.map(&:status_code)).to eq([4, 3])
      expect(result.first.created_at).to eq('2026-09-05T10:03:12-06:00')
      expect(result.first.details).to eq('SAP no respondió')
      expect(result.last.details).to be_nil
    end

    it 'devuelve una lista vacía cuando el documento no tiene intentos' do
      allow(client).to receive(:get).and_return([])

      expect(attempts.list(doc_entry: 25, doc_type: '01')).to eq([])
    end
  end
end

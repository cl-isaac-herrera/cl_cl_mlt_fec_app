# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::DocumentStatus do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client, patch: nil) }

  before do
    SlResource.create!(code: 'updateDocument01', resource: 'Invoices(#DocumentEntry#)', page_size: 0)
    SlResource.create!(code: 'updateDocument03', resource: 'CreditNotes(#DocumentEntry#)', page_size: 0)
  end

  def status(doc_type: DocType::FE, doc_entry: 25)
    described_class.new(client: client, doc_type: doc_type, doc_entry: doc_entry)
  end

  it 'resuelve el path desde el catálogo, con el DocEntry sustituido' do
    status.call(status: Documents::PendingQueue::STATUS_SENT)

    expect(client).to have_received(:patch).with('Invoices(25)', anything)
  end

  it 'elige la entidad de SAP según el tipo de documento' do
    status(doc_type: DocType::NC).call(status: Documents::PendingQueue::STATUS_SENT)

    expect(client).to have_received(:patch).with('CreditNotes(25)', anything)
  end

  # Los siete campos van SIEMPRE — ningún desenlace es un caso especial que
  # recorte el body. Es la corrección explícita a la versión anterior, que
  # omitía Clave/NumConsecutivo cuando venían en blanco.
  describe 'los siete campos van siempre, en cualquier desenlace' do
    it 'en un envío aceptado' do
      status.call(status: Documents::PendingQueue::STATUS_SENT, clave: '506123',
                  consecutivo: '00100001010000000001', xml_sent_url: 'https://azure.test/x.xml',
                  fecha_emision: '2026-09-06T09:06:00Z')

      expect(client).to have_received(:patch).with(anything, body: {
        'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_SENT,
        'U_CL_FEC_ErrorDetails' => nil,
        'U_CL_FEC_Clave' => '506123',
        'U_CL_FEC_NumConsecutivo' => '00100001010000000001',
        'U_CL_FEC_XmlSentUrl' => 'https://azure.test/x.xml',
        'U_CL_FEC_XmlResponseUrl' => nil,
        'U_CL_FEC_FechaEmision' => '2026-09-06T09:06:00Z'
      })
    end

    it 'en un error de validación, antes de que exista un XML que archivar' do
      status.call(status: Documents::PendingQueue::STATUS_ERROR, details: 'Falta el CABYS.',
                  clave: '506123', consecutivo: '00100001010000000001')

      expect(client).to have_received(:patch).with(anything, body: {
        'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_ERROR,
        'U_CL_FEC_ErrorDetails' => 'Falta el CABYS.',
        'U_CL_FEC_Clave' => '506123',
        'U_CL_FEC_NumConsecutivo' => '00100001010000000001',
        'U_CL_FEC_XmlSentUrl' => nil,
        'U_CL_FEC_XmlResponseUrl' => nil,
        'U_CL_FEC_FechaEmision' => nil
      })
    end

    it 'sin ningún dato — el llamador no sabe nada todavía' do
      status.call(status: Documents::PendingQueue::STATUS_ERROR)

      expect(client).to have_received(:patch).with(anything, body: {
        'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_ERROR,
        'U_CL_FEC_ErrorDetails' => nil,
        'U_CL_FEC_Clave' => nil,
        'U_CL_FEC_NumConsecutivo' => nil,
        'U_CL_FEC_XmlSentUrl' => nil,
        'U_CL_FEC_XmlResponseUrl' => nil,
        'U_CL_FEC_FechaEmision' => nil
      })
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::DocumentCheckStatus do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client, patch: nil) }

  before do
    SlResource.create!(code: 'updateDocument01', resource: 'Invoices(#DocumentEntry#)', page_size: 0)
  end

  def check_status(doc_type: DocType::FE, doc_entry: 25)
    described_class.new(client: client, doc_type: doc_type, doc_entry: doc_entry)
  end

  it 'resuelve el path desde el mismo catálogo que Sap::DocumentStatus' do
    check_status.call(status: Documents::PendingQueue::STATUS_SENT)

    expect(client).to have_received(:patch).with('Invoices(25)', anything)
  end

  # A diferencia de `Sap::DocumentStatus`, NUNCA manda `Clave`/`NumConsecutivo`/
  # `XmlSentUrl`: ya están en SAP desde el envío, y mandarlos como `nil` acá los
  # borraría.
  it 'manda SOLO los tres campos que una verificación puede cambiar' do
    check_status.call(status: Documents::PendingQueue::STATUS_ACCEPTED,
                       xml_response_url: 'https://azure.test/x_respuesta.xml')

    expect(client).to have_received(:patch).with(anything, body: {
      'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_ACCEPTED,
      'U_CL_FEC_ErrorDetails' => nil,
      'U_CL_FEC_XmlResponseUrl' => 'https://azure.test/x_respuesta.xml'
    })
  end

  it 'manda el motivo del rechazo en ErrorDetails' do
    check_status.call(status: Documents::PendingQueue::STATUS_REJECTED, details: 'Comprobante duplicado.')

    expect(client).to have_received(:patch).with(anything, body: hash_including(
      'U_CL_FEC_ErrorDetails' => 'Comprobante duplicado.'
    ))
  end

  it 'sin ningún dato — el documento sigue Sent y la verificación no tuvo error' do
    check_status.call(status: Documents::PendingQueue::STATUS_SENT)

    expect(client).to have_received(:patch).with(anything, body: {
      'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_SENT,
      'U_CL_FEC_ErrorDetails' => nil,
      'U_CL_FEC_XmlResponseUrl' => nil
    })
  end
end

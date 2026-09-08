# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::MailDocumentInfo do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }
  let(:select_fields) do
    '$select=U_CL_FEC_NumConsecutivo,CardName,U_CL_FEC_Clave,U_CL_FEC_FechaEmision,DocTotal,DocTotalFc,' \
      'DocCurrency,U_CL_FEC_Status,U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl'
  end

  before do
    # `find_or_initialize_by`: la migración `AddMailDocumentInfoSlResources` ya
    # deja esta fila sembrada en cualquier base migrada (incluida la de test),
    # así que un `create!` a secas chocaría con la unicidad de `code` — mismo
    # patrón que `spec/services/sap/issued_documents_search_spec.rb`.
    record = SlResource.unscoped.find_or_initialize_by(code: 'getMailDocumentInfo01')
    record.update!(resource: 'Invoices', query_params: "$filter=DocEntry eq @DocEntry&#{select_fields}",
                   page_size: 0, is_active: true)
  end

  def company(send_rejected: false)
    Company.new(name: 'ACME S.A.', send_rejected_documents: send_rejected)
  end

  subject(:info) do
    described_class.new(company: company, doc_entry: 25, doc_type: '01', client: client)
  end

  it 'le suma U_CL_FEC_Status eq 6 al filtro cuando la compañía no envía rechazados' do
    allow(client).to receive(:get).and_return([])

    info.call

    expect(client).to have_received(:get)
      .with("Invoices?$filter=DocEntry eq 25 and U_CL_FEC_Status eq 6&#{select_fields}")
  end

  it 'NO le suma el filtro de estado cuando la compañía sí envía rechazados' do
    allow(client).to receive(:get).and_return([])

    described_class.new(company: company(send_rejected: true), doc_entry: 25, doc_type: '01', client: client).call

    expect(client).to have_received(:get).with("Invoices?$filter=DocEntry eq 25&#{select_fields}")
  end

  it 'devuelve la fila envuelta en Documents::Row' do
    allow(client).to receive(:get).and_return([{ 'CardName' => 'Cliente Test' }])

    expect(info.call.string('CardName')).to eq('Cliente Test')
  end

  it 'devuelve nil cuando SAP no devuelve filas (el filtro de estado excluyó el documento)' do
    allow(client).to receive(:get).and_return([])

    expect(info.call).to be_nil
  end

  it 'levanta UnsupportedDocType cuando el tipo no tiene fila en el catálogo' do
    expect do
      described_class.new(company: company, doc_entry: 25, doc_type: '99', client: client).call
    end.to raise_error(described_class::UnsupportedDocType, /"99"/)
  end
end

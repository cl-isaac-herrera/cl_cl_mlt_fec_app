# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::MailDocumentInfo do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }
  let(:resource) { 'CL_D_CL_MLT_FEC_SLT_DOCMAILINFO_B1SLQuery' }

  before do
    # `find_or_initialize_by`: la migración `PointGetMailDocumentInfoSlResourcesToView`
    # ya deja esta fila sembrada en cualquier base migrada (incluida la de
    # test), así que un `create!` a secas chocaría con la unicidad de `code` —
    # mismo patrón que `spec/services/sap/issued_documents_search_spec.rb`.
    record = SlResource.unscoped.find_or_initialize_by(code: 'getMailDocumentInfo')
    record.update!(resource: resource, query_params: '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)',
                   page_size: 0, is_active: true)
  end

  def company(send_rejected: false)
    Company.new(name: 'ACME S.A.', send_rejected_documents: send_rejected)
  end

  subject(:info) do
    described_class.new(company: company, doc_entry: 25, doc_type: '01', client: client)
  end

  it 'le suma Status eq 6 al filtro cuando la compañía no envía rechazados' do
    allow(client).to receive(:get).and_return([])

    info.call

    expect(client).to have_received(:get)
      .with("#{resource}?$filter=(DocEntry eq 25 and DocType eq '01') and Status eq 6")
  end

  it 'NO le suma el filtro de estado cuando la compañía sí envía rechazados' do
    allow(client).to receive(:get).and_return([])

    described_class.new(company: company(send_rejected: true), doc_entry: 25, doc_type: '01', client: client).call

    expect(client).to have_received(:get).with("#{resource}?$filter=(DocEntry eq 25 and DocType eq '01')")
  end

  # Es la MISMA fila para los siete tipos: el `$filter=DocType eq @DocType` es
  # un binding dinámico, no un literal horneado por tipo (a diferencia de
  # `getDocuments01`..`10`).
  it 'usa la misma fila del catálogo sea cual sea el tipo de documento' do
    allow(client).to receive(:get).and_return([])

    described_class.new(company: company(send_rejected: true), doc_entry: 40, doc_type: '08', client: client).call

    expect(client).to have_received(:get).with("#{resource}?$filter=(DocEntry eq 40 and DocType eq '08')")
  end

  it 'devuelve la fila envuelta en Documents::Row' do
    allow(client).to receive(:get).and_return([{ 'CardName' => 'Cliente Test' }])

    expect(info.call.string('CardName')).to eq('Cliente Test')
  end

  it 'devuelve nil cuando SAP no devuelve filas (el filtro de estado excluyó el documento)' do
    allow(client).to receive(:get).and_return([])

    expect(info.call).to be_nil
  end

  it 'levanta UnsupportedDocType cuando el código no es un tipo de documento que DocType reconozca' do
    expect do
      described_class.new(company: company, doc_entry: 25, doc_type: '99', client: client).call
    end.to raise_error(described_class::UnsupportedDocType, /"99"/)
  end

  # Los mensajes de receptor (`05`/`06`/`07`) no son comprobantes: no tienen
  # `DocEntry` propio en la vista, así que este correo no les aplica.
  it 'levanta UnsupportedDocType para un mensaje de receptor' do
    expect do
      described_class.new(company: company, doc_entry: 25, doc_type: DocType::AT, client: client).call
    end.to raise_error(described_class::UnsupportedDocType, /"05"/)
  end
end

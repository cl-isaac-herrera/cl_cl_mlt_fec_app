# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::MailQueue do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  before do
    SlResource.create!(code: 'qsGetMailQueueByDocument', resource: '@CL_FEC_MAILSQUEUE',
                       query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType and U_Status ne 4)',
                       page_size: 0)
    SlResource.create!(code: 'createMailQueue', resource: '@CL_FEC_MAILSQUEUE', page_size: 0)
    SlResource.create!(code: 'updateMailQueue', resource: '@CL_FEC_MAILSQUEUE(#Code#)', page_size: 0)
  end

  subject(:mail_queue) { described_class.new(client: client) }

  describe '#find' do
    it 'resuelve el path del catálogo con DocEntry y DocType sustituidos' do
      allow(client).to receive(:get).and_return([])

      mail_queue.find(doc_entry: 25, doc_type: '01')

      expect(client).to have_received(:get).with(
        "@CL_FEC_MAILSQUEUE?$filter=(U_DocEntry eq 25 and U_DocType eq '01' and U_Status ne 4)"
      )
    end

    it 'devuelve la fila envuelta en Documents::Row' do
      allow(client).to receive(:get).and_return([{ 'Code' => '3', 'U_OutputTo' => 'x@test.com' }])

      row = mail_queue.find(doc_entry: 25, doc_type: '01')

      expect(row.string('Code')).to eq('3')
      expect(row.string('U_OutputTo')).to eq('x@test.com')
    end

    it 'devuelve nil cuando SAP no tiene ninguna fila' do
      allow(client).to receive(:get).and_return([])

      expect(mail_queue.find(doc_entry: 25, doc_type: '01')).to be_nil
    end

    it 'avisa y usa la primera cuando SAP devuelve más de una' do
      allow(client).to receive(:get).and_return([{ 'Code' => '1' }, { 'Code' => '2' }])
      allow(Rails.logger).to receive(:warn)

      row = mail_queue.find(doc_entry: 25, doc_type: '01')

      expect(row.string('Code')).to eq('1')
      expect(Rails.logger).to have_received(:warn).with(/devolvió 2 filas/)
    end
  end

  describe '#create' do
    it 'crea la fila con el estado Pendiente y el tipo Envío por defecto' do
      allow(client).to receive(:post).and_return({ 'Code' => '7' })

      mail_queue.create(doc_entry: 25, doc_type: '01', output_to: 'a@test.com', output_cc: 'b@test.com',
                        output_bcc: nil)

      expect(client).to have_received(:post).with('@CL_FEC_MAILSQUEUE', body: hash_including(
        'U_DocEntry' => 25,
        'U_DocType' => '01',
        'U_Status' => 1,
        'U_OutputTo' => 'a@test.com',
        'U_OutputCC' => 'b@test.com',
        'U_OutputBCC' => nil,
        'U_Type' => described_class::TYPE_SEND
      ))
    end

    it 'devuelve el Code que asignó SAP' do
      allow(client).to receive(:post).and_return({ 'Code' => '7' })

      expect(
        mail_queue.create(doc_entry: 25, doc_type: '01', output_to: 'a@test.com', output_cc: nil, output_bcc: nil)
      ).to eq('7')
    end
  end

  describe '#update_status' do
    it 'resuelve el path con el Code de la fila' do
      allow(client).to receive(:patch)

      mail_queue.update_status(code: '7', status: 4)

      expect(client).to have_received(:patch).with('@CL_FEC_MAILSQUEUE(7)', anything)
    end

    it 'manda el estado, la fecha del intento y el detalle o el correo enviado' do
      allow(client).to receive(:patch)

      mail_queue.update_status(code: '7', status: 3, details: 'SMTP rechazó la conexión')

      expect(client).to have_received(:patch).with(anything, body: hash_including(
        'U_Status' => 3,
        'U_Details' => 'SMTP rechazó la conexión',
        'U_Email' => nil
      ))
    end
  end
end

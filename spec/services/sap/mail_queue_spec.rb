# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::MailQueue do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  before do
    SlResource.create!(code: 'getPendingDocumentMail', resource: 'U_CL_FEC_MAILSDETAILS',
                       query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType and ' \
                                     'U_Status ne 4 and U_Status ne 5)&$orderby=Code desc',
                       page_size: 0)
    SlResource.create!(code: 'createDocumentMail', resource: 'U_CL_FEC_MAILSDETAILS', page_size: 0)
    SlResource.create!(code: 'updateDocumentMail', resource: 'U_CL_FEC_MAILSDETAILS(#Code#)', page_size: 0)
    # `find_or_initialize_by` y no `create!`: la fila puede venir ya insertada
    # por su migración (`20260912100000_add_document_mails_sl_resource.rb`).
    SlResource.unscoped.find_or_initialize_by(code: 'getDocumentMails').update!(
      resource: 'U_CL_FEC_MAILSDETAILS',
      query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=Code desc',
      page_size: 0, is_active: true
    )
  end

  subject(:mail_queue) { described_class.new(client: client) }

  describe '#find' do
    it 'resuelve el path del catálogo con DocEntry y DocType sustituidos' do
      allow(client).to receive(:get).and_return([])

      mail_queue.find(doc_entry: 25, doc_type: '01')

      expect(client).to have_received(:get).with(
        'U_CL_FEC_MAILSDETAILS?$filter=(U_DocEntry eq 25 and ' \
        "U_DocType eq '01' and U_Status ne 4 and U_Status ne 5)&$orderby=Code desc"
      )
    end

    # El orden lo decide el catálogo, pero lo que `#find` promete es que se queda
    # con la más reciente. Importa desde que un reenvío puede convivir con un
    # envío que quedó en Error: la buena es la nueva.
    it 'se queda con la primera que devuelve la consulta, la más reciente' do
      allow(client).to receive(:get).and_return(
        [{ 'Code' => '9', 'U_Type' => 2, 'U_OutputTo' => 'nuevo@test.com' },
         { 'Code' => '8', 'U_Type' => 1, 'U_OutputTo' => 'viejo@test.com' }]
      )
      allow(Rails.logger).to receive(:warn)

      expect(mail_queue.find(doc_entry: 25, doc_type: '01').string('U_OutputTo')).to eq('nuevo@test.com')
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

  describe '#list' do
    # Es OTRA consulta del catálogo, no `getPendingDocumentMail`: esta no excluye
    # los estados terminales, que son justamente los que el panel muestra.
    it 'resuelve el path del catálogo con DocEntry y DocType sustituidos' do
      allow(client).to receive(:get).and_return([])

      mail_queue.list(doc_entry: 25, doc_type: '01')

      expect(client).to have_received(:get).with(
        "U_CL_FEC_MAILSDETAILS?$filter=(U_DocEntry eq 25 and U_DocType eq '01')&$orderby=Code desc"
      )
    end

    it 'devuelve un Mail por fila, con el estado y el tipo como enteros' do
      allow(client).to receive(:get).and_return(
        [{ 'Code' => '8', 'U_CreatedAt' => '2026-09-11T10:03:12-06:00',
           'U_LastAttempt' => '2026-09-11T10:04:00-06:00', 'U_Status' => '4', 'U_Type' => 1,
           'U_OutputTo' => 'cliente@test.com', 'U_OutputCC' => 'copia@test.com',
           'U_OutputBCC' => nil, 'U_Email' => 'bandeja@acme.test', 'U_Details' => nil },
         { 'Code' => '7', 'U_CreatedAt' => '2026-09-10T09:00:00-06:00', 'U_Status' => 3, 'U_Type' => 1,
           'U_Details' => 'SMTP rechazó la conexión' }]
      )

      result = mail_queue.list(doc_entry: 25, doc_type: '01')

      expect(result.map(&:code)).to eq(%w[8 7])
      expect(result.first.status).to eq(4)
      expect(result.first.type).to eq(1)
      expect(result.first.output_to).to eq('cliente@test.com')
      expect(result.first.output_cc).to eq('copia@test.com')
      expect(result.first.sender).to eq('bandeja@acme.test')
      expect(result.first.details).to be_nil
      expect(result.last.details).to eq('SMTP rechazó la conexión')
      expect(result.last.last_attempt).to be_nil
    end

    # HANA devuelve los identificadores en MAYÚSCULAS (ver `Documents::Row`).
    it 'lee los campos sin depender de la caja de los identificadores' do
      allow(client).to receive(:get).and_return([{ 'CODE' => '8', 'U_STATUS' => 4, 'U_OUTPUTTO' => 'x@test.com' }])

      mail = mail_queue.list(doc_entry: 25, doc_type: '01').first

      expect(mail.code).to eq('8')
      expect(mail.status).to eq(4)
      expect(mail.output_to).to eq('x@test.com')
    end

    it 'devuelve una lista vacía cuando el documento no tiene correos' do
      allow(client).to receive(:get).and_return([])

      expect(mail_queue.list(doc_entry: 25, doc_type: '01')).to eq([])
    end
  end

  describe '#create' do
    it 'crea la fila con el estado Pendiente y el tipo Envío por defecto' do
      allow(client).to receive(:post).and_return({ 'Code' => '7' })

      mail_queue.create(doc_entry: 25, doc_type: '01', output_to: 'a@test.com', output_cc: 'b@test.com',
                        output_bcc: nil)

      expect(client).to have_received(:post).with('U_CL_FEC_MAILSDETAILS', body: hash_including(
        'U_DocEntry' => 25,
        'U_DocType' => '01',
        'U_Status' => 1,
        'U_OutputTo' => 'a@test.com',
        'U_OutputCC' => 'b@test.com',
        'U_OutputBCC' => nil,
        'U_Type' => described_class::TYPE_SEND
      ))
    end

    # Un reenvío nace igual que un envío —Pendiente—; lo que los distingue es
    # `U_Type`, no el estado.
    it 'acepta el tipo Reenvío, sin cambiar el estado inicial' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      mail_queue.create(doc_entry: 25, doc_type: '01', output_to: 'a@test.com', output_cc: nil,
                        output_bcc: nil, type: described_class::TYPE_RESEND)

      expect(client).to have_received(:post).with(anything, body: hash_including(
        'U_Status' => Documents::MailQueue::STATUS_PENDING,
        'U_Type' => described_class::TYPE_RESEND
      ))
    end

    # Entero aunque el Service Layer lo devuelva como texto: la UDT es
    # `bott_NoObjectAutoIncrement` y la columna que lo guarda
    # (`OutgoingMailsQueue.UdtCode`) es `int`.
    it 'devuelve como entero el Code que asignó SAP' do
      allow(client).to receive(:post).and_return({ 'Code' => '7' })

      expect(
        mail_queue.create(doc_entry: 25, doc_type: '01', output_to: 'a@test.com', output_cc: nil, output_bcc: nil)
      ).to eq(7)
    end
  end

  describe '#update_status' do
    it 'resuelve el path con el Code de la fila' do
      allow(client).to receive(:patch)

      mail_queue.update_status(code: '7', status: 4)

      expect(client).to have_received(:patch).with('U_CL_FEC_MAILSDETAILS(7)', anything)
    end

    it 'manda el estado, la fecha del intento y el motivo del error (sin remitente)' do
      allow(client).to receive(:patch)

      mail_queue.update_status(code: '7', status: 3, details: 'SMTP rechazó la conexión')

      expect(client).to have_received(:patch).with(anything, body: hash_including(
        'U_Status' => 3,
        'U_Details' => 'SMTP rechazó la conexión',
        'U_Email' => nil
      ))
    end

    it 'manda en U_Email el remitente con el que salió el correo' do
      allow(client).to receive(:patch)

      mail_queue.update_status(code: '7', status: 4, email: 'bandeja@acme.test')

      expect(client).to have_received(:patch).with(anything, body: hash_including(
        'U_Status' => 4,
        'U_Details' => nil,
        'U_Email' => 'bandeja@acme.test'
      ))
    end
  end
end

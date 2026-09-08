# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CheckSentDocumentsJob do
  let(:connection) do
    Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/',
                       sap_license: 'licencia', sap_license_password: 'secreto')
  end
  let!(:company) do
    Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id)
  end
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }
  let(:hacienda) { instance_double(Hacienda::Client) }
  let(:xml_response_url) { 'https://azure.test/clvsfe/3101822733/506123_respuesta.xml' }

  before do
    SlResource.create!(code: Sap::DocumentDetails::HEADER, resource: 'view.svc/HEADER_B1SLQuery',
                       query_params: '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', page_size: 0)
    SlResource.create!(code: 'updateDocument01', resource: 'Invoices(#DocumentEntry#)', page_size: 0)

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    # La verificación SOLO pide la `Clave`: el resto del documento ya se armó y
    # se envió, no hace falta volver a traer las seis consultas de detalle.
    allow(client).to receive(:get).and_return([{ 'Clave' => '506123' }])
    allow(client).to receive(:patch)

    allow(Hacienda::Client).to receive(:new).and_return(hacienda)
    allow(Documents::XmlArchive).to receive(:store_response).and_return(xml_response_url)
  end

  def queue(*entries)
    allow(Documents::PendingQueue).to receive(:pending_check).and_return(entries)
    # El desenlace vuelve a la cola. Se dobla para que un ejemplo no intente
    # hablar con la base externa.
    allow(Documents::PendingQueue).to receive(:mark)
  end

  def entry(id: 1, doc_entry: 25, doc_type: DocType::FE, sap_db: 'SBO_ACME')
    Documents::PendingQueue::Entry.new(id: id, doc_entry: doc_entry, doc_type: doc_type, sap_db: sap_db)
  end

  def check_result(status:, xml_base64: nil)
    Hacienda::Client::CheckResult.new(status: status, xml_base64: xml_base64)
  end

  describe 'cola vacía' do
    it 'no toca SAP' do
      queue

      described_class.perform_now

      expect(Sap::CompanyClient).not_to have_received(:for)
    end
  end

  describe 'Hacienda todavía no resuelve' do
    # SAP Service Layer no mapea `$select` de forma confiable sobre las vistas
    # `qs*` (SQL Queries, no una entidad OData nativa) — confirmado contra SAP
    # real: `$select=Clave` devolvía el valor bajo OTRO nombre de campo. Por
    # eso se trae la fila COMPLETA, igual que `Sap::DocumentDetails` (ver
    # `TODOS.md` → SAP).
    it 'consulta la cabecera completa, sin acotar con $select' do
      queue(entry)
      allow(hacienda).to receive(:check_status).and_return(check_result(status: 'procesando'))

      described_class.perform_now

      expect(client).to have_received(:get).with(satisfy { |path| !path.include?('$select') })
    end

    it 'verifica con la clave que trajo SAP y deja el documento en Sent' do
      queue(entry)
      allow(hacienda).to receive(:check_status).with('506123').and_return(check_result(status: 'procesando'))

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_SENT, details: nil)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_Status' => Documents::PendingQueue::STATUS_SENT))
    end

    it 'no archiva nada mientras Hacienda no resuelva' do
      queue(entry)
      allow(hacienda).to receive(:check_status).and_return(check_result(status: 'recibido'))

      described_class.perform_now

      expect(Documents::XmlArchive).not_to have_received(:store_response)
    end
  end

  describe 'Hacienda acepta' do
    before do
      allow(hacienda).to receive(:check_status)
        .and_return(check_result(status: 'aceptado', xml_base64: Base64.strict_encode64('<Mensaje/>')))
    end

    it 'marca Accepted en la cola y en SAP, con la URL del XML archivado' do
      queue(entry)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_ACCEPTED, details: nil)
      expect(client).to have_received(:patch).with(anything, body: {
        'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_ACCEPTED,
        'U_CL_FEC_ErrorDetails' => nil,
        'U_CL_FEC_XmlResponseUrl' => xml_response_url
      })
    end

    it 'archiva el XML ya decodificado, con la clave que trajo SAP' do
      queue(entry)

      described_class.perform_now

      expect(Documents::XmlArchive).to have_received(:store_response)
        .with(company: company, clave: '506123', xml: '<Mensaje/>')
    end
  end

  describe 'Hacienda rechaza' do
    let(:xml) { '<MensajeHacienda><DetalleMensaje>La clave ya existe</DetalleMensaje></MensajeHacienda>' }

    before do
      allow(hacienda).to receive(:check_status)
        .and_return(check_result(status: 'rechazado', xml_base64: Base64.strict_encode64(xml)))
    end

    it 'marca Rejected con el motivo que trae el XML de respuesta' do
      queue(entry)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_REJECTED, details: 'La clave ya existe')
      expect(client).to have_received(:patch).with(anything, body: hash_including(
        'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_REJECTED,
        'U_CL_FEC_ErrorDetails' => 'La clave ya existe'
      ))
    end
  end

  # La pregunta NUNCA es "reintentar o marcar Error": a diferencia del envío,
  # una verificación que falla deja el documento tal como estaba (`Sent`) — el
  # comprobante YA fue aceptado por Hacienda al recibirlo, así que fallar al
  # consultar la resolución no es un desenlace del documento.
  describe 'la verificación falla' do
    it 'deja el documento en Sent con el motivo, sin escalar a Error' do
      queue(entry)
      allow(hacienda).to receive(:check_status)
        .and_raise(Hacienda::Client::TransientError, 'Hacienda no disponible')

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_SENT, details: /Hacienda no disponible/)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_Status' => Documents::PendingQueue::STATUS_SENT))
    end

    it 'trata credenciales inválidas igual que cualquier otro error de verificación' do
      queue(entry)
      allow(hacienda).to receive(:check_status)
        .and_raise(Hacienda::Client::InvalidCredentials, 'credenciales inválidas')

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_SENT, details: /credenciales inválidas/)
    end

    it 'no escala a Error cuando SAP no devuelve la clave' do
      queue(entry)
      allow(client).to receive(:get).and_return([])
      allow(hacienda).to receive(:check_status)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_SENT, details: /no devolvió la clave/)
      expect(hacienda).not_to have_received(:check_status)
    end

    it 'sigue con el resto cuando uno revienta' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))
      call_count = 0
      allow(hacienda).to receive(:check_status) do
        call_count += 1
        raise 'algo reventó' if call_count == 1

        check_result(status: 'procesando')
      end
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error
      expect(Sentry).to have_received(:capture_exception).once
    end
  end

  # La UDT (destinatarios, `Sap::MailQueue`) ya la crea `SyncIssuedDocumentsJob`
  # tan pronto Hacienda RECIBE el documento — este job solo encola la cola
  # EXTERNA (`Documents::MailQueue`, el disparador real de
  # `SendElectronicReceiptJob`), y sin condicionar por destinatario: eso ya se
  # decidió antes.
  describe 'correo de recepción' do
    before { allow(Documents::MailQueue).to receive(:create) }

    it 'encola en la cola externa cuando Hacienda acepta' do
      queue(entry)
      allow(hacienda).to receive(:check_status)
        .and_return(check_result(status: 'aceptado', xml_base64: Base64.strict_encode64('<Mensaje/>')))

      described_class.perform_now

      expect(Documents::MailQueue).to have_received(:create)
        .with(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: DocType::FE)
    end

    it 'también encola cuando Hacienda rechaza' do
      xml = '<MensajeHacienda><DetalleMensaje>La clave ya existe</DetalleMensaje></MensajeHacienda>'
      queue(entry)
      allow(hacienda).to receive(:check_status)
        .and_return(check_result(status: 'rechazado', xml_base64: Base64.strict_encode64(xml)))

      described_class.perform_now

      expect(Documents::MailQueue).to have_received(:create)
    end

    it 'no tumba la verificación si falla el encolado del correo' do
      queue(entry)
      allow(hacienda).to receive(:check_status)
        .and_return(check_result(status: 'aceptado', xml_base64: Base64.strict_encode64('<Mensaje/>')))
      allow(Documents::MailQueue).to receive(:create).and_raise('la base externa no responde')
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error
      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_ACCEPTED, details: nil)
      expect(Sentry).to have_received(:capture_exception)
    end
  end

  describe 'sin compañía configurada' do
    it 'deja el documento en Sent en la cola, sin tocar SAP' do
      queue(entry(sap_db: 'SBO_FANTASMA'))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark)
        .with(anything, status: Documents::PendingQueue::STATUS_SENT, details: /No hay una compañía activa/)
      expect(Sap::CompanyClient).not_to have_received(:for)
    end
  end

  describe 'base de documentos sin configurar' do
    it 'avisa y termina sin fallar' do
      allow(Documents::PendingQueue).to receive(:pending_check)
        .and_raise(ExternalDb::ConfigurationError, 'Faltan ajustes')
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/sin conexión a la base de documentos/)
    end

    it 'deja fallar cuando la base no responde' do
      allow(Documents::PendingQueue).to receive(:pending_check)
        .and_raise(ExternalDb::ConnectionError, 'servidor caído')

      expect { described_class.perform_now }.to raise_error(ExternalDb::ConnectionError)
    end
  end
end

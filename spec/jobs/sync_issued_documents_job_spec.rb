# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SyncIssuedDocumentsJob do
  let(:connection) do
    Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/',
                       sap_license: 'licencia', sap_license_password: 'secreto')
  end
  let!(:company) do
    Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id)
  end
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # La firma y el envío se doblan: acá se prueba la ORQUESTACIÓN —qué se
  # intenta, en qué orden y qué se anota en la cola y en SAP según el
  # desenlace—, no el XML ni el HTTP. Eso lo cubren
  # `spec/services/hacienda/xml_builder_spec.rb` y `client_spec.rb`.
  let(:signer) { instance_double(Hacienda::XmlSigner, sign: 'PEZhY3R1cmE+') }
  let(:hacienda) { instance_double(Hacienda::Client) }
  let(:receipt) do
    Hacienda::Client::Receipt.new(location: 'https://api.test/recepcion/555', duplicate: false)
  end
  let(:xml_sent_url) { 'https://azure.test/clvsfe/3101822733/506123.xml' }

  before do
    filter = '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)'
    %w[HEADER LINES OTHER_CHARGES PAYMENT_METHODS REFERENCES OTHERS].each do |name|
      SlResource.create!(code: Sap::DocumentDetails.const_get(name),
                         resource: "view.svc/#{name}_B1SLQuery", query_params: filter, page_size: 0)
    end
    # El recurso con el que se le escribe el desenlace al documento de SAP.
    SlResource.create!(code: 'updateDocument01', resource: 'Invoices(#DocumentEntry#)', page_size: 0)

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    allow(client).to receive(:get) do |path|
      path.match?(/HEADER/) ? [{ 'Clave' => '506123', 'FechaEmision' => '2026-09-06T09:06:00Z' }] : []
    end
    allow(client).to receive(:patch)

    allow(Hacienda::CompanySigner).to receive(:for).and_return(signer)
    allow(Hacienda::Client).to receive(:new).and_return(hacienda)
    allow(hacienda).to receive(:send_document).and_return(receipt)
    # El archivado en Azure se dobla igual que la firma y el envío: tiene su
    # propio spec (`spec/services/azure/blob_storage_spec.rb`,
    # `xml_archive_spec.rb`). Acá solo importa que `Documents::Issuer` lo llama
    # y que la URL que devuelve termina en el `PATCH` a SAP.
    allow(Documents::XmlArchive).to receive(:store_sent).and_return(xml_sent_url)
    # El documento de prueba no pasa las reglas de FE (la cabecera que devuelve
    # el doble de SAP trae solo la clave), así que el validador se dobla en los
    # ejemplos que no lo están probando.
    allow(Hacienda::InvoiceValidator).to receive(:new).and_return(
      instance_double(Hacienda::InvoiceValidator,
                      call: Hacienda::InvoiceValidator::Result.new(errors: []))
    )
  end

  def queue(*entries)
    allow(Documents::PendingQueue).to receive(:pending).and_return(entries)
    # El desenlace vuelve a la cola. Se doblan los dos: sin esto un ejemplo
    # intentaría hablar con la base externa.
    allow(Documents::PendingQueue).to receive(:mark_error)
    allow(Documents::PendingQueue).to receive(:mark_sent)
  end

  def entry(id: 1, doc_entry: 25, doc_type: DocType::FE, sap_db: 'SBO_ACME')
    Documents::PendingQueue::Entry.new(id: id, doc_entry: doc_entry, doc_type: doc_type, sap_db: sap_db)
  end

  describe 'cola vacía' do
    it 'no toca SAP' do
      queue

      described_class.perform_now

      expect(Sap::CompanyClient).not_to have_received(:for)
    end
  end

  describe 'documento procesable' do
    it 'consulta el detalle y arma el objeto unificado' do
      queue(entry)
      allow(Documents::UnifiedBuilder).to receive(:new).and_call_original

      described_class.perform_now

      expect(Documents::UnifiedBuilder).to have_received(:new)
        .with(hash_including(company: company, doc_type: '01'))
    end

    # Una sesión de SAP por compañía, no una por documento: el pool del Client
    # indexa por compañía y `Sap::CompanyClient.for` revalida la configuración.
    it 'reutiliza el client entre documentos de la misma compañía' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))

      described_class.perform_now

      expect(Sap::CompanyClient).to have_received(:for).once
    end

    # Abrir el `.p12` descifra la llave privada y pedir el token es un viaje a
    # Hacienda: los dos son por compañía, no por documento.
    it 'reutiliza el firmador y el cliente de Hacienda entre documentos' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))

      described_class.perform_now

      expect(Hacienda::CompanySigner).to have_received(:for).once
      expect(Hacienda::Client).to have_received(:new).once
    end

    it 'firma el XML y lo envía a Hacienda' do
      queue(entry)

      described_class.perform_now

      expect(signer).to have_received(:sign).with(/<FacturaElectronica/)
      expect(hacienda).to have_received(:send_document)
        .with(hash_including(comprobante_xml: 'PEZhY3R1cmE+'))
    end

    # Enviar deja el comprobante EN TRÁNSITO: el `Location` es donde Hacienda va
    # a publicar la resolución, y es lo único que la pasada que la recoja
    # necesita para encontrarla.
    it 'deja el documento en Enviado con el Location, en la cola y en SAP' do
      queue(entry)

      described_class.perform_now

      expect(Documents::PendingQueue)
        .to have_received(:mark_sent).with(anything, 'https://api.test/recepcion/555')
      expect(client).to have_received(:patch)
        .with('Invoices(25)', body: hash_including('U_CL_FEC_Status' => 3))
    end

    # La fecha de emisión ante Hacienda solo tiene sentido cuando Hacienda de
    # verdad recibió el comprobante: por eso se manda únicamente en el envío
    # aceptado, nunca en un rechazo (ver el siguiente ejemplo).
    it 'manda U_CL_FEC_FechaEmision en el envío aceptado' do
      queue(entry)

      described_class.perform_now

      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_FechaEmision' => '2026-09-06T09:06:00Z'))
    end

    it 'NO manda U_CL_FEC_FechaEmision cuando Hacienda rechaza el envío, aunque ya la tenga' do
      queue(entry)
      allow(hacienda).to receive(:send_document)
        .and_raise(Hacienda::Client::RejectedError, 'La clave no cumple el formato')

      described_class.perform_now

      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_FechaEmision' => nil))
    end

    # El orden exacto (firmar → archivar → enviar) lo prueba
    # `spec/services/documents/issuer_spec.rb`; acá solo importa que la URL que
    # devuelve `Documents::XmlArchive` termina en `U_CL_FEC_XmlSentUrl`, junto
    # con la clave y el consecutivo que trajo SAP.
    it 'archiva el XML firmado y guarda la URL en SAP' do
      queue(entry)

      described_class.perform_now

      expect(Documents::XmlArchive).to have_received(:store_sent)
        .with(company: company, clave: '506123', xml: anything)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_XmlSentUrl' => xml_sent_url,
                                             'U_CL_FEC_Clave' => '506123'))
    end

    # El mismo número de estado en los dos lados: así lo que ve alguien en SAP y
    # lo que ve alguien en la cola se comparan sin traducir.
    it 'limpia el detalle de error de SAP cuando el envío sale bien' do
      queue(entry)

      described_class.perform_now

      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_ErrorDetails' => nil))
    end
  end

  # La UDT (destinatarios, `Sap::MailQueue`) se crea acá, tan pronto Hacienda
  # RECIBE el documento (`Sent`) — sin esperar la resolución de
  # `CheckSentDocumentsJob`, que es quien encola la cola EXTERNA.
  describe 'correo de recepción' do
    let(:mail_queue) { instance_double(Sap::MailQueue, create: '5') }

    before { allow(Sap::MailQueue).to receive(:new).and_return(mail_queue) }

    it 'encola en la UDT la posición 0 como destinatario y el resto en copia, cuando el envío queda Sent' do
      allow(client).to receive(:get) do |path|
        if path.match?(/HEADER/)
          [{ 'Clave' => '506123', 'RcprCorreoElectronico' => 'cliente@test.com;otro@test.com' }]
        else
          []
        end
      end
      queue(entry)

      described_class.perform_now

      expect(mail_queue).to have_received(:create).with(
        doc_entry: 25, doc_type: DocType::FE,
        output_to: 'cliente@test.com', output_cc: 'otro@test.com', output_bcc: nil
      )
    end

    it 'agrega los correos en copia de la compañía después de los de SAP' do
      company.update!(email_cc: 'cc1@test.com;cc2@test.com')
      allow(client).to receive(:get) do |path|
        if path.match?(/HEADER/)
          [{ 'Clave' => '506123', 'RcprCorreoElectronico' => 'cliente@test.com;otro@test.com' }]
        else
          []
        end
      end
      queue(entry)

      described_class.perform_now

      expect(mail_queue).to have_received(:create)
        .with(hash_including(output_cc: 'otro@test.com;cc1@test.com;cc2@test.com'))
    end

    it 'no encola nada sin destinatario en la cabecera' do
      queue(entry) # la cabecera del `before` general no trae `RcprCorreoElectronico`

      described_class.perform_now

      expect(Sap::MailQueue).not_to have_received(:new)
    end

    it 'no tumba el envío si falla el encolado del correo' do
      allow(client).to receive(:get) do |path|
        if path.match?(/HEADER/)
          [{ 'Clave' => '506123', 'RcprCorreoElectronico' => 'cliente@test.com' }]
        else
          []
        end
      end
      queue(entry)
      allow(Sap::MailQueue).to receive(:new).and_raise('SAP no responde')
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error
      expect(Documents::PendingQueue).to have_received(:mark_sent)
      expect(Sentry).to have_received(:capture_exception)
    end
  end

  # La pregunta que separa un desenlace del otro es si reintentar sin que nadie
  # toque nada puede funcionar.
  describe 'desenlaces del envío' do
    it 'marca Error con todas las reglas incumplidas cuando el documento no cuadra' do
      queue(entry)
      allow(Hacienda::InvoiceValidator).to receive(:new).and_return(
        instance_double(Hacienda::InvoiceValidator, call: Hacienda::InvoiceValidator::Result.new(
          errors: [Hacienda::InvoiceValidationError.new(message: 'Falta el CABYS.'),
                   Hacienda::InvoiceValidationError.new(message: 'El total no cuadra.')]
        ))
      )

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /2 regla\(s\).*Falta el CABYS.*El total no cuadra/)
      expect(hacienda).not_to have_received(:send_document)
    end

    it 'no firma ni envía un documento que no pasó las validaciones' do
      queue(entry)
      allow(Hacienda::InvoiceValidator).to receive(:new).and_return(
        instance_double(Hacienda::InvoiceValidator, call: Hacienda::InvoiceValidator::Result.new(
          errors: [Hacienda::InvoiceValidationError.new(message: 'Falta el CABYS.')]
        ))
      )

      described_class.perform_now

      expect(signer).not_to have_received(:sign)
    end

    it 'marca Error cuando Hacienda rechaza el envío por el documento' do
      queue(entry)
      allow(hacienda).to receive(:send_document)
        .and_raise(Hacienda::Client::RejectedError, 'La clave no cumple el formato')

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /La clave no cumple el formato/)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_Status' => 4))
    end

    # El documento SÍ se firmó y se archivó antes de que Hacienda lo rechazara:
    # `xml_sent_url` tiene que sobrevivir al rechazo y llegar a SAP igual, para
    # que quede rastro de qué se le mandó exactamente.
    it 'guarda xml_sent_url en SAP aunque Hacienda rechace el envío' do
      queue(entry)
      allow(hacienda).to receive(:send_document)
        .and_raise(Hacienda::Client::RejectedError, 'La clave no cumple el formato')

      described_class.perform_now

      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_XmlSentUrl' => xml_sent_url))
    end

    # Un documento que no pasa la validación nunca llega a firmarse ni a
    # archivarse: `xml_sent_url` tiene que quedar en `nil`, no inventado.
    it 'no manda xml_sent_url cuando el documento no pasó la validación' do
      queue(entry)
      allow(Hacienda::InvoiceValidator).to receive(:new).and_return(
        instance_double(Hacienda::InvoiceValidator, call: Hacienda::InvoiceValidator::Result.new(
          errors: [Hacienda::InvoiceValidationError.new(message: 'Falta el CABYS.')]
        ))
      )

      described_class.perform_now

      expect(Documents::XmlArchive).not_to have_received(:store_sent)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_XmlSentUrl' => nil, 'U_CL_FEC_Clave' => '506123'))
    end

    # Dejar la fila en `Processing` ES el reintento: el procedimiento la vuelve a
    # repartir a los diez minutos. Marcarla `Error` obligaría a volver a emitir
    # cada documento a mano desde SAP por media hora de Hacienda caída.
    it 'no marca nada cuando la falla es de Hacienda y no del documento' do
      queue(entry)
      allow(hacienda).to receive(:send_document)
        .and_raise(Hacienda::Client::TransientError, 'Hacienda no disponible')
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Documents::PendingQueue).not_to have_received(:mark_error)
      expect(Documents::PendingQueue).not_to have_received(:mark_sent)
      expect(client).not_to have_received(:patch)
      expect(Rails.logger).to have_received(:warn).with(/se reintenta solo/)
    end

    # A diferencia de Hacienda caída, un 401 al pedir el token es Hacienda
    # rechazando la credencial de la compañía: reintentar con la misma
    # contraseña mala nunca cambia el resultado (bug real visto en desarrollo,
    # igual que el del contenedor de Azure).
    it 'marca Error cuando Hacienda rechaza las credenciales del ATV al pedir el token' do
      queue(entry)
      allow(hacienda).to receive(:send_document).and_raise(
        Hacienda::Client::InvalidCredentials,
        'Hacienda no entregó el token de autenticación (HTTP 401 Unauthorized). ' \
        'Revise el usuario y la contraseña del ATV de la compañía y el Client ID configurado.'
      )
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /usuario y la contraseña del ATV/)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_Status' => 4))
      expect(Sentry).not_to have_received(:capture_exception)
    end

    it 'marca Error sin alertar cuando falta el certificado de la compañía' do
      queue(entry)
      allow(Hacienda::CompanySigner).to receive(:for)
        .and_raise(Hacienda::CompanySigner::MissingCertificate, 'no tiene certificado digital')
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /no tiene certificado digital/)
      expect(Sentry).not_to have_received(:capture_exception)
    end

    it 'marca Error sin alertar cuando falta un ajuste de Hacienda' do
      queue(entry)
      allow(hacienda).to receive(:send_document)
        .and_raise(Hacienda::Client::MissingConfiguration, 'Falta el ajuste HACIENDA_FE_URI_SEND')
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /HACIENDA_FE_URI_SEND/)
      expect(Sentry).not_to have_received(:capture_exception)
    end

    it 'marca Error sin alertar cuando falta un ajuste de Azure Storage' do
      queue(entry)
      allow(Documents::XmlArchive).to receive(:store_sent)
        .and_raise(Azure::BlobStorage::MissingConfiguration, 'Falta el ajuste AZURE_STORAGE_ACCOUNT_KEY')
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /AZURE_STORAGE_ACCOUNT_KEY/)
      expect(Sentry).not_to have_received(:capture_exception)
      expect(hacienda).not_to have_received(:send_document)
    end

    it 'marca Error sin alertar cuando la compañía no tiene cédula para archivar el XML' do
      queue(entry)
      allow(Documents::XmlArchive).to receive(:store_sent)
        .and_raise(Documents::XmlArchive::MissingIdNumber, 'no tiene número de identificación')
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /no tiene número de identificación/)
      expect(Sentry).not_to have_received(:capture_exception)
    end

    # Azure caído es tan transitorio como Hacienda caída: no es culpa del
    # documento, y reintentar sin tocar nada puede funcionar solo.
    it 'no marca nada cuando Azure Storage no responde' do
      queue(entry)
      allow(Documents::XmlArchive).to receive(:store_sent)
        .and_raise(Azure::BlobStorage::TransientError, 'Azure Storage no disponible')
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Documents::PendingQueue).not_to have_received(:mark_error)
      expect(Documents::PendingQueue).not_to have_received(:mark_sent)
      expect(hacienda).not_to have_received(:send_document)
      expect(Rails.logger).to have_received(:warn).with(/se reintenta solo/)
    end

    # A diferencia de Azure caído, un contenedor que no existe NUNCA se
    # arregla solo reintentando: dejarlo como transitorio (bug real, visto en
    # desarrollo) escondía el documento en `Processing` para siempre sin que
    # nadie se enterara por qué nunca avanzaba.
    it 'marca Error cuando Azure Storage rechaza la subida (contenedor inexistente)' do
      queue(entry)
      allow(Documents::XmlArchive).to receive(:store_sent).and_raise(
        Azure::BlobStorage::RejectedError,
        'Azure Storage rechazó la subida (HTTP 404 The specified container does not exist.).'
      )
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue).to have_received(:mark_error)
        .with(anything, /container does not exist/)
      expect(client).to have_received(:patch)
        .with(anything, body: hash_including('U_CL_FEC_Status' => 4))
      expect(Sentry).not_to have_received(:capture_exception)
    end
  end

  describe 'aislamiento de errores' do
    # Un documento que falla no puede dejar sin procesar a los que siguen.
    it 'sigue con el resto cuando uno revienta' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))
      call_count = 0
      allow(client).to receive(:get) do |path|
        call_count += 1
        raise 'SAP se cayó' if call_count == 1

        path.match?(/HEADER/) ? [{ 'Clave' => '506123' }] : []
      end
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error
      expect(Sentry).to have_received(:capture_exception).once
    end

    it 'omite el documento cuyo tipo no conoce' do
      queue(entry(doc_type: '99'))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(/El tipo de documento "99"/)
      expect(Sap::CompanyClient).not_to have_received(:for)
    end

    it 'omite el documento de una base de SAP sin compañía configurada' do
      queue(entry(sap_db: 'SBO_FANTASMA'))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(/No hay una compañía activa/)
    end

    it 'omite la compañía sin credenciales de licencia sin tratarlo como error' do
      queue(entry)
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'faltan credenciales')
      allow(Rails.logger).to receive(:warn)
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(/faltan credenciales/)
      expect(Sentry).not_to have_received(:capture_exception)
    end
  end

  # Sin esto la fila se queda en `Processing` —el estado en que la dejó el
  # reclamo— y desde afuera no hay dónde leer qué pasó.
  describe 'la falla vuelve a la cola' do
    it 'marca el error con el motivo cuando SAP revienta' do
      failing = entry(id: 7)
      queue(failing)
      allow(client).to receive(:get).and_raise('SAP se cayó')
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Documents::PendingQueue)
        .to have_received(:mark_error).with(failing, /SAP se cayó/)
    end

    it 'marca también el tipo desconocido, que si no reintentaría para siempre' do
      unknown = entry(doc_type: '99')
      queue(unknown)

      described_class.perform_now

      expect(Documents::PendingQueue)
        .to have_received(:mark_error).with(unknown, /no es un comprobante/)
    end

    it 'no marca error cuando el documento se envió bien' do
      queue(entry)

      described_class.perform_now

      expect(Documents::PendingQueue).not_to have_received(:mark_error)
      expect(Documents::PendingQueue).to have_received(:mark_sent)
    end

    # La cola es el registro del desenlace, no una dependencia para trabajar. Y
    # si no acepta la marca del envío, la fila se vuelve a repartir y el mismo
    # comprobante se le manda otra vez a Hacienda — que contesta que ya lo
    # tenía, y `Hacienda::Client` trata esa respuesta como un envío bueno.
    it 'sigue con el resto si la cola rechaza la marca del envío' do
      queue(entry(id: 1, doc_entry: 25), entry(id: 2, doc_entry: 26))
      allow(Documents::PendingQueue).to receive(:mark_sent)
        .and_raise(ExternalDb::QueryError, 'la cola no responde')
      allow(Sentry).to receive(:capture_exception)

      expect { described_class.perform_now }.not_to raise_error
      expect(hacienda).to have_received(:send_document).twice
    end

    # La cola es donde se anota la falla, no una dependencia para poder seguir:
    # si no acepta la marca, los documentos que siguen igual se procesan.
    it 'sigue con el resto si la cola rechaza la marca' do
      queue(entry(id: 1, doc_type: '99'), entry(id: 2, doc_entry: 26))
      allow(Documents::PendingQueue).to receive(:mark_error)
        .and_raise(ExternalDb::QueryError, 'la cola no responde')
      allow(Sentry).to receive(:capture_exception)
      allow(Documents::UnifiedBuilder).to receive(:new).and_call_original

      expect { described_class.perform_now }.not_to raise_error
      expect(Documents::UnifiedBuilder).to have_received(:new)
    end
  end

  describe 'base de documentos sin configurar' do
    # Corre cada dos minutos: dejarla fallar acumularía una ejecución fallida y un
    # evento en Sentry cada dos minutos, para siempre.
    it 'avisa y termina sin fallar' do
      allow(Documents::PendingQueue).to receive(:pending)
        .and_raise(ExternalDb::ConfigurationError, 'Faltan ajustes')
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/sin conexión a la base de documentos/)
    end

    # Una base caída sí es un fallo: la ejecución fallida es la señal correcta.
    it 'deja fallar cuando la base no responde' do
      allow(Documents::PendingQueue).to receive(:pending)
        .and_raise(ExternalDb::ConnectionError, 'servidor caído')

      expect { described_class.perform_now }.to raise_error(ExternalDb::ConnectionError)
    end
  end
end

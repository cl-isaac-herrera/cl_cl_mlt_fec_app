# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::Issuer do
  include HaciendaDocumentHelpers

  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:signer) { instance_double(Hacienda::XmlSigner, sign: 'c2lnbmVkLXhtbA==') }
  let(:hacienda) { instance_double(Hacienda::Client) }
  let(:receipt) { Hacienda::Client::Receipt.new(location: 'https://api.test/recepcion/1', duplicate: false) }
  let(:payload) do
    { 'DocType' => DocType::FE, 'Document' => valid_unified_document,
      'SendDocumentHacienda' => { 'fecha' => '2026-09-06T10:00:00-06:00',
                                 'emisor' => {}, 'receptor' => {} } }
  end

  def issuer(doc_type: DocType::FE)
    described_class.new(doc_type: doc_type, payload: payload, company: company,
                        signer: signer, hacienda: hacienda)
  end

  before do
    allow(Documents::XmlArchive).to receive(:store_sent)
      .and_return('https://azure.test/clvsfe/x/506123.xml')
    allow(hacienda).to receive(:send_document).and_return(receipt)
    # La validación XSD tiene su propio `describe` más abajo; acá se dobla en
    # "válido" para que el resto de los ejemplos —que prueban firmar, archivar
    # y enviar— no dependan de un esquema real cargado en `settings`.
    allow(Hacienda::SchemaStore).to receive(:for_doc_type)
      .and_return(instance_double(Nokogiri::XML::Schema, validate: []))
  end

  it 'firma el XML generado del documento' do
    issuer.call

    expect(signer).to have_received(:sign).with(/<FacturaElectronica/)
  end

  it 'archiva el XML firmado (ya decodificado, no el Base64) antes de enviarlo' do
    issuer.call

    expect(Documents::XmlArchive).to have_received(:store_sent)
      .with(company: company, clave: '5' * 50, xml: 'signed-xml')
  end

  it 'envía el comprobante después de archivarlo' do
    call_order = []
    allow(Documents::XmlArchive).to receive(:store_sent) do
      call_order << :archive
      'https://azure.test/clvsfe/x/506123.xml'
    end
    allow(hacienda).to receive(:send_document) do
      call_order << :send
      receipt
    end

    issuer.call

    expect(call_order).to eq(%i[archive send])
  end

  it 'expone la URL archivada después de llamar' do
    result = issuer

    result.call

    expect(result.xml_sent_url).to eq('https://azure.test/clvsfe/x/506123.xml')
  end

  # El documento SÍ se firmó y se archivó antes de que Hacienda lo rechazara:
  # `xml_sent_url` tiene que sobrevivir, para que el llamador pueda escribirla
  # en SAP aunque `#call` termine levantando.
  it 'conserva xml_sent_url aunque el envío a Hacienda falle después' do
    allow(hacienda).to receive(:send_document).and_raise(Hacienda::Client::RejectedError, 'rechazado')
    result = issuer

    expect { result.call }.to raise_error(Hacienda::Client::RejectedError)
    expect(result.xml_sent_url).to eq('https://azure.test/clvsfe/x/506123.xml')
  end

  it 'no envía nada si el archivado falla' do
    allow(Documents::XmlArchive).to receive(:store_sent)
      .and_raise(Azure::BlobStorage::TransientError, 'Azure no responde')

    expect { issuer.call }.to raise_error(Azure::BlobStorage::TransientError)
    expect(hacienda).not_to have_received(:send_document)
  end

  describe 'validación' do
    it 'valida factura electrónica y no llega a firmar si no cumple' do
      document = valid_unified_document
      document['CondicionVenta'] = nil
      payload['Document'] = document

      expect { issuer.call }.to raise_error(described_class::ValidationFailed)
      expect(signer).not_to have_received(:sign)
      expect(Documents::XmlArchive).not_to have_received(:store_sent)
    end

    it 'xml_sent_url queda en nil cuando la validación falla' do
      document = valid_unified_document
      document['CondicionVenta'] = nil
      payload['Document'] = document
      result = issuer

      expect { result.call }.to raise_error(described_class::ValidationFailed)
      expect(result.xml_sent_url).to be_nil
    end

    # El tiquete SÍ se valida: comparte todas las reglas de la factura menos la
    # identificación del receptor, que el legacy le exime (CLAUDE.md §39).
    it 'acepta un tiquete sin identificación del receptor' do
      document = valid_unified_document
      document['Receptor']['Identificacion'] = { 'Tipo' => nil, 'Numero' => nil }
      payload['Document'] = document

      expect { issuer(doc_type: DocType::TE).call }.not_to raise_error
      expect(signer).to have_received(:sign)
    end

    it 'valida el tiquete con las reglas que sí le aplican y no llega a firmar' do
      document = valid_unified_document
      document['Receptor']['Identificacion'] = { 'Tipo' => nil, 'Numero' => nil }
      document['CondicionVenta'] = nil
      payload['Document'] = document

      expect { issuer(doc_type: DocType::TE).call }.to raise_error(described_class::ValidationFailed)
      expect(signer).not_to have_received(:sign)
    end
  end

  # El esquema se dobla con `instance_double(Nokogiri::XML::Schema)`: lo que
  # `Hacienda::SchemaStore` hace con `settings`/Azure para llegar a ese objeto
  # ya lo prueba `spec/services/hacienda/schema_store_spec.rb`. Acá solo
  # importa qué hace `Issuer` con lo que el esquema devuelve.
  describe 'validación del XSD' do
    let(:schema_errors) { [Nokogiri::XML::SyntaxError.new("Element 'Clave': Esto no es válido.")] }

    it 'pide el esquema del tipo de comprobante que se está emitiendo' do
      issuer(doc_type: DocType::TE).call

      expect(Hacienda::SchemaStore).to have_received(:for_doc_type).with(DocType::TE)
    end

    it 'no llega a firmar si el XML no cumple el esquema de Hacienda' do
      allow(Hacienda::SchemaStore).to receive(:for_doc_type)
        .and_return(instance_double(Nokogiri::XML::Schema, validate: schema_errors))

      expect { issuer.call }.to raise_error(described_class::ValidationFailed)
      expect(signer).not_to have_received(:sign)
      expect(Documents::XmlArchive).not_to have_received(:store_sent)
    end

    it 'expone los incumplimientos del esquema tal como los devuelve Nokogiri' do
      allow(Hacienda::SchemaStore).to receive(:for_doc_type)
        .and_return(instance_double(Nokogiri::XML::Schema, validate: schema_errors))

      expect { issuer.call }.to raise_error(described_class::ValidationFailed) do |error|
        expect(error.errors).to eq(schema_errors)
      end
    end

    # Las reglas de negocio corren PRIMERO (paso 1): un documento que ya
    # incumple `DocumentValidator` no tiene por qué gastar ni siquiera el
    # `SELECT` de `Setting.value_for` que arma la ruta del esquema.
    it 'no consulta el esquema si las reglas de negocio ya rechazaron el documento' do
      document = valid_unified_document
      document['CondicionVenta'] = nil
      payload['Document'] = document

      expect { issuer.call }.to raise_error(described_class::ValidationFailed)
      expect(Hacienda::SchemaStore).not_to have_received(:for_doc_type)
    end

    it 'no encuentra incumplimientos y firma con normalidad cuando SÍ es válido' do
      issuer.call

      expect(signer).to have_received(:sign)
    end
  end
end

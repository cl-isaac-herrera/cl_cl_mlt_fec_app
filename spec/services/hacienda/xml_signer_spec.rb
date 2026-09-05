# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::XmlSigner do
  # La política de firma sale de `settings` (`db/seeds.rb` la reafirma en cada
  # instalación real); acá se declara a mano porque los specs no corren el seed.
  before do
    policy_url = 'https://tribunet.hacienda.go.cr/docs/esquemas/2016/v4.1/' \
                 'Resolucion_Comprobantes_Electronicos_DGT-R-48-2016.pdf'
    create(:setting, code: 'HACIENDA_XADES_POLICY_IDENTIFIER', value: policy_url)
    create(:setting, code: 'HACIENDA_XADES_POLICY_HASH', value: 'Ohixl6upD6av8N7pEvDABhEL6hM=')
  end

  # Certificado efímero, no un fixture binario: así el ejemplo no depende de un
  # `.p12` externo (con su propio vencimiento) y `build_p12` ya existe para
  # esto (`spec/support/company_files_helpers.rb`).
  let(:pin)      { 'clave-segura' }
  let(:p12_path) do
    directory = Dir.mktmpdir('xml-signer-spec')
    path = File.join(directory, 'cert.p12')
    File.binwrite(path, build_p12(pin: pin, expires_at: 1.year.from_now))
    path
  end

  # Un XML mínimo con la forma real de un comprobante: un elemento raíz con
  # namespace, que es justo el caso que ejercita el `enveloped-signature`
  # (la firma se inserta como último hijo de ESTE nodo).
  let(:unsigned_xml) do
    <<~XML
      <FacturaElectronica xmlns="https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/facturaElectronica">
        <Clave>50625082600310182273300100001010000010043125082026</Clave>
        <NumeroConsecutivo>00100001010000010043</NumeroConsecutivo>
      </FacturaElectronica>
    XML
  end

  def signed_doc(base64)
    Nokogiri::XML(Base64.strict_decode64(base64))
  end

  describe '#sign' do
    it 'devuelve el XML firmado en Base64, con la firma como último hijo de la raíz' do
      signer = described_class.new(p12_path, pin)

      doc = signed_doc(signer.sign(unsigned_xml))

      expect(doc.root.children.last.name).to eq('Signature')
      expect(doc.root.children.last.namespace.href).to eq(described_class::NS_DSIG)
    end

    it 'arma la política de firma DGT-R-48-2016 en las propiedades firmadas' do
      doc = signed_doc(described_class.new(p12_path, pin).sign(unsigned_xml))

      identifier = doc.at_xpath('//xades:Identifier',
                                'xades' => described_class::NS_XADES)

      expect(identifier.text).to include('DGT-R-48-2016')
    end

    # La auto-verificación (paso 8) es la garantía real: si esto pasa, los
    # cuatro digests y la firma RSA son consistentes entre sí y contra el
    # certificado — no solo "se ve como XML de firma".
    it 'la firma verifica criptográficamente contra el certificado' do
      signer = described_class.new(p12_path, pin)

      expect { signer.sign(unsigned_xml) }.not_to raise_error
    end

    it 'produce un id de firma distinto en cada llamada' do
      signer = described_class.new(p12_path, pin)

      first  = signed_doc(signer.sign(unsigned_xml)).root.children.last['Id']
      second = signed_doc(signer.sign(unsigned_xml)).root.children.last['Id']

      expect(first).not_to eq(second)
    end

    it 'levanta si el XML de entrada no es válido' do
      signer = described_class.new(p12_path, pin)

      expect { signer.sign('<abierto-sin-cerrar>') }.to raise_error(Nokogiri::XML::SyntaxError)
    end

    it 'acepta un IO además de un String' do
      signer = described_class.new(p12_path, pin)

      result = signer.sign(StringIO.new(unsigned_xml))

      expect { signed_doc(result) }.not_to raise_error
    end
  end

  describe '#initialize' do
    it 'levanta si el PIN no abre el certificado' do
      expect { described_class.new(p12_path, 'clave-incorrecta') }
        .to raise_error(OpenSSL::PKCS12::PKCS12Error)
    end
  end
end

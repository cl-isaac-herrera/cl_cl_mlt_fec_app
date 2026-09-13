# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::SchemaStore do
  let(:account)   { 'clviscofe' }
  let(:key)       { Base64.strict_encode64('una-clave-de-prueba-cualquiera') }
  let(:container) { 'clvsfe' }

  # El XSD real que usaba el .NET. Se lee del legacy a propósito: un esquema de
  # juguete no probaría que los archivos que el operador va a subir de verdad
  # compilan desde memoria, que es toda la premisa de esta clase.
  let(:legacy_xsd) do
    Rails.root.join('legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Docs/FacturaElectronica_V4.4.xsd').read
  end

  before do
    Hacienda::SchemaStore.clear_cache!

    azure_setting('AZURE_STORAGE_ACCOUNT_NAME', account)
    azure_setting('AZURE_STORAGE_ACCOUNT_KEY', key, is_visible: false)
    azure_setting('AZURE_STORAGE_CONTAINER', container)
  end

  after { Hacienda::SchemaStore.clear_cache! }

  def azure_setting(code, value, is_visible: true)
    Setting.unscoped.find_or_initialize_by(code: code).tap do |setting|
      setting.group_code  = 'AZURE_STORAGE'
      setting.description = code
      setting.is_visible  = is_visible
      setting.value       = value
      setting.save!
    end
  end

  def schema_setting(code, value)
    Setting.unscoped.find_or_initialize_by(code: code).tap do |setting|
      setting.group_code  = described_class::GROUP_CODE
      setting.description = code
      setting.is_visible  = true
      setting.value       = value
      setting.save!
    end
  end

  def stub_download(path, body: legacy_xsd, status: 200)
    stub_request(:get, "https://#{account}.blob.core.windows.net/#{container}/#{path}")
      .to_return(status: status, body: body)
  end

  describe 'el catálogo' do
    it 'resuelve el `code` de cada tipo de comprobante' do
      expect(described_class.code_for(DocType::FE)).to  eq('HACIENDA_XSD_01')
      expect(described_class.code_for(DocType::ND)).to  eq('HACIENDA_XSD_02')
      expect(described_class.code_for(DocType::NC)).to  eq('HACIENDA_XSD_03')
      expect(described_class.code_for(DocType::TE)).to  eq('HACIENDA_XSD_04')
      expect(described_class.code_for(DocType::FEC)).to eq('HACIENDA_XSD_08')
      expect(described_class.code_for(DocType::FEE)).to eq('HACIENDA_XSD_09')
      expect(described_class.code_for(DocType::REP)).to eq('HACIENDA_XSD_10')
    end

    # La razón de que sean NUEVE ajustes y no diez: el legacy valida los tres
    # mensajes con el mismo archivo (`Validations.cs` L248-256).
    it 'manda los TRES mensajes de receptor al mismo esquema' do
      codes = DocType::RECEIVER_MESSAGES.map { |type| described_class.code_for(type) }

      expect(codes.uniq).to eq(['HACIENDA_XSD_MENSAJE_RECEPTOR'])
    end

    it 'elige la variante del correo con `from_mail_parser`' do
      expect(described_class.code_for(DocType::AT, from_mail_parser: true))
        .to eq('HACIENDA_XSD_MENSAJE_RECEPTOR_MAIL_PARSER')
    end

    it 'normaliza el tipo antes de resolverlo' do
      expect(described_class.code_for('1')).to eq('HACIENDA_XSD_01')
    end

    it 'levanta con un tipo que no tiene esquema' do
      expect { described_class.code_for('99') }
        .to raise_error(described_class::NotConfigured, /99/)
    end

    it 'reconoce solo los `code` del catálogo' do
      expect(described_class.code?('HACIENDA_XSD_01')).to be(true)
      expect(described_class.code?('HACIENDA_XSD_05')).to be(false)
      expect(described_class.code?('CRYSTAL_PASSWORD')).to be(false)
    end
  end

  describe '.compile' do
    # La premisa de todo el diseño: el archivo no tiene que existir en el disco
    # del servidor.
    it 'construye el esquema desde los bytes, sin tocar el disco' do
      expect(described_class.compile(legacy_xsd)).to be_a(Nokogiri::XML::Schema)
    end

    it 'rechaza algo que no es XML' do
      expect { described_class.compile('no soy un xsd', code: 'HACIENDA_XSD_01') }
        .to raise_error(described_class::InvalidSchema, /Factura electrónica/)
    end

    # ⚠️ El hallazgo que define la regla del encabezado: un esquema construido
    # desde un String no tiene ruta base, así que libxml2 no resuelve NINGÚN
    # import. Los XSD publicados por Hacienda traen el de `xmldsig`; el legacy
    # lo dejó comentado en sus copias. Si esto alguna vez dejara de fallar,
    # sería porque algo empezó a salir a la red en medio de una emisión.
    it 'rechaza un XSD con un `xs:import` que no puede resolver' do
      with_import = <<~XSD
        <?xml version="1.0" encoding="UTF-8"?>
        <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
                   xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
          <xs:import namespace="http://www.w3.org/2000/09/xmldsig#"
                     schemaLocation="xmldsig-core-schema.xsd"/>
          <xs:element name="Raiz">
            <xs:complexType>
              <xs:sequence><xs:element ref="ds:Signature"/></xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>
      XSD

      expect { described_class.compile(with_import) }
        .to raise_error(described_class::InvalidSchema, /xmldsig-core-schema\.xsd/)
    end

    it 'no sale a la red a buscar un `schemaLocation` remoto' do
      remote = <<~XSD
        <?xml version="1.0" encoding="UTF-8"?>
        <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
                   xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
          <xs:import namespace="http://www.w3.org/2000/09/xmldsig#"
                     schemaLocation="https://www.w3.org/TR/xmldsig-core/xmldsig-core-schema.xsd"/>
          <xs:element name="Raiz" type="xs:string"/>
        </xs:schema>
      XSD

      # WebMock levantaría si se intentara la petición; el ejemplo pasa porque
      # libxml2 compila con NONET y ni lo intenta.
      expect(described_class.compile(remote)).to be_a(Nokogiri::XML::Schema)
    end
  end

  describe '.fetch' do
    it 'levanta NotConfigured cuando no hay archivo cargado' do
      schema_setting('HACIENDA_XSD_01', nil)

      expect { described_class.fetch('HACIENDA_XSD_01') }
        .to raise_error(described_class::NotConfigured,
                        /No se encuentra el archivo XSD configurado para Factura electrónica/)
    end

    it 'baja el blob y devuelve el esquema compilado' do
      path = 'xsd/HACIENDA_XSD_01/abc123/FacturaElectronica_V4.4.xsd'
      schema_setting('HACIENDA_XSD_01', path)
      request = stub_download(path)

      expect(described_class.fetch('HACIENDA_XSD_01')).to be_a(Nokogiri::XML::Schema)
      expect(request).to have_been_made.once
    end

    it 'no vuelve a bajarlo mientras la ruta no cambie' do
      path = 'xsd/HACIENDA_XSD_01/abc123/FacturaElectronica_V4.4.xsd'
      schema_setting('HACIENDA_XSD_01', path)
      request = stub_download(path)

      3.times { described_class.fetch('HACIENDA_XSD_01') }

      expect(request).to have_been_made.once
    end

    # El digest en la ruta es lo que hace que un proceso que lleva días arriba
    # se entere de que alguien subió un XSD nuevo desde la pantalla.
    it 'recompila cuando la ruta cambió, sin reiniciar el proceso' do
      vieja = 'xsd/HACIENDA_XSD_01/abc123/FacturaElectronica_V4.4.xsd'
      nueva = 'xsd/HACIENDA_XSD_01/def456/FacturaElectronica_V4.4.xsd'
      setting = schema_setting('HACIENDA_XSD_01', vieja)
      stub_download(vieja)
      nuevo_request = stub_download(nueva)

      described_class.fetch('HACIENDA_XSD_01')
      setting.update_value!(nueva)
      described_class.fetch('HACIENDA_XSD_01')

      expect(nuevo_request).to have_been_made.once
    end

    it 'levanta InvalidSchema si el blob guardado no compila' do
      path = 'xsd/HACIENDA_XSD_01/abc123/roto.xsd'
      schema_setting('HACIENDA_XSD_01', path)
      stub_download(path, body: 'esto no es un esquema')

      expect { described_class.fetch('HACIENDA_XSD_01') }
        .to raise_error(described_class::InvalidSchema)
    end
  end

  describe '.for_doc_type' do
    it 'resuelve el esquema del tipo de comprobante' do
      path = 'xsd/HACIENDA_XSD_04/abc123/TiqueteElectronico_V4.4.xsd'
      schema_setting('HACIENDA_XSD_04', path)
      stub_download(path)

      expect(described_class.for_doc_type(DocType::TE)).to be_a(Nokogiri::XML::Schema)
    end
  end

  describe '.blob_path' do
    it 'conserva el nombre original y deriva el digest del contenido' do
      path = described_class.blob_path(code: 'HACIENDA_XSD_01',
                                       file_name: 'FacturaElectronica_V4.4.xsd',
                                       content: legacy_xsd)

      expect(path).to start_with('xsd/HACIENDA_XSD_01/')
      expect(path).to end_with('/FacturaElectronica_V4.4.xsd')
      expect(described_class.file_name(path)).to eq('FacturaElectronica_V4.4.xsd')
    end

    it 'da la MISMA ruta para el mismo contenido y otra para uno distinto' do
      igual = described_class.blob_path(code: 'HACIENDA_XSD_01', file_name: 'x.xsd', content: legacy_xsd)
      otro  = described_class.blob_path(code: 'HACIENDA_XSD_01', file_name: 'x.xsd', content: "#{legacy_xsd} ")

      expect(described_class.blob_path(code: 'HACIENDA_XSD_01', file_name: 'x.xsd', content: legacy_xsd))
        .to eq(igual)
      expect(otro).not_to eq(igual)
    end
  end

  describe '.container' do
    it 'levanta con un mensaje accionable si falta el ajuste' do
      Setting.unscoped.find_by(code: 'AZURE_STORAGE_CONTAINER').update_value!(nil)

      expect { described_class.container }
        .to raise_error(Azure::BlobStorage::MissingConfiguration, /AZURE_STORAGE_CONTAINER/)
    end
  end
end

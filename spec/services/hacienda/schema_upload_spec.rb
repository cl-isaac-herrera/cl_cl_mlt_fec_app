# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::SchemaUpload do
  let(:account)   { 'clviscofe' }
  let(:key)       { Base64.strict_encode64('una-clave-de-prueba-cualquiera') }
  let(:container) { 'clvsfe' }
  let(:code)      { 'HACIENDA_XSD_01' }

  let(:legacy_xsd) do
    Rails.root.join('legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Docs/FacturaElectronica_V4.4.xsd').read
  end

  before do
    Hacienda::SchemaStore.clear_cache!

    azure_setting('AZURE_STORAGE_ACCOUNT_NAME', account)
    azure_setting('AZURE_STORAGE_ACCOUNT_KEY', key, is_visible: false)
    azure_setting('AZURE_STORAGE_CONTAINER', container)

    setting.update_value!(nil)
  end

  after { Hacienda::SchemaStore.clear_cache! }

  let(:setting) do
    Setting.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.group_code  = Hacienda::SchemaStore::GROUP_CODE
      record.description = code
      record.is_visible  = true
      record.save!
    end
  end

  def azure_setting(code, value, is_visible: true)
    Setting.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.group_code  = 'AZURE_STORAGE'
      record.description = code
      record.is_visible  = is_visible
      record.value       = value
      record.save!
    end
  end

  def blob_url(path) = "https://#{account}.blob.core.windows.net/#{container}/#{path}"

  def expected_path(content: legacy_xsd, file_name: 'FacturaElectronica_V4.4.xsd')
    Hacienda::SchemaStore.blob_path(code: code, file_name: file_name, content: content)
  end

  def xsd_upload(bytes = legacy_xsd, filename: 'FacturaElectronica_V4.4.xsd')
    uploaded_file(bytes, filename: filename, type: 'application/xml')
  end

  def stub_put(path)  = stub_request(:put, blob_url(path)).to_return(status: 201)
  def stub_del(path)  = stub_request(:delete, blob_url(path)).to_return(status: 202)

  describe 'validación previa' do
    # Lo importante no es que rechace: es que rechace SIN haber escrito nada en
    # Azure. Por eso cada ejemplo verifica que no salió ninguna petición.
    it 'rechaza una extensión que no sea .xsd' do
      expect { described_class.new(code: code, upload: xsd_upload(filename: 'esquema.xml')).call }
        .to raise_error(described_class::Error, /extensión \.xsd/)

      expect(a_request(:put, %r{blob\.core\.windows\.net})).not_to have_been_made
    end

    it 'rechaza un archivo vacío' do
      expect { described_class.new(code: code, upload: xsd_upload('')).call }
        .to raise_error(described_class::Error, /vacío/)
    end

    it 'rechaza un archivo que supera el tope de tamaño' do
      stub_const("#{Hacienda::SchemaStore}::MAX_BYTES", 10)

      expect { described_class.new(code: code, upload: xsd_upload).call }
        .to raise_error(described_class::Error, /tamaño máximo/)

      expect(a_request(:put, %r{blob\.core\.windows\.net})).not_to have_been_made
    end

    # El motivo de compilar ANTES de subir: un XSD roto se rechaza en la
    # pantalla y no en medio de una emisión.
    it 'rechaza un archivo que no compila como esquema, sin subir nada' do
      expect { described_class.new(code: code, upload: xsd_upload('no soy un esquema')).call }
        .to raise_error(Hacienda::SchemaStore::InvalidSchema)

      expect(a_request(:put, %r{blob\.core\.windows\.net})).not_to have_been_made
      expect(setting.reload.value).to be_nil
    end

    it 'rechaza un `code` que no está en el catálogo de la instalación' do
      expect { described_class.new(code: 'HACIENDA_XSD_99', upload: xsd_upload).call }
        .to raise_error(described_class::Error, /no existe en el catálogo/)
    end
  end

  describe 'carga' do
    it 'sube el blob y deja el ajuste apuntando a él' do
      path = expected_path
      request = stub_put(path)

      expect(described_class.new(code: code, upload: xsd_upload).call).to eq(path)
      expect(request).to have_been_made.once
      expect(setting.reload.value).to eq(path)
    end

    it 'conserva el nombre original del archivo en la ruta' do
      path = expected_path
      stub_put(path)

      described_class.new(code: code, upload: xsd_upload).call

      expect(Hacienda::SchemaStore.file_name(setting.reload.value))
        .to eq('FacturaElectronica_V4.4.xsd')
    end

    # El nombre forma parte de la ruta del blob: sin limpiarlo, un `/` cambiaría
    # a qué blob se escribe. Se descarta la carpeta que traiga —`../../` incluido—
    # y se reemplaza todo lo que no sea alfanumérico, punto, guion o guion bajo.
    it 'limpia el nombre antes de que forme parte de la ruta' do
      upload = xsd_upload(legacy_xsd, filename: '../../Factura Electrónica v4.4.xsd')
      path = expected_path(file_name: 'Factura_Electr_nica_v4.4.xsd')
      request = stub_put(path)

      described_class.new(code: code, upload: upload).call

      expect(request).to have_been_made.once
      expect(setting.reload.value).to eq(path)
      expect(setting.value).not_to include('..')
    end

    it 'borra el blob anterior cuando el contenido cambió' do
      anterior = 'xsd/HACIENDA_XSD_01/viejo123456789a/FacturaElectronica_V4.4.xsd'
      setting.update_value!(anterior)
      nuevo = expected_path
      stub_put(nuevo)
      borrado = stub_del(anterior)

      described_class.new(code: code, upload: xsd_upload).call

      expect(borrado).to have_been_made.once
    end

    # Mismo contenido ⇒ mismo digest ⇒ misma ruta: "el anterior" y "el nuevo"
    # son el mismo blob, y borrarlo dejaría el ajuste apuntando a nada.
    it 'NO borra nada cuando se vuelve a subir el mismo archivo' do
      path = expected_path
      setting.update_value!(path)
      stub_put(path)

      described_class.new(code: code, upload: xsd_upload).call

      expect(a_request(:delete, blob_url(path))).not_to have_been_made
      expect(setting.reload.value).to eq(path)
    end

    it 'no deja el ajuste escrito si Azure rechaza la subida' do
      stub_request(:put, blob_url(expected_path)).to_return(status: 404)

      expect { described_class.new(code: code, upload: xsd_upload).call }
        .to raise_error(Azure::BlobStorage::RejectedError)

      expect(setting.reload.value).to be_nil
    end

    # No poder borrar el blob viejo deja basura en el contenedor, no un ajuste
    # incorrecto: la carga tiene que terminar bien igual.
    it 'termina bien aunque el borrado del anterior falle' do
      anterior = 'xsd/HACIENDA_XSD_01/viejo123456789a/FacturaElectronica_V4.4.xsd'
      setting.update_value!(anterior)
      path = expected_path
      stub_put(path)
      stub_request(:delete, blob_url(anterior)).to_return(status: 500)

      expect(described_class.new(code: code, upload: xsd_upload).call).to eq(path)
      expect(setting.reload.value).to eq(path)
    end

    it 'deja de servir el esquema anterior desde el caché de este proceso' do
      anterior = 'xsd/HACIENDA_XSD_01/viejo123456789a/FacturaElectronica_V4.4.xsd'
      setting.update_value!(anterior)
      stub_request(:get, blob_url(anterior)).to_return(status: 200, body: legacy_xsd)
      Hacienda::SchemaStore.fetch(code)

      path = expected_path
      stub_put(path)
      stub_del(anterior)
      described_class.new(code: code, upload: xsd_upload).call

      nueva_lectura = stub_request(:get, blob_url(path)).to_return(status: 200, body: legacy_xsd)
      Hacienda::SchemaStore.fetch(code)

      expect(nueva_lectura).to have_been_made.once
    end
  end
end

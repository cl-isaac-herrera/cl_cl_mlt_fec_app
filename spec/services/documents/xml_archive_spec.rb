# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::XmlArchive do
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', issuer_id_number: '3101822733') }
  let(:uuid)    { company.uuid }
  let(:blob_storage) { instance_double(Azure::BlobStorage) }

  def azure_setting(code, value, description)
    Setting.unscoped.find_or_create_by!(code: code) do |s|
      s.group_code  = 'AZURE_STORAGE'
      s.description = description
    end.update!(value: value)
  end

  before do
    azure_setting('AZURE_STORAGE_CONTAINER', 'appfiles', 'Contenedor')
    azure_setting('AZURE_STORAGE_WORKSPACE', 'fec', 'Carpeta del producto')

    allow(Azure::BlobStorage).to receive(:new).and_return(blob_storage)
    allow(blob_storage).to receive(:upload).and_return('https://azure.test/appfiles/fec/x/xmls/506123.xml')
  end

  describe '.store_sent' do
    it 'sube a <workspace>/<uuid de la compañía>/xmls, con el nombre {clave}.xml' do
      described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>')

      expect(blob_storage).to have_received(:upload).with(
        container: 'appfiles', path: "fec/#{uuid}/xmls/506123.xml",
        content: '<Factura/>', content_type: 'application/xml'
      )
    end

    # La cédula salió de la ruta a propósito: se puede corregir, y corregirla
    # movería de carpeta a una compañía que ya tiene documentos archivados.
    it 'no usa la cédula en la ruta' do
      described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>')

      expect(blob_storage).to have_received(:upload) do |args|
        expect(args[:path]).not_to include('3101822733')
      end
    end

    it 'usa el workspace configurado, no uno fijo' do
      azure_setting('AZURE_STORAGE_WORKSPACE', 'fec-qa', 'Carpeta del producto')

      described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>')

      expect(blob_storage).to have_received(:upload)
        .with(hash_including(path: "fec-qa/#{uuid}/xmls/506123.xml"))
    end

    it 'devuelve la URL que reporta Azure::BlobStorage' do
      result = described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>')

      expect(result).to eq('https://azure.test/appfiles/fec/x/xmls/506123.xml')
    end
  end

  describe '.store_response' do
    it 'sube a la misma carpeta con el nombre {clave}_respuesta.xml' do
      described_class.store_response(company: company, clave: '506123', xml: '<MensajeHacienda/>')

      expect(blob_storage).to have_received(:upload).with(
        container: 'appfiles', path: "fec/#{uuid}/xmls/506123_respuesta.xml",
        content: '<MensajeHacienda/>', content_type: 'application/xml'
      )
    end
  end

  describe 'sin uuid de compañía' do
    it 'no sube nada si la compañía no tiene uuid' do
      company.update_column(:uuid, nil)

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(described_class::MissingUuid, /no tiene identificador/)
      expect(blob_storage).not_to have_received(:upload)
    end

    it 'no sube nada si el uuid tiene caracteres que cambiarían la ruta' do
      company.update_column(:uuid, '../otra-compania')

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(described_class::MissingUuid, /no es válido/)
      expect(blob_storage).not_to have_received(:upload)
    end
  end

  # Leer NO recompone la ruta: la saca de la URL que quedó guardada en SAP. Es lo
  # que hace que los documentos archivados antes del workspace se sigan bajando.
  describe '.fetch' do
    before { allow(blob_storage).to receive(:download).and_return('<Factura/>') }

    it 'parte la URL guardada en container/path y descarga el blob' do
      result = described_class.fetch("https://miempresa.blob.core.windows.net/appfiles/fec/#{uuid}/xmls/506123.xml")

      expect(blob_storage).to have_received(:download)
        .with(container: 'appfiles', path: "fec/#{uuid}/xmls/506123.xml")
      expect(result).to eq('<Factura/>')
    end

    it 'baja igual un XML archivado con la ruta vieja (bajo la cédula, sin workspace)' do
      described_class.fetch('https://miempresa.blob.core.windows.net/clvsfe/3101822733/506123.xml')

      expect(blob_storage).to have_received(:download)
        .with(container: 'clvsfe', path: '3101822733/506123.xml')
    end

    it 'decodifica los segmentos codificados en la URL antes de volver a pasarlos' do
      described_class.fetch('https://miempresa.blob.core.windows.net/appfiles/carpeta%20con%20espacio/x.xml')

      expect(blob_storage).to have_received(:download)
        .with(container: 'appfiles', path: 'carpeta con espacio/x.xml')
    end
  end

  # Las dos formas que produce `store_sent`/`store_response`. Se escriben
  # literales y no se obtienen llamándolos porque el doble de `upload` devuelve
  # siempre la misma URL: lo que se está probando es cómo se parte la URL, no
  # cómo se arma.
  describe '.file_name' do
    it 'devuelve el nombre del blob del comprobante' do
      expect(described_class.file_name('https://x.blob.core.windows.net/appfiles/fec/abc/xmls/506123.xml'))
        .to eq('506123.xml')
    end

    # El de respuesta lleva guion BAJO, no guion medio: así lo nombra
    # `store_response` y así quedó archivado en Azure.
    it 'devuelve el nombre del blob de la respuesta de Hacienda' do
      expect(described_class.file_name('https://x.blob.core.windows.net/appfiles/fec/abc/xmls/506_respuesta.xml'))
        .to eq('506_respuesta.xml')
    end

    it 'decodifica el nombre codificado en la URL' do
      expect(described_class.file_name('https://x.blob.core.windows.net/appfiles/fec/abc/con%20espacio.xml'))
        .to eq('con espacio.xml')
    end

    it 'devuelve nil cuando la URL no termina en un nombre' do
      expect(described_class.file_name('https://x.blob.core.windows.net/')).to be_nil
    end
  end

  describe 'sin los ajustes de la ruta' do
    it 'nombra el contenedor que falta' do
      Setting.find_by!(code: 'AZURE_STORAGE_CONTAINER').update!(value: nil)

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(Azure::BlobStorage::MissingConfiguration, /AZURE_STORAGE_CONTAINER/)
      expect(blob_storage).not_to have_received(:upload)
    end

    it 'nombra el workspace que falta' do
      Setting.find_by!(code: 'AZURE_STORAGE_WORKSPACE').update!(value: nil)

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(Azure::BlobStorage::MissingConfiguration, /AZURE_STORAGE_WORKSPACE/)
      expect(blob_storage).not_to have_received(:upload)
    end

    # Un workspace con `/` o `..` escribiría en la carpeta de otro producto.
    it 'rechaza un workspace que no sirve como carpeta' do
      azure_setting('AZURE_STORAGE_WORKSPACE', '../otro-producto', 'Carpeta del producto')

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(Azure::BlobStorage::InvalidConfiguration, /no es una carpeta válida/)
      expect(blob_storage).not_to have_received(:upload)
    end
  end
end

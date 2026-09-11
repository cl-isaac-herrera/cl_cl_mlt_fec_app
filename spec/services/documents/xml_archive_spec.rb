# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::XmlArchive do
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', issuer_id_number: '3101822733') }
  let(:blob_storage) { instance_double(Azure::BlobStorage) }

  before do
    Setting.find_or_create_by!(code: 'AZURE_STORAGE_CONTAINER') do |s|
      s.group_code = 'AZURE_STORAGE'
      s.description = 'x'
    end.update!(value: 'clvsfe')

    allow(Azure::BlobStorage).to receive(:new).and_return(blob_storage)
    allow(blob_storage).to receive(:upload).and_return('https://azure.test/clvsfe/3101822733/506123.xml')
  end

  describe '.store_sent' do
    it 'sube al contenedor fijo, bajo la cédula, con el nombre {clave}.xml' do
      described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>')

      expect(blob_storage).to have_received(:upload).with(
        container: 'clvsfe', path: '3101822733/506123.xml',
        content: '<Factura/>', content_type: 'application/xml'
      )
    end

    it 'devuelve la URL que reporta Azure::BlobStorage' do
      result = described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>')

      expect(result).to eq('https://azure.test/clvsfe/3101822733/506123.xml')
    end
  end

  # Sin llamador todavía (la pasada que recoge la resolución de Hacienda no
  # existe), pero la convención de nombre tiene que estar lista para cuando sí
  # exista — ver la cabecera de la clase.
  describe '.store_response' do
    it 'sube con el nombre {clave}_respuesta.xml' do
      described_class.store_response(company: company, clave: '506123', xml: '<MensajeHacienda/>')

      expect(blob_storage).to have_received(:upload).with(
        container: 'clvsfe', path: '3101822733/506123_respuesta.xml',
        content: '<MensajeHacienda/>', content_type: 'application/xml'
      )
    end
  end

  describe 'sin cédula' do
    it 'no sube nada si la compañía no tiene número de identificación' do
      company.update_column(:issuer_id_number, nil)

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(described_class::MissingIdNumber, /no tiene número de identificación/)
      expect(blob_storage).not_to have_received(:upload)
    end

    it 'no sube nada si la cédula tiene caracteres que cambiarían la ruta' do
      company.update_column(:issuer_id_number, '31018/22733')

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(described_class::MissingIdNumber, /no es válido/)
    end
  end

  describe '.fetch' do
    before { allow(blob_storage).to receive(:download).and_return('<Factura/>') }

    it 'parte la URL guardada en container/path y descarga el blob' do
      result = described_class.fetch('https://miempresa.blob.core.windows.net/clvsfe/3101822733/506123.xml')

      expect(blob_storage).to have_received(:download).with(container: 'clvsfe', path: '3101822733/506123.xml')
      expect(result).to eq('<Factura/>')
    end

    it 'decodifica los segmentos codificados en la URL antes de volver a pasarlos' do
      described_class.fetch('https://miempresa.blob.core.windows.net/clvsfe/carpeta%20con%20espacio/x.xml')

      expect(blob_storage).to have_received(:download).with(container: 'clvsfe', path: 'carpeta con espacio/x.xml')
    end
  end

  # Las dos formas que produce `store_sent`/`store_response`. Se escriben
  # literales y no se obtienen llamándolos porque el doble de `upload` devuelve
  # siempre la misma URL: lo que se está probando es cómo se parte la URL, no
  # cómo se arma.
  describe '.file_name' do
    it 'devuelve el nombre del blob del comprobante' do
      expect(described_class.file_name('https://x.blob.core.windows.net/clvsfe/3101822733/506123.xml'))
        .to eq('506123.xml')
    end

    # El de respuesta lleva guion BAJO, no guion medio: así lo nombra
    # `store_response` y así quedó archivado en Azure.
    it 'devuelve el nombre del blob de la respuesta de Hacienda' do
      expect(described_class.file_name('https://x.blob.core.windows.net/clvsfe/3101822733/506123_respuesta.xml'))
        .to eq('506123_respuesta.xml')
    end

    it 'decodifica el nombre codificado en la URL' do
      expect(described_class.file_name('https://x.blob.core.windows.net/clvsfe/310/con%20espacio.xml'))
        .to eq('con espacio.xml')
    end

    it 'devuelve nil cuando la URL no termina en un nombre' do
      expect(described_class.file_name('https://x.blob.core.windows.net/')).to be_nil
    end
  end

  describe 'sin el ajuste del contenedor' do
    it 'nombra el ajuste que falta' do
      Setting.find_by!(code: 'AZURE_STORAGE_CONTAINER').update!(value: nil)

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(Azure::BlobStorage::MissingConfiguration, /AZURE_STORAGE_CONTAINER/)
      expect(blob_storage).not_to have_received(:upload)
    end
  end
end

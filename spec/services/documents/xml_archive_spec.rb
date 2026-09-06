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

  describe 'sin el ajuste del contenedor' do
    it 'nombra el ajuste que falta' do
      Setting.find_by!(code: 'AZURE_STORAGE_CONTAINER').update!(value: nil)

      expect { described_class.store_sent(company: company, clave: '506123', xml: '<Factura/>') }
        .to raise_error(Azure::BlobStorage::MissingConfiguration, /AZURE_STORAGE_CONTAINER/)
      expect(blob_storage).not_to have_received(:upload)
    end
  end
end

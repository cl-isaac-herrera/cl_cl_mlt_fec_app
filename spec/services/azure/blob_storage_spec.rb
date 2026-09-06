# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Azure::BlobStorage do
  let(:account) { 'clviscofe' }
  let(:key) { Base64.strict_encode64('una-clave-de-prueba-cualquiera') }

  before do
    Setting.find_or_create_by!(code: 'AZURE_STORAGE_ACCOUNT_NAME') do |s|
      s.group_code = 'AZURE_STORAGE'
      s.description = 'x'
    end.update!(value: account)

    Setting.find_or_create_by!(code: 'AZURE_STORAGE_ACCOUNT_KEY') do |s|
      s.group_code = 'AZURE_STORAGE'
      s.description = 'x'
      s.is_visible = false
    end.update!(value: key)
  end

  # Reproduce el algoritmo "Authorize with Shared Key" de Microsoft de forma
  # INDEPENDIENTE al código de producción — no reutiliza ni un método privado
  # de `BlobStorage`, para que este spec de verdad verifique el cálculo y no
  # solo que la clase se llama a sí misma consistentemente.
  #
  # Referencia: "Authorize with Shared Key (REST API) - Azure Storage",
  # sección "Blob, Queue, and File Services (Shared Key authorization)".
  def expected_authorization(verb:, account:, key:, path:, date:, content_length:, content_type:)
    string_to_sign = [
      verb, '', '', content_length.zero? ? '' : content_length.to_s, '', content_type, '',
      '', '', '', '', ''
    ].join("\n") + "\n" +
      "x-ms-blob-type:BlockBlob\nx-ms-date:#{date}\nx-ms-version:2021-08-06\n" +
      "/#{account}#{path}"

    signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest('SHA256', Base64.strict_decode64(key), string_to_sign)
    )
    "SharedKey #{account}:#{signature}"
  end

  def stub_put(status: 201)
    stub_request(:put, "https://#{account}.blob.core.windows.net/clvsfe/3101822733/506123.xml")
      .to_return(status: status)
  end

  def upload(content: '<Factura/>')
    described_class.new.upload(container: 'clvsfe', path: '3101822733/506123.xml',
                               content: content, content_type: 'application/xml')
  end

  it 'devuelve la URL del blob cuando Azure acepta la subida' do
    stub_put

    expect(upload).to eq("https://#{account}.blob.core.windows.net/clvsfe/3101822733/506123.xml")
  end

  it 'firma la petición con el algoritmo Shared Key exacto de Microsoft' do
    stub_put

    upload

    expect(a_request(:put, %r{clvsfe/3101822733/506123\.xml}).with { |req|
      date = req.headers['X-Ms-Date']
      req.headers['Authorization'] == expected_authorization(
        verb: 'PUT', account: account, key: key, path: '/clvsfe/3101822733/506123.xml',
        date: date, content_length: '<Factura/>'.bytesize, content_type: 'application/xml'
      )
    }).to have_been_made
  end

  it 'manda los headers obligatorios de Put Blob para un block blob' do
    stub_put

    upload

    expect(a_request(:put, %r{506123\.xml}).with(headers: {
      'X-Ms-Blob-Type' => 'BlockBlob',
      'X-Ms-Version' => '2021-08-06',
      'Content-Type' => 'application/xml'
    })).to have_been_made
  end

  it 'manda el contenido tal cual, sin Base64 ni transformación' do
    stub_put

    upload(content: '<Factura>contenido</Factura>')

    expect(a_request(:put, %r{506123\.xml}).with(body: '<Factura>contenido</Factura>')).to have_been_made
  end

  describe 'fallas' do
    it 'un rechazo de Azure es transitorio' do
      stub_put(status: 403)

      expect { upload }.to raise_error(described_class::TransientError, /rechazó la subida/)
    end

    it 'un 5xx de Azure es transitorio' do
      stub_put(status: 503)

      expect { upload }.to raise_error(described_class::TransientError)
    end

    it 'un timeout es transitorio' do
      stub_request(:put, %r{506123\.xml}).to_timeout

      expect { upload }.to raise_error(described_class::TransientError, /No se pudo contactar/)
    end

    it 'un contenedor inexistente NO es transitorio' do
      stub_put(status: 404)

      expect { upload }.to raise_error(described_class::RejectedError, /rechazó la subida/)
    end

    it 'un 400 tampoco es transitorio' do
      stub_put(status: 400)

      expect { upload }.to raise_error(described_class::RejectedError)
    end
  end

  describe 'instalación a medio configurar' do
    it 'nombra el ajuste que falta' do
      Setting.find_by!(code: 'AZURE_STORAGE_ACCOUNT_KEY').update!(value: nil)

      expect { upload }.to raise_error(described_class::MissingConfiguration, /AZURE_STORAGE_ACCOUNT_KEY/)
    end
  end
end

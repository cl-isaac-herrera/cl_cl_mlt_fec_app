# frozen_string_literal: true

# Helpers para los specs que suben o leen un certificado digital.
#
# El `.p12` se arma en el momento en vez de guardar un binario como fixture: así
# se puede fijar la fecha de vencimiento que cada ejemplo necesita, y se prueba
# que la fecha sale de abrir el archivo y no de algo que mandó el cliente.
module CertificateHelpers
  # @param pin [String] clave con la que se protege el PKCS#12.
  # @param expires_at [Time] vencimiento que va a tener el certificado.
  # @return [String] el PKCS#12 en DER.
  def build_p12(pin:, expires_at:, subject: '/CN=ACME S.A.')
    key  = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version    = 2
    cert.serial     = 1
    cert.subject    = OpenSSL::X509::Name.parse(subject)
    cert.issuer     = cert.subject
    cert.public_key = key.public_key
    cert.not_before = expires_at - 1.year
    cert.not_after  = expires_at
    cert.sign(key, OpenSSL::Digest.new('SHA256'))

    OpenSSL::PKCS12.create(pin, 'ACME', key, cert).to_der
  end

  # `Rack::Test::UploadedFile` necesita un archivo en disco: el Tempfile vive lo
  # que dure el ejemplo.
  #
  # El tercer argumento (`binary`) es obligatorio: sin él, `Rack::Test` arma el
  # cuerpo multipart leyendo el archivo en modo texto y en Windows eso expande los
  # LF a CRLF y corta en el primer `0x1A`. El DER llega alterado y el ejemplo
  # falla por una razón que no tiene nada que ver con lo que prueba.
  def uploaded_file(bytes, filename: 'cert.p12', type: 'application/x-pkcs12')
    tempfile = Tempfile.new([File.basename(filename, '.*'), File.extname(filename)])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind

    Rack::Test::UploadedFile.new(tempfile.path, type, true, original_filename: filename)
  end

  # Apunta `FILES_BASE_PATH` a una carpeta descartable, para que los specs no
  # escriban en la raíz real ni dependan de que exista.
  def use_temporary_files_root
    root = Dir.mktmpdir('fec-files')
    allow(Rails.application.config).to receive(:files_base_path).and_return(root)
    root
  end
end

RSpec.configure do |config|
  config.include CertificateHelpers
end

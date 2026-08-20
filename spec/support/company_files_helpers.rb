# frozen_string_literal: true

# Helpers para los specs que suben o leen alguno de los tres archivos de una
# compañía: el certificado digital, el logo y el formato de impresión (ver
# `CompanyFiles::Store`).
#
# `build_p12` es del certificado; `uploaded_file` y `use_temporary_files_root`
# sirven para los tres.
module CompanyFilesHelpers
  # El `.p12` se arma en el momento en vez de guardar un binario como fixture:
  # así se puede fijar la fecha de vencimiento que cada ejemplo necesita, y se
  # prueba que la fecha sale de abrir el archivo y no de algo que mandó el
  # cliente.
  #
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

  # `Rack::Test::UploadedFile` necesita un archivo en disco. El archivo va en una
  # carpeta descartable propia y se limpia al terminar el ejemplo.
  #
  # **No se usa `Tempfile`** a propósito: su finalizador corre en cualquier GC y
  # borra el archivo, pero `Rack::Test` todavía lo tiene abierto — en Windows eso
  # escupe un `Errno::EACCES` con backtrace en medio de la corrida, sin relación
  # con el ejemplo que se estaba ejecutando.
  #
  # El tercer argumento (`binary`) es obligatorio: sin él, `Rack::Test` arma el
  # cuerpo multipart leyendo el archivo en modo texto y en Windows eso expande los
  # LF a CRLF y corta en el primer `0x1A`. El binario llega alterado y el ejemplo
  # falla por una razón que no tiene nada que ver con lo que prueba.
  #
  # `filename` puede traer barras o caracteres raros (los ejemplos que prueban
  # que el nombre se limpia antes de tocar el disco): eso viaja como
  # `original_filename` y el archivo real se guarda con el último segmento.
  def uploaded_file(bytes, filename: 'cert.p12', type: 'application/x-pkcs12')
    directory = Dir.mktmpdir('fec-upload')
    path      = File.join(directory, filename.to_s.split(%r{[/\\]}).last.presence || 'archivo')
    File.binwrite(path, bytes)

    upload = Rack::Test::UploadedFile.new(path, type, true, original_filename: filename)
    (@company_files_uploads ||= []) << [upload, directory]
    upload
  end

  # Apunta `FILES_BASE_PATH` a una carpeta descartable, para que los specs no
  # escriban en la raíz real ni dependan de que exista.
  def use_temporary_files_root
    root = Dir.mktmpdir('fec-files')
    allow(Rails.application.config).to receive(:files_base_path).and_return(root)
    root
  end

  # Cierra los handles y borra las carpetas de los archivos que se subieron. Es
  # best-effort: son carpetas del directorio temporal del sistema y no poder
  # borrar una no tiene por qué hacer fallar un ejemplo que ya pasó.
  def clean_up_uploaded_files
    Array(@company_files_uploads).each do |upload, directory|
      suppress(StandardError) { upload.close }
      suppress(StandardError) { FileUtils.remove_entry(directory) }
    end
  end
end

RSpec.configure do |config|
  config.include CompanyFilesHelpers
  config.after { clean_up_uploaded_files }
end

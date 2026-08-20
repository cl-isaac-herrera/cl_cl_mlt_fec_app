# frozen_string_literal: true

module Certificates
  # Abre un certificado `.p12` / `.pfx` con su PIN y devuelve la fecha en que
  # vence. Equivale a `CheckCertExpireDate` del API .NET, que hacía lo mismo del
  # otro lado del proxy.
  #
  # El archivo **no se guarda**: se lee del `UploadedFile` que Rack dejó en disco
  # temporalmente, se abre en memoria y se descarta al terminar el request. Esta
  # clase es solo lectura — quien quiera persistir el certificado necesita
  # resolver antes dónde vive el binario (`TODOS.md` → Compañías).
  #
  # Que el PIN sea el correcto y que el archivo sea un PKCS#12 de verdad son la
  # misma comprobación: si el MAC no verifica, OpenSSL no distingue "clave
  # equivocada" de "esto no es un .p12". Por eso el mensaje de error nombra las
  # dos causas en vez de afirmar una.
  #
  # Nunca levanta: cualquier fallo sale como un Result con su motivo, porque para
  # la pantalla todos significan lo mismo — de ese archivo no se puede sacar la
  # fecha.
  class ExpirationReader
    # Un PKCS#12 real pesa unos pocos KB. El tope existe para no leer a memoria
    # lo que alguien mande por el mismo campo; no es una regla de negocio.
    MAX_BYTES = 1.megabyte

    Result = Struct.new(:expires_at, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    # @param file [ActionDispatch::Http::UploadedFile, nil]
    # @param pin [String, nil]
    def initialize(file:, pin:)
      @file = file
      @pin  = pin.to_s
    end

    # @return [Result]
    def call
      missing = missing_prerequisite
      return failure(missing) if missing

      certificate = OpenSSL::PKCS12.new(binary_contents, @pin).certificate
      return failure('El archivo no contiene ningún certificado.') if certificate.nil?

      Result.new(expires_at: certificate.not_after)
    rescue OpenSSL::OpenSSLError
      # El motivo real (MAC verify failure, DER inválido) no se le pasa al
      # usuario: es ruido de OpenSSL y no le dice qué hacer.
      failure('No se pudo abrir el certificado. Verifique que el PIN sea el correcto y que el archivo sea un .p12 o .pfx válido.')
    end

    private

    # Un `.p12` es DER, no texto, y esta app corre en Windows: si el handle quedó
    # en modo texto, la lectura traduce CRLF y **corta en el primer byte `0x1A`**
    # (el EOF de DOS), que en un DER aparece por casualidad. El archivo llega
    # truncado y OpenSSL lo rechaza como si el PIN estuviera mal — se reprodujo
    # así, con 1391 de 2484 bytes.
    #
    # Por eso el modo binario se fuerza acá y no se da por sentado: quién abrió el
    # handle depende de la capa (el parser multipart de Rack, `Rack::Test` en los
    # specs) y no todas lo ponen.
    def binary_contents
      io = @file.respond_to?(:tempfile) ? @file.tempfile : @file
      io.binmode if io.respond_to?(:binmode)
      io.rewind  if io.respond_to?(:rewind)
      io.read
    end

    # @return [String, nil] motivo por el que ni vale la pena abrir el archivo.
    def missing_prerequisite
      return 'Seleccione el archivo del certificado.' unless @file.respond_to?(:read)
      return 'Ingrese el PIN del certificado.' if @pin.blank?
      return "El archivo del certificado supera el tamaño máximo (#{MAX_BYTES / 1.kilobyte} KB)." if too_big?

      nil
    end

    def too_big?
      @file.respond_to?(:size) && @file.size.to_i > MAX_BYTES
    end

    def failure(message) = Result.new(error: message)
  end
end

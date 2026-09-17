# frozen_string_literal: true

require 'zip'

module MailReception
  # Un documento electrónico (factura, nota de crédito, etc.) encontrado como
  # adjunto de un correo de recepción. Extrae lo mínimo que `MailReceptionJob`
  # necesita para archivar el .eml en la carpeta de la compañía correcta: la
  # `Clave` (el nombre con el que se archiva) y la identificación del
  # RECEPTOR (con qué compañía hacer el match, `Company#issuer_id_number`).
  #
  # A diferencia del legacy (`InvoiceHandler`, que deserializaba el XML
  # entero contra clases generadas del XSD de cada versión/tipo de documento,
  # duplicado casi verbatim en dos clases distintas), esto NO valida ni
  # interpreta el comprobante — solo necesita esos dos datos, y todos los
  # documentos que este producto ya emite (FE/TE/ND/NC/FEC/FEE/REP, CLAUDE.md
  # §39) comparten la misma forma para eso: un `<Clave>` y un
  # `<Receptor><Identificacion><Numero>`. Una consulta genérica por nombre
  # local de elemento (`remove_namespaces!`) alcanza, sin importar el tipo ni
  # la versión del esquema (4.3/4.4).
  class IncomingDocument
    Attachment = Struct.new(:clave, :receptor_id_number, keyword_init: true)

    # @param raw [String] los bytes del correo (RFC822/.eml).
    # @return [Array<Attachment>] uno por cada adjunto que parece un
    #   comprobante electrónico. Los demás adjuntos (un PDF, un XML que no es
    #   de Hacienda) se ignoran en silencio — no es un error, es correo que no
    #   le interesa a este job.
    def self.attachments_from(raw)
      message = ::Mail.read_from_string(raw)
      candidates(message).filter_map { |_name, bytes| parse(bytes) }
    end

    def self.candidates(message)
      message.attachments.flat_map do |part|
        zip?(part) ? zip_entries(part.body.decoded) : [[part.filename, part.body.decoded]]
      end
    end
    private_class_method :candidates

    def self.zip?(part)
      part.content_type.to_s.start_with?('application/zip', 'application/x-zip-compressed') ||
        part.filename.to_s.downcase.end_with?('.zip')
    end
    private_class_method :zip?

    # Entradas de un ZIP adjunto, aplanadas: algunos proveedores mandan el XML
    # del comprobante junto con el de la respuesta de Hacienda en el mismo
    # archivo (mismo comportamiento que `ExtractAttachmentsFromZip` del
    # legacy).
    def self.zip_entries(bytes)
      entries = []
      # `Zip::File.open_buffer` no devuelve lo que retorna el bloque —devuelve
      # el propio `StringIO`—, así que el resultado se captura adentro.
      Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
        entries = zip.filter_map { |entry| [entry.name, entry.get_input_stream.read] if entry.file? }
      end
      entries
    rescue Zip::Error
      []
    end
    private_class_method :zip_entries

    def self.parse(bytes)
      doc = Nokogiri::XML(bytes) { |cfg| cfg.strict }
      doc.remove_namespaces!

      clave = doc.at_xpath('//Clave')&.text&.strip
      receptor_id_number = doc.at_xpath('//Receptor/Identificacion/Numero')&.text&.strip
      return nil if clave.blank? || receptor_id_number.blank?

      Attachment.new(clave: clave, receptor_id_number: receptor_id_number)
    rescue Nokogiri::XML::SyntaxError
      nil
    end
    private_class_method :parse
  end
end

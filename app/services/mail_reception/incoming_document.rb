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
  # duplicado casi verbatim en dos clases distintas), esto solo distingue si
  # el adjunto ES un comprobante que este flujo procesa y extrae lo mínimo
  # para archivarlo (`Clave`, `Receptor/Identificacion/Numero`) — la
  # interpretación completa del XML (para las UDTs de mensaje receptor) vive
  # en `MailReception::ReceivedDocument`, que reutiliza el nodo raíz de acá.
  #
  # ── Qué tipo de documento se acepta ──────────────────────────────────────
  # SOLO FE (`01`), ND (`02`) y NC (`03`) — el mismo alcance que el mail
  # parser legacy, que detecta el elemento raíz por substring
  # (`Constants.cs:224-226`, `InboxHandler.cs:483-487`) y RECHAZA con
  # excepción cualquier otro tipo que reconoce (TE/FEC/FEE/REP,
  # `InvoiceHandler.cs:350-361`, "Please contact Clavisco for … acceptance.").
  # Confirmado con el usuario: los demás tipos no se recepcionan ni se
  # registran. El nombre del elemento raíz es la señal — la misma que usa el
  # legacy — y de paso descarta el `MensajeHacienda` (respuesta de Hacienda
  # que a veces viaja junto al comprobante en el mismo correo): su raíz nunca
  # aparece en esta lista.
  class IncomingDocument
    SUPPORTED_DOC_TYPES = [DocType::FE, DocType::ND, DocType::NC].freeze

    # `Hacienda::XmlBuilder::DOCUMENTS` ya tiene el nombre del elemento raíz
    # por tipo (`{doc_type => [root_name, namespace]}`) — se invierte acá en
    # vez de declarar una segunda copia de esos nombres.
    ROOT_ELEMENT_TO_DOC_TYPE = Hacienda::XmlBuilder::DOCUMENTS.slice(*SUPPORTED_DOC_TYPES)
                                                               .each_with_object({}) { |(doc_type, (root, _ns)), acc|
                                                                 acc[root] = doc_type
                                                               }.freeze

    # `root` es el `Nokogiri::XML::Element` raíz, con namespaces ya
    # removidos — se lo pasa a `MailReception::ReceivedDocument` para no
    # volver a parsear el mismo XML.
    Attachment = Struct.new(:clave, :receptor_id_number, :doc_type, :root, keyword_init: true)

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

      doc_type = ROOT_ELEMENT_TO_DOC_TYPE[doc.root&.name]
      return nil unless doc_type

      clave = doc.at_xpath('//Clave')&.text&.strip
      # `Receptor` es OPCIONAL en ND/NC (CLAUDE.md §39, `RECEPTOR_OPCIONAL`):
      # un documento válido de esos tipos puede no traerlo. Sin identificación
      # del receptor no hay con qué compañía hacer el match (`#archive`), así
      # que igual se descarta acá — es una limitación conocida del criterio de
      # match por `Receptor`, no algo que este método pueda resolver.
      receptor_id_number = doc.at_xpath('//Receptor/Identificacion/Numero')&.text&.strip
      return nil if clave.blank? || receptor_id_number.blank?

      Attachment.new(clave: clave, receptor_id_number: receptor_id_number, doc_type: doc_type, root: doc.root)
    rescue Nokogiri::XML::SyntaxError
      nil
    end
    private_class_method :parse
  end
end

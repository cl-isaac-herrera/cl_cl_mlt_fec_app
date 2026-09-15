# frozen_string_literal: true

module Documents
  # Lleva un documento ya armado desde el objeto unificado hasta Hacienda.
  #
  #   issuer = Documents::Issuer.new(
  #     doc_type: '01', payload: payload, company: company, signer: signer, hacienda: hacienda
  #   )
  #   receipt = issuer.call
  #   receipt.location    # => donde Hacienda va a publicar la resolución
  #   issuer.xml_sent_url # => la URL en Azure del XML que se firmó y se envió
  #
  # Es el paso 4 de `docs/sync-documents-flow.md` y son seis operaciones en
  # este orden, que no es negociable:
  #
  #   1. validar el objeto unificado  (`Hacienda::DocumentValidator`)
  #   2. generar el XML 4.4           (`Hacienda::XmlBuilder`)
  #   3. validarlo contra el XSD      (`Hacienda::SchemaStore`)
  #   4. firmarlo con XAdES-EPES      (`Hacienda::XmlSigner`)
  #   5. archivarlo en Azure          (`Documents::XmlArchive`)
  #   6. enviarlo                     (`Hacienda::Client`)
  #
  # Validar ANTES de firmar es lo que evita gastar una operación criptográfica
  # —y un envío— en un documento que ya se sabe que Hacienda va a rechazar.
  # Archivar ANTES de enviar es el mismo criterio del legacy
  # (`Transactions.cs`: sube a Azure y recién después llama `sendDocument`): si
  # no se pudo guardar una copia del comprobante, tampoco se manda — es
  # preferible no enviar a enviar sin dejar rastro de qué se envió.
  #
  # ── El paso 3 corre DESPUÉS de generar el XML, no antes ─────────────────────
  # El legacy (`Validations.cs#ValidateDocument`) corre su equivalente
  # (`ValidateXSD`) ANTES de `OwnValidations` — pero contra un objeto
  # intermedio que serializaba aparte para la ocasión
  # (`GetDocumentToValidateFETE`/`GetDocumentToValidateFEC`/…), no el XML que
  # de verdad firmaba y enviaba (ver `Hacienda::SchemaStore`). Acá no existe
  # ese objeto intermedio: lo único que el XSD tiene para comparar es el XML
  # real, y ese no existe hasta que `XmlBuilder` termina. Por eso el orden de
  # negocio-primero se conserva (paso 1) y el XSD corre sobre el resultado del
  # paso 2, no antes de él.
  #
  # ── `xml_sent_url` sobrevive a un envío fallido ─────────────────────────────
  # Se archiva ANTES de llamar a Hacienda, así que si el envío es rechazado o
  # falla de forma transitoria, `xml_sent_url` YA tiene la URL — el llamador la
  # lee del `Issuer` (no del `Receipt`, que en ese caso nunca se produce) para
  # escribirla en SAP igual: el documento SÍ se generó y se firmó, aunque
  # Hacienda no lo haya aceptado.
  #
  # ── Lo que esta clase NO hace: registrar el desenlace ───────────────────────
  # Devuelve el acuse o levanta, y nada más. Escribir el estado en la cola y en
  # SAP es del llamador (`SyncIssuedDocumentsJob`), que es el que sabe de qué
  # fila de la cola se trata y el que tiene que seguir con los documentos que
  # siguen si este falla.
  #
  # `signer` y `hacienda` se reciben ya construidos, no se arman acá: los dos
  # son POR COMPAÑÍA y se reutilizan entre los documentos de la tanda (abrir el
  # `.p12` descifra una llave privada y el token es un viaje a Hacienda). Ver
  # `Hacienda::CompanySigner.for` y `Hacienda::Client`.
  class Issuer
    # El documento no cumple las reglas de Hacienda. Lleva los errores tal como
    # los devolvió el validador, para que el llamador arme el mensaje que va a
    # leer quien tiene que corregir el documento en SAP.
    class ValidationFailed < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.map(&:message).join(' '))
      end
    end

    # La URL en Azure del XML firmado que se envió — o el que se intentó
    # enviar, si Hacienda lo rechazó después. `nil` hasta que el archivado
    # termine.
    attr_reader :xml_sent_url

    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param payload [Hash] lo que devuelve `Documents::UnifiedBuilder#call`.
    # @param company [Company] dueña del comprobante — la carpeta del archivo.
    # @param signer [Hacienda::XmlSigner]
    # @param hacienda [Hacienda::Client]
    def initialize(doc_type:, payload:, company:, signer:, hacienda:)
      @doc_type = doc_type
      @payload = payload
      @company = company
      @signer = signer
      @hacienda = hacienda
    end

    # @return [Hacienda::Client::Receipt]
    # @raise [ValidationFailed] el documento no pasa las reglas de Hacienda, ya
    #   sea las de negocio o las del esquema XSD.
    # @raise [Hacienda::XmlBuilder::UnsupportedDocType, Hacienda::XmlBuilder::InvalidValue]
    # @raise [Hacienda::SchemaStore::NotConfigured, Hacienda::SchemaStore::InvalidSchema]
    # @raise [Documents::XmlArchive::MissingUuid, Azure::BlobStorage::MissingConfiguration,
    #   Azure::BlobStorage::TransientError, Azure::BlobStorage::RejectedError]
    # @raise [Hacienda::Client::TransientError, Hacienda::Client::RejectedError,
    #   Hacienda::Client::MissingConfiguration]
    def call
      validate!

      xml = Hacienda::XmlBuilder.new(payload).call
      validate_schema!(xml)

      signed = signer.sign(xml)
      archive(signed)

      hacienda.send_document(
        clave: document['Clave'],
        comprobante_xml: signed,
        fecha: send_info['fecha'],
        emisor: send_info['emisor'],
        receptor: send_info['receptor']
      )
    end

    private

    attr_reader :doc_type, :payload, :company, :signer, :hacienda

    # `signed` es el Base64 que espera Hacienda (`XmlSigner#sign`); el archivo
    # que se guarda es el XML real, así que se decodifica antes de subirlo —
    # nadie quiere abrir `{clave}.xml` y encontrarse un Base64 más.
    def archive(signed)
      @xml_sent_url = XmlArchive.store_sent(company: company, clave: document['Clave'],
                                            xml: Base64.decode64(signed))
    end

    def document = payload['Document'] || {}

    def send_info = payload['SendDocumentHacienda'] || {}

    # ── Se valida todo lo que este producto sabe emitir ──────────────────────
    # El legacy corre `Validations.cs#OwnValidations` para TODOS los tipos y
    # excluye reglas puntuales según el `DocType`; acá se replica esa forma, así
    # que la pregunta no es "¿qué tipo se valida?" sino "¿qué regla no aplica a
    # este tipo?" — y eso lo resuelve cada validador (CLAUDE.md §39).
    #
    # `VALIDATED_DOC_TYPES` coincide con lo que `Hacienda::XmlBuilder` sabe
    # generar, de modo que ningún comprobante se firme y se envíe sin pasar
    # antes por las reglas. Un tipo fuera de esa lista no llega a este
    # método: `XmlBuilder` lo corta con `UnsupportedDocType` un paso después.
    # El guard queda igual para que agregar un tipo al builder sin revisar sus
    # exclusiones no lo deje emitiéndose a ciegas.
    def validate!
      return unless Hacienda::DocumentValidator.validates?(doc_type)

      result = Hacienda::DocumentValidator.new(document, doc_type: doc_type).call
      return if result.valid?

      raise ValidationFailed, result.errors
    end

    # ── El XSD es la MISMA fuente de errores que las reglas de negocio ────────
    # `Nokogiri::XML::Schema#validate` ya acumula TODOS los incumplimientos de
    # una pasada —no el primero—, y cada `Nokogiri::XML::SyntaxError` responde
    # a `#message` igual que un `Hacienda::DocumentValidationError`. Por eso se
    # reutiliza `ValidationFailed` tal cual en vez de una excepción aparte:
    # `SyncIssuedDocumentsJob` no necesita distinguir cuál de los dos
    # validadores rechazó el documento, y el mensaje que arma para SAP le
    # sirve a los dos por igual.
    #
    # `cfg.strict` —igual que `Hacienda::XmlSigner#sign`— es lo que hace que un
    # XML mal formado (un bug de `XmlBuilder`, nunca algo que dependa del
    # documento) levante en vez de validarse en silencio contra un DOM
    # recuperado a medias.
    def validate_schema!(xml)
      xml_document = Nokogiri::XML(xml) { |cfg| cfg.strict }
      errors = Hacienda::SchemaStore.for_doc_type(doc_type).validate(xml_document)
      return if errors.empty?

      raise ValidationFailed, errors
    end
  end
end

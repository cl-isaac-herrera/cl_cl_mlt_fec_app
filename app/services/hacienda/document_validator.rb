# frozen_string_literal: true

module Hacienda
  # Valida el objeto unificado de un comprobante contra las reglas de negocio
  # de Hacienda, antes de generar y firmar su XML.
  #
  #   result = Hacienda::DocumentValidator.new(payload['Document'], doc_type: DocType::FE).call
  #   result.valid?   # => false
  #   result.errors   # => [#<Hacienda::DocumentValidationError …>, …]
  #
  # @param document [Hash] la clave `'Document'` del payload que arma
  #   `Documents::UnifiedBuilder` — NO el payload completo (ese también trae
  #   `DocType` y `SendDocumentHacienda`, que este validador no necesita).
  # @param doc_type [String] código de Hacienda (`DocType::FE`, `DocType::TE`,
  #   `DocType::ND`, `DocType::NC`).
  #
  # ── Origen y alcance ─────────────────────────────────────────────────────
  # Las reglas vienen de `Validations.cs#OwnValidations` del sistema .NET
  # (`legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Validations.cs`), que es UN SOLO
  # método para TODOS los tipos de comprobante: recibe el `DocType` y lo usa
  # para excluir reglas puntuales, nunca para saltarse el bloque entero.
  #
  # Acá se replica esa forma. Las reglas migradas son las que aplican a
  # factura, tiquete y notas de crédito/débito; las que el legacy marca como
  # exclusivas de Factura de Compra/Exportación o de Recibo de Pago quedan
  # para cuando se migren esos tipos. La regla de migración está en CLAUDE.md
  # §39: una regla que no aplica a un tipo se excluye DENTRO del validador,
  # con el tipo como condición — no salteándose el validador completo, que
  # dejaría pasar sin verificar todas las demás.
  #
  # ── Los cuatro tipos comparten casi TODAS las reglas ─────────────────────
  # De todo `OwnValidations`, lo único que distingue a FE de TE/ND/NC es la
  # identificación del receptor (`Validations.cs` L324 y L329), y vive en
  # `Validations::HeaderValidator::RECEPTOR_OPCIONAL`. El bloque de
  # referencias es el otro caso con matiz, y el único donde ND/NC piden MÁS
  # que la factura y no menos — ver `#validate_references`.
  #
  # ── Por qué acumula en vez de cortar en el primer error ─────────────────
  # El legacy es fail-fast: el primer `throw` interrumpe todo, así que un
  # documento con diez problemas se corrige de a uno por intento. Acá se
  # corren TODOS los bloques y se devuelven todos los errores de una sola
  # pasada — mejor para quien tiene que corregir el documento en SAP, y no
  # cambia qué documentos pasan o no pasan: solo cuánto tarda enterarse de
  # todo lo que falta.
  #
  # ── Por qué son ocho colaboradores y no un método gigante ────────────────
  # Cada uno vive en `app/services/hacienda/validations/` y cubre un bloque
  # autocontenido del legacy (cabecera, condición de venta, líneas, otros
  # cargos, moneda, totales, referencias). Ninguno conoce a los demás; este
  # orquestador solo los llama en orden y junta lo que devuelven.
  class DocumentValidator
    # Los tipos cuyas reglas están migradas y revisadas una por una contra el
    # legacy. `Documents::Issuer` lo consulta para saber a qué comprobante
    # aplicarle este validador.
    #
    # Es exactamente lo que `Hacienda::XmlBuilder` sabe generar hoy, y no es
    # casualidad: un tipo que se pueda emitir sin poder validarse iría a
    # Hacienda a ciegas. Al agregar uno acá hay que revisar antes cada
    # exclusión por tipo de `Validations.cs` (CLAUDE.md §39).
    VALIDATED_DOC_TYPES = [DocType::FE, DocType::TE, DocType::ND, DocType::NC].freeze

    # Tipos que NO validan `InformacionReferencia`.
    #
    # El legacy corre ese bloque solo cuando el documento NO es un tiquete
    # (`Validations.cs` L817; para TE ninguna de las dos ramas da verdadero).
    # Se replica: un tiquete con referencia declarada pasa sin revisarla, que
    # es lo que hace el sistema en producción hoy.
    REFERENCIAS_NO_VALIDADAS = [DocType::TE].freeze

    # Tipos que EXIGEN al menos una `InformacionReferencia`.
    #
    # Esta regla no sale de `OwnValidations` —ahí la referencia se revisa si
    # viene, pero nadie cuenta cuántas hay— sino del XSD, que es el otro
    # validador que el legacy corre antes (`Validations.cs#ValidateXSD`, con
    # `pathNCXSD`/`pathNDXSD`): `InformacionReferencia` es `maxOccurs="10"` sin
    # `minOccurs`, o sea mínimo UNA, mientras que en el de factura es
    # `minOccurs="0"`. Y es lo único que ese XSD pide de más.
    #
    # Tiene sentido de negocio y por eso se replica acá en vez de dejarla para
    # el rechazo de Hacienda: una nota de crédito o de débito existe para
    # corregir OTRO comprobante, así que sin decir cuál no corrige nada.
    REFERENCIAS_REQUERIDAS = [DocType::ND, DocType::NC].freeze

    Result = Data.define(:errors) do
      def valid? = errors.empty?
    end

    # ¿Este validador cubre ese tipo de comprobante?
    def self.validates?(doc_type) = VALIDATED_DOC_TYPES.include?(doc_type)

    def initialize(document, doc_type:)
      @document = document
      @doc_type = doc_type
    end

    # @return [Hacienda::DocumentValidator::Result]
    def call
      errors = [
        *Validations::HeaderValidator.new(document, doc_type: doc_type).call,
        *Validations::SalesConditionValidator.new(document).call,
        *Validations::CurrencyValidator.new(document).call,
        *Validations::SummaryTotalsValidator.new(document).call,
        *validate_lines,
        *validate_other_charges,
        *validate_references
      ]

      Result.new(errors: errors)
    end

    private

    attr_reader :document, :doc_type

    def validate_lines
      lines = document['DetalleServicio'] || []
      lines.each_with_index.flat_map do |line, index|
        Validations::LineItemValidator.new(line, index + 1).call
      end
    end

    def validate_other_charges
      charges = document['OtrosCargos'] || []
      charges.flat_map { |charge| Validations::OtherChargeValidator.new(charge).call }
    end

    def validate_references
      return [] if REFERENCIAS_NO_VALIDADAS.include?(doc_type)

      references = document['InformacionReferencia'] || []
      return [referencia_requerida] if references.empty? && REFERENCIAS_REQUERIDAS.include?(doc_type)

      references.flat_map { |reference| Validations::ReferenceValidator.new(reference).call }
    end

    def referencia_requerida
      DocumentValidationError.new(
        message: "#{DocType.label(doc_type)} debe indicar el documento que corrige en la " \
                 'información de referencia.',
        field: 'InformacionReferencia'
      )
    end
  end
end

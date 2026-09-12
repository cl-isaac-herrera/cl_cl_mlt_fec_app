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
  # @param doc_type [String] código de Hacienda (`DocType::FE`, `DocType::TE`).
  #
  # ── Origen y alcance ─────────────────────────────────────────────────────
  # Las reglas vienen de `Validations.cs#OwnValidations` del sistema .NET
  # (`legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Validations.cs`), que es UN SOLO
  # método para TODOS los tipos de comprobante: recibe el `DocType` y lo usa
  # para excluir reglas puntuales, nunca para saltarse el bloque entero.
  #
  # Acá se replica esa forma. Las reglas migradas son las que aplican a
  # factura y tiquete; las que el legacy marca como exclusivas de Factura de
  # Compra/Exportación o de Recibo de Pago quedan para cuando se migren esos
  # tipos. La regla de migración está en CLAUDE.md §39: una regla que no
  # aplica a un tipo se excluye DENTRO del validador, con el tipo como
  # condición — no salteándose el validador completo, que dejaría pasar sin
  # verificar todas las demás.
  #
  # ── Factura y tiquete comparten TODAS las reglas menos una ───────────────
  # De todo `OwnValidations`, lo único que distingue FE de TE es la
  # identificación del receptor (`Validations.cs` L324 y L329), y vive en
  # `Validations::HeaderValidator::RECEPTOR_OPCIONAL`. El bloque de
  # referencias es el otro caso con matiz — ver `#validate_references`.
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
    VALIDATED_DOC_TYPES = [DocType::FE, DocType::TE].freeze

    # Tipos que NO validan `InformacionReferencia`.
    #
    # El legacy corre ese bloque solo cuando el documento NO es un tiquete
    # (`Validations.cs` L817; para TE ninguna de las dos ramas da verdadero).
    # Se replica: un tiquete con referencia declarada pasa sin revisarla, que
    # es lo que hace el sistema en producción hoy.
    REFERENCIAS_NO_VALIDADAS = [DocType::TE].freeze

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
      references.flat_map { |reference| Validations::ReferenceValidator.new(reference).call }
    end
  end
end

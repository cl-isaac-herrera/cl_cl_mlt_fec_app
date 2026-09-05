# frozen_string_literal: true

module Hacienda
  # Valida el objeto unificado de una FACTURA ELECTRÓNICA (`DocType::FE`)
  # contra las reglas de negocio de Hacienda, antes de generar y firmar su XML.
  #
  #   result = Hacienda::InvoiceValidator.new(payload['Document']).call
  #   result.valid?   # => false
  #   result.errors   # => [#<Hacienda::InvoiceValidationError …>, …]
  #
  # @param document [Hash] la clave `'Document'` del payload que arma
  #   `Documents::UnifiedBuilder` — NO el payload completo (ese también trae
  #   `DocType` y `SendDocumentHacienda`, que este validador no necesita).
  #
  # ── Origen y alcance ─────────────────────────────────────────────────────
  # Las reglas vienen de `Validations.cs#OwnValidations` del sistema .NET
  # (`legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Validations.cs`), y solo las que
  # aplican a Factura Electrónica (DocType `01`) — las excluidas explícitas
  # (Nota de Crédito, Nota de Débito, Tiquete, Factura de Compra/Exportación,
  # Recibo de Pago) se dejan para cuando este producto migre esos tipos, con
  # el mismo patrón de colaboradores.
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
  class InvoiceValidator
    Result = Data.define(:errors) do
      def valid? = errors.empty?
    end

    def initialize(document)
      @document = document
    end

    # @return [Hacienda::InvoiceValidator::Result]
    def call
      errors = [
        *Validations::HeaderValidator.new(document).call,
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

    attr_reader :document

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
      references = document['InformacionReferencia'] || []
      references.flat_map { |reference| Validations::ReferenceValidator.new(reference).call }
    end
  end
end

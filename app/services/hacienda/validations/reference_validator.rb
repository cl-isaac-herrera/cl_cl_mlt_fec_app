# frozen_string_literal: true

module Hacienda
  module Validations
    # Reglas de un elemento de `InformacionReferencia`. Origen:
    # `Validations.cs#OwnValidations`, bloque H (reglas #68-72).
    #
    # ── Simplificación deliberada frente al legacy ────────────────────────
    # El .NET solo corre este bloque cuando `Situacion != 1` (el documento
    # está en contingencia o es una sustitución) — un dato que no viaja en el
    # objeto unificado (`Documents::UnifiedBuilder` no lo expone; ver
    # `docs/sync-documents-flow.md`). En Factura Electrónica normal el XSD
    # deja `InformacionReferencia` opcional (`minOccurs="0"`), así que la
    # regla que sí se puede aplicar sin ese dato es la más segura: SI hay una
    # referencia declarada, tiene que estar bien formada. No se intenta
    # replicar la condición de `Situacion`.
    class ReferenceValidator
      include Catalogs

      def initialize(reference)
        @reference = reference
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        [
          tipo_documento_valido,
          numero_requerido,
          fecha_emision_requerida,
          *codigo_y_razon
        ].compact
      end

      private

      attr_reader :reference

      # Regla #68.
      def tipo_documento_valido
        tipo = reference['TipoDocIR']
        return nil if TIPO_DOC_REFERENCIA.include?(tipo)

        error("El tipo de documento de referencia #{tipo.inspect} no es válido.", field: 'TipoDocIR')
      end

      # Regla #69.
      def numero_requerido
        return nil if reference['Numero'].present?

        error('El número del documento de referencia es requerido.', field: 'Numero')
      end

      # Regla #70.
      def fecha_emision_requerida
        return nil if reference['FechaEmisionIR'].present?

        error('La fecha de emisión del documento de referencia es requerida.', field: 'FechaEmisionIR')
      end

      # Reglas #71-72: facturación de mes vencido (13) exime código y razón.
      def codigo_y_razon
        return [] if reference['TipoDocIR'] == TIPO_DOC_REFERENCIA_MES_VENCIDO

        errors = []
        codigo = reference['Codigo']
        if codigo.blank?
          errors << error('El código del documento de referencia es requerido.', field: 'Codigo')
        elsif !CODIGO_REFERENCIA.include?(codigo)
          errors << error("El código del documento de referencia #{codigo.inspect} no es válido.",
                          field: 'Codigo')
        end

        if reference['Razon'].blank?
          errors << error('La razón del documento de referencia es requerida.', field: 'Razon')
        end

        errors
      end

      def error(message, field:)
        InvoiceValidationError.new(message: message, field: field)
      end
    end
  end
end

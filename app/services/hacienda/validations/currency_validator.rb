# frozen_string_literal: true

module Hacienda
  module Validations
    # `CodigoMoneda` y `TipoCambio` del resumen de factura. Origen:
    # `Validations.cs#OwnValidations`, reglas #49-51.
    class CurrencyValidator
      include Catalogs

      def initialize(document)
        @document = document
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        codigo = document.dig('ResumenFactura', 'CodigoTipoMoneda', 'CodigoMoneda')

        return [error('El código de moneda es requerido.', field: 'CodigoTipoMoneda.CodigoMoneda')] if codigo.blank?

        errors = []
        unless CODIGO_MONEDA_PATTERN.match?(codigo)
          errors << error("El código de moneda #{codigo.inspect} no tiene el formato ISO 4217 " \
                          '(tres letras mayúsculas).', field: 'CodigoTipoMoneda.CodigoMoneda')
        end
        errors.concat(validate_tipo_cambio(codigo))
        errors
      end

      private

      attr_reader :document

      # Reglas #50-51.
      def validate_tipo_cambio(codigo)
        tipo_cambio = document.dig('ResumenFactura', 'CodigoTipoMoneda', 'TipoCambio')

        if codigo == MONEDA_LOCAL
          return [] if tipo_cambio == BigDecimal(1)

          [error('El tipo de cambio debe ser 1 para la moneda local (CRC).',
                 field: 'CodigoTipoMoneda.TipoCambio')]
        else
          return [] if tipo_cambio.present? && tipo_cambio.positive?

          [error('El tipo de cambio es requerido para una moneda extranjera.',
                 field: 'CodigoTipoMoneda.TipoCambio')]
        end
      end

      def error(message, field:)
        InvoiceValidationError.new(message: message, field: field)
      end
    end
  end
end

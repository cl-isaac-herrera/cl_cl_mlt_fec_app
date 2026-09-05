# frozen_string_literal: true

module Hacienda
  module Validations
    # Cruce entre `CondicionVenta`, `PlazoCredito` y los medios de pago del
    # resumen. Origen: `Validations.cs#OwnValidations`, reglas #11-16.
    class SalesConditionValidator
      include Catalogs

      def initialize(document)
        @document = document
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        condicion = document['CondicionVenta']

        return validate_credito if CONDICIONES_DE_CREDITO.include?(condicion)
        return validate_contado if condicion == CONDICION_VENTA_CONTADO
        return validate_otros   if condicion == CONDICION_VENTA_OTROS

        []
      end

      private

      attr_reader :document

      # Reglas #11-12: en crédito, el plazo es obligatorio y el medio de pago
      # NO puede cubrir el total — si lo cubriera, no sería una venta a
      # crédito. La tolerancia es la misma que el cuadre de totales.
      def validate_credito
        errors = []
        plazo = document['PlazoCredito']

        if plazo.nil? || plazo <= 0
          errors << error('El plazo de crédito es requerido cuando la venta es a crédito.',
                          field: 'PlazoCredito')
        end

        total_medios = sum_medios_pago
        total_comprobante = document.dig('ResumenFactura', 'TotalComprobante')
        if total_medios.present? && total_comprobante.present? &&
           total_medios >= total_comprobante - TOLERANCE
          errors << error(
            'La suma de los medios de pago no puede cubrir el total del comprobante ' \
            'en una venta a crédito.',
            field: 'ResumenFactura.MedioPago'
          )
        end

        errors
      end

      # Reglas #13-15: en contado, el plazo debe ser cero, el medio de pago es
      # obligatorio y su suma debe cuadrar contra el total.
      def validate_contado
        errors = []
        plazo = document['PlazoCredito']

        if plazo.present? && plazo != 0
          errors << error('El plazo de crédito debe ser cero para la condición de venta Contado.',
                          field: 'PlazoCredito')
        end

        medios = document.dig('ResumenFactura', 'MedioPago') || []
        if medios.empty?
          errors << error('El medio de pago es requerido para la condición de venta Contado.',
                          field: 'ResumenFactura.MedioPago')
        else
          total_medios = sum_medios_pago
          total_comprobante = document.dig('ResumenFactura', 'TotalComprobante')
          if total_medios.present? && total_comprobante.present? &&
             (total_medios - total_comprobante).abs > TOLERANCE
            errors << error(
              'La suma de los medios de pago debe ser igual al total del comprobante ' \
              'para la condición de venta Contado.',
              field: 'ResumenFactura.MedioPago'
            )
          end
        end

        errors
      end

      # Regla #16.
      def validate_otros
        return [] if document['CondicionVentaOtros'].present?

        [error('El detalle de "condición de venta otros" es requerido cuando ' \
               'CondicionVenta es 99.', field: 'CondicionVentaOtros')]
      end

      def sum_medios_pago
        medios = document.dig('ResumenFactura', 'MedioPago') || []
        return nil if medios.empty?

        medios.sum { |medio| medio['TotalMedioPago'] || BigDecimal(0) }
      end

      def error(message, field: nil)
        InvoiceValidationError.new(message: message, field: field)
      end
    end
  end
end

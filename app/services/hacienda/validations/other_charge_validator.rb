# frozen_string_literal: true

module Hacienda
  module Validations
    # Reglas de un elemento de `OtrosCargos`. Origen: `Validations.cs`,
    # bloque de otros cargos (reglas #42, #45-48 del reporte de la migración).
    #
    # La regla #43 (bloquear tercero en FEE/FEC) no aplica: este validador es
    # solo para Factura Electrónica.
    class OtherChargeValidator
      include Catalogs

      def initialize(charge)
        @charge = charge
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        [
          tipo_documento_valido,
          *tercero_requerido,
          detalle_requerido,
          porcentaje_no_negativo,
          porcentaje_o_monto_presente,
          monto_cargo_positivo
        ].compact
      end

      private

      attr_reader :charge

      # Regla #42.
      def tipo_documento_valido
        tipo = charge['TipoDocumentoOC']
        return nil if TIPO_DOCUMENTO_OTROS_CARGOS.include?(tipo)

        error("El tipo de documento de otros cargos #{tipo.inspect} no es válido.",
              field: 'TipoDocumentoOC')
      end

      # Regla #44: cobro de un tercero exige su identificación y nombre.
      def tercero_requerido
        return [] unless charge['TipoDocumentoOC'] == TIPO_OTROS_CARGOS_COBRO_TERCERO

        errors = []
        if charge.dig('IdentificacionTercero', 'Numero').blank?
          errors << error('La identificación del tercero es requerida para el cobro de un tercero.',
                          field: 'IdentificacionTercero.Numero')
        end
        if charge['NombreTercero'].blank?
          errors << error('El nombre del tercero es requerido para el cobro de un tercero.',
                          field: 'NombreTercero')
        end
        errors
      end

      # Regla #45.
      def detalle_requerido
        return nil if charge['Detalle'].present?

        error('El detalle de otros cargos es requerido.', field: 'Detalle')
      end

      # Regla #46.
      def porcentaje_no_negativo
        porcentaje = charge['PorcentajeOC']
        return nil if porcentaje.nil? || !porcentaje.negative?

        error('El porcentaje de otros cargos no puede ser negativo.', field: 'PorcentajeOC')
      end

      # Regla #47: uno de los dos tiene que traer un valor real.
      def porcentaje_o_monto_presente
        porcentaje = charge['PorcentajeOC'] || BigDecimal(0)
        monto      = charge['MontoCargo'] || BigDecimal(0)
        return nil if porcentaje.positive? || monto.positive?

        error('El porcentaje y el monto de otros cargos no pueden ser cero los dos a la vez.',
              field: 'PorcentajeOC')
      end

      # Regla #48.
      def monto_cargo_positivo
        monto = charge['MontoCargo']
        return nil if monto.present? && monto.positive?

        error('El monto de otros cargos tiene que ser mayor a cero.', field: 'MontoCargo')
      end

      def error(message, field:)
        InvoiceValidationError.new(message: message, field: field)
      end
    end
  end
end

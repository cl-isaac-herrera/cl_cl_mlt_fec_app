# frozen_string_literal: true

module Hacienda
  module Validations
    # Reglas de un elemento de `OtrosCargos`. Origen: `Validations.cs`,
    # bloque de otros cargos (reglas #42, #45-48 del reporte de la migración).
    #
    # El bloque entero corre para todos los tipos menos Recibo de Pago
    # (`Validations.cs` L630). Lo único que depende del tipo es el tercero:
    # ver `TERCERO_PROHIBIDO`.
    class OtherChargeValidator
      include Catalogs

      # Tipos donde el cobro por cuenta de un tercero NO EXISTE.
      #
      # `Validations.cs` L639 no lo vuelve opcional: lo **prohíbe**. Si la
      # factura de compra o la de exportación traen `NumeroIdentidadTercero` o
      # `NombreTercero`, el legacy corta con "es inexistente en este tipo de
      # documento", y el `else` —el que exige los dos cuando el tipo de
      # documento del cargo es `04`— no llega a correr.
      #
      # Es coherente con lo que esos comprobantes son: un cargo que se le
      # cobra a un tercero supone que hay un tercero en la operación, y en una
      # compra a un proveedor que no factura la operación tiene dos partes.
      #
      # FEE se lista porque el legacy lo exime igual, aunque este producto
      # todavía no lo emita — la lista describe la regla, no lo que hoy se
      # puede mandar.
      TERCERO_PROHIBIDO = [DocType::FEC, DocType::FEE].freeze

      # @param charge [Hash] un elemento de `document['OtrosCargos']`.
      # @param doc_type [String] código de Hacienda. Sin default a propósito:
      #   de él depende si el tercero es obligatorio o está prohibido, y un
      #   default silencioso haría que un tipo nuevo herede la regla contraria.
      def initialize(charge, doc_type:)
        @charge = charge
        @doc_type = doc_type
      end

      # @return [Array<Hacienda::DocumentValidationError>]
      def call
        [
          tipo_documento_valido,
          *validate_tercero,
          detalle_requerido,
          porcentaje_no_negativo,
          porcentaje_o_monto_presente,
          monto_cargo_positivo
        ].compact
      end

      private

      attr_reader :charge, :doc_type

      # Regla #42.
      def tipo_documento_valido
        tipo = charge['TipoDocumentoOC']
        return nil if TIPO_DOCUMENTO_OTROS_CARGOS.include?(tipo)

        error("El tipo de documento de otros cargos #{tipo.inspect} no es válido.",
              field: 'TipoDocumentoOC')
      end

      # Regla #43/#44. Las dos mitades del mismo `if/else` del legacy: o el
      # tercero está prohibido, o es obligatorio cuando el cargo es un cobro
      # por su cuenta. Nunca las dos, nunca ninguna.
      def validate_tercero
        return tercero_prohibido if TERCERO_PROHIBIDO.include?(doc_type)

        tercero_requerido
      end

      # Regla #43 (`Validations.cs` L639).
      def tercero_prohibido
        errors = []
        if charge.dig('IdentificacionTercero', 'Numero').present?
          errors << error("#{DocType.label(doc_type)} no lleva cobros por cuenta de un tercero, " \
                          'así que su identificación no corresponde.',
                          field: 'IdentificacionTercero.Numero')
        end
        if charge['NombreTercero'].present?
          errors << error("#{DocType.label(doc_type)} no lleva cobros por cuenta de un tercero, " \
                          'así que su nombre no corresponde.',
                          field: 'NombreTercero')
        end
        errors
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
        DocumentValidationError.new(message: message, field: field)
      end
    end
  end
end

# frozen_string_literal: true

module Hacienda
  module Validations
    # Reglas de la cabecera del comprobante: código de actividad, condición de
    # venta y las identificaciones de emisor/receptor.
    #
    # Origen: `Validations.cs#OwnValidations`, bloque de cabecera (reglas #2,
    # #4-10 del reporte de la migración). Se excluyeron las reglas que el
    # legacy marca como "no aplica a Factura Electrónica" (#1, #3: solo FEE/FEC).
    class HeaderValidator
      include Catalogs

      # @param document [Hash] `payload['Document']`, tal como lo arma
      #   `Documents::UnifiedBuilder`.
      def initialize(document)
        @document = document
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        errors = []

        errors << actividad_emisor_requerida
        errors << condicion_venta_valida
        errors << tipo_identificacion_emisor_valido
        errors.concat(validate_receptor)

        errors.compact
      end

      private

      attr_reader :document

      # Regla #2. `CodigoActividadReceptor` (regla #3) NO se valida acá: es
      # solo para Factura de Compra, que este validador no cubre.
      def actividad_emisor_requerida
        return nil if document['CodigoActividadEmisor'].present?

        error('El código de actividad del emisor es requerido.', field: 'CodigoActividadEmisor')
      end

      # Regla #4.
      def condicion_venta_valida
        condicion = document['CondicionVenta']
        return nil if CONDICION_VENTA.include?(condicion)

        error("La condición de venta #{condicion.inspect} no es permitida.", field: 'CondicionVenta')
      end

      # Regla #5. El del receptor no se exige acá si el receptor es libre —
      # ver `#validate_receptor`, que sí lo hace obligatorio para FE.
      def tipo_identificacion_emisor_valido
        tipo = document.dig('Emisor', 'Identificacion', 'Tipo')
        return nil if TIPO_IDENTIFICACION.include?(tipo)

        error("El tipo de identificación del emisor #{tipo.inspect} no es permitido.",
              field: 'Emisor.Identificacion.Tipo')
      end

      # Reglas #6-10. En Factura Electrónica el tipo y el número del receptor
      # SON obligatorios (a diferencia de Tiquete, Nota de Crédito y Nota de
      # Débito, que los legacy exime).
      def validate_receptor
        tipo   = document.dig('Receptor', 'Identificacion', 'Tipo')
        numero = document.dig('Receptor', 'Identificacion', 'Numero')
        errors = []

        if tipo.blank?
          errors << error('El tipo de identificación del receptor es requerido.',
                          field: 'Receptor.Identificacion.Tipo')
        elsif !TIPO_IDENTIFICACION.include?(tipo)
          errors << error("El tipo de identificación del receptor #{tipo.inspect} no es permitido.",
                          field: 'Receptor.Identificacion.Tipo')
        end

        if numero.blank?
          errors << error('El número de identificación del receptor es requerido.',
                          field: 'Receptor.Identificacion.Numero')
        elsif tipo.present? && (longitudes = LONGITUD_IDENTIFICACION[tipo]) && longitudes.exclude?(numero.length)
          errors << error(
            "La identificación del receptor tiene #{numero.length} caracteres; " \
            "para el tipo #{tipo.inspect} se esperaban #{longitudes.join(' o ')}.",
            field: 'Receptor.Identificacion.Numero'
          )
        end

        errors
      end

      def error(message, field: nil)
        InvoiceValidationError.new(message: message, field: field)
      end
    end
  end
end

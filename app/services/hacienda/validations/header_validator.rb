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

      # Tipos que NO están obligados a identificar al receptor.
      #
      # Es la única regla de todo `OwnValidations` que distingue entre factura y
      # tiquete (`Validations.cs` L324 y L329, que excluyen TE, ND y NC). Un
      # tiquete a un cliente que no da su cédula es el caso NORMAL, así que
      # exigirla rechazaría documentos correctos.
      #
      # ND y NC se listan porque el legacy los exime, aunque este producto
      # todavía no los emita: la lista describe la regla, no lo que hoy se
      # puede mandar. Ver CLAUDE.md §39.
      RECEPTOR_OPCIONAL = [DocType::TE, DocType::ND, DocType::NC].freeze

      # @param document [Hash] `payload['Document']`, tal como lo arma
      #   `Documents::UnifiedBuilder`.
      # @param doc_type [String] código de Hacienda (`DocType::FE`, …). Sin
      #   default a propósito: de él depende si el receptor es obligatorio, y un
      #   default silencioso haría que un tipo nuevo herede la regla equivocada.
      def initialize(document, doc_type:)
        @document = document
        @doc_type = doc_type
      end

      # @return [Array<Hacienda::DocumentValidationError>]
      def call
        errors = []

        errors << actividad_emisor_requerida
        errors << condicion_venta_valida
        errors << tipo_identificacion_emisor_valido
        errors.concat(validate_receptor)

        errors.compact
      end

      private

      attr_reader :document, :doc_type

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

      # Reglas #6-10.
      #
      # Quién está OBLIGADO a identificar al receptor depende del tipo
      # (`RECEPTOR_OPCIONAL`); el resto de las reglas NO dependen del tipo y
      # corren siempre. Un tiquete puede no traer receptor, pero si lo trae
      # tiene que estar bien: el legacy valida el formato y la longitud con un
      # `if` que no excluye a nadie (`Validations.cs` L334, L339, L344).
      #
      # Dicho de otro modo: lo que se exime es EXIGIRLO, no revisarlo.
      def validate_receptor
        tipo   = document.dig('Receptor', 'Identificacion', 'Tipo')
        numero = document.dig('Receptor', 'Identificacion', 'Numero')

        return [] if tipo.blank? && numero.blank? && receptor_opcional?

        validate_receptor_tipo(tipo) + validate_receptor_numero(tipo, numero)
      end

      def receptor_opcional? = RECEPTOR_OPCIONAL.include?(doc_type)

      def validate_receptor_tipo(tipo)
        if tipo.blank?
          # Solo se llega acá con un tipo obligatorio, o con el número puesto y
          # el tipo no (que es incoherente en cualquier comprobante).
          return [error('El tipo de identificación del receptor es requerido.',
                        field: 'Receptor.Identificacion.Tipo')]
        end

        return [] if TIPO_IDENTIFICACION.include?(tipo)

        [error("El tipo de identificación del receptor #{tipo.inspect} no es permitido.",
               field: 'Receptor.Identificacion.Tipo')]
      end

      # El número es obligatorio cuando lo es para el tipo de comprobante y
      # también cuando se declaró un tipo de identificación: media identificación
      # no identifica a nadie (`Validations.cs` L339).
      def validate_receptor_numero(tipo, numero)
        return validate_receptor_longitud(tipo, numero) if numero.present?
        return [] if receptor_opcional? && tipo.blank?

        [error('El número de identificación del receptor es requerido.',
               field: 'Receptor.Identificacion.Numero')]
      end

      # La longitud se mide contra el tipo declarado. Sin tipo —o con uno fuera
      # del catálogo— no hay contra qué compararla, y de ese faltante ya avisó
      # `#validate_receptor_tipo`: repetirlo acá sería el mismo problema dicho
      # dos veces.
      def validate_receptor_longitud(tipo, numero)
        longitudes = tipo.present? ? LONGITUD_IDENTIFICACION[tipo] : nil
        return [] if longitudes.nil? || longitudes.include?(numero.length)

        [error(
          "La identificación del receptor tiene #{numero.length} caracteres; " \
          "para el tipo #{tipo.inspect} se esperaban #{longitudes.join(' o ')}.",
          field: 'Receptor.Identificacion.Numero'
        )]
      end

      def error(message, field: nil)
        DocumentValidationError.new(message: message, field: field)
      end
    end
  end
end

# frozen_string_literal: true

module Hacienda
  module Validations
    # Recalcula los totales de `ResumenFactura` a partir de las líneas y
    # verifica que cuadren entre sí. Origen: `Validations.cs#OwnValidations`,
    # bloques F (reglas #52-58, recompute desde líneas) y G (reglas #59-67,
    # cuadre de los totales del resumen entre ellos).
    #
    # Si el documento no tiene líneas, el legacy **no ejecuta este bloque en
    # absoluto** — no hay error, pero tampoco se valida nada de totales. Se
    # replica esa misma omisión: un documento sin `DetalleServicio` no puede
    # pasar por acá y sería un caso raro que otra regla debería atrapar antes.
    class SummaryTotalsValidator
      include Catalogs

      # Regla #56: una mercancía gravada bajo régimen especial de fábrica
      # (venta exenta) NO cuenta como gravada en el total recalculado.
      IVA_COBRADO_FABRICA_EXENTO = '02'

      def initialize(document)
        @document = document
        @lines = document['DetalleServicio'] || []
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        return [] if lines.empty?

        [
          *recomputed_total_errors,
          *cross_total_errors
        ]
      end

      private

      attr_reader :document, :lines

      def resumen = document['ResumenFactura']

      # ── Bloque F: recalcular desde las líneas (reglas #52-58) ────────────
      def recomputed_total_errors
        servicio, mercancia = lines.partition { |line| unidad_de_servicio?(line) }

        [
          compare_total('TotalServNoSujeto', sum_no_sujeto(servicio)),
          compare_total('TotalServGravados', sum_gravado(servicio)),
          compare_total('TotalServExentos', sum_exento(servicio)),
          compare_total('TotalMercNoSujeta', sum_no_sujeto(mercancia)),
          compare_total('TotalMercanciasGravadas', sum_gravado_mercancia(mercancia)),
          compare_total('TotalMercanciasExentas', sum_exento(mercancia)),
          compare_total('TotalImpAsumEmisorFabrica', sum_field(lines, 'ImpuestoAsumidoEmisorFabrica'))
        ].compact
      end

      def unidad_de_servicio?(line)
        UNIDADES_DE_SERVICIO.include?(line['UnidadMedida'])
      end

      # Regla #52: "no sujeto" es la tarifa 0% (`01`) o la del 0% sin derecho a
      # crédito (`11`) — dos códigos de tarifa distintos, mismo tratamiento.
      TARIFA_CERO = '01'

      def no_sujeto?(line)
        [TARIFA_SIN_DERECHO_CREDITO, TARIFA_CERO].include?(line.dig('Impuesto', 'CodigoTarifaIVA'))
      end

      def exento?(line)
        line.dig('Impuesto', 'CodigoTarifaIVA') == TARIFA_EXENTA
      end

      # "Gravado" en el sentido del recalculo de totales: un impuesto de los
      # cuatro códigos que la regla #53 considera, sin ser no-sujeto ni exento.
      GRAVADO_CODIGOS = %w[01 07 08 99].freeze

      def gravado?(line)
        GRAVADO_CODIGOS.include?(line.dig('Impuesto', 'Codigo')) && !no_sujeto?(line) && !exento?(line)
      end

      def sum_no_sujeto(group)
        group.select { |l| no_sujeto?(l) }.sum { |l| l['MontoTotal'] || BigDecimal(0) }
      end

      def sum_exento(group)
        group.select { |l| exento?(l) }.sum { |l| l['MontoTotal'] || BigDecimal(0) }
      end

      def sum_gravado(group)
        group.select { |l| gravado?(l) }.sum { |l| exonerated_total(l) }
      end

      # Regla #56: excluye las líneas de régimen especial de fábrica exento.
      def sum_gravado_mercancia(group)
        group.select { |l| gravado?(l) && l['IVACobradoFabrica'] != IVA_COBRADO_FABRICA_EXENTO }
             .sum { |l| exonerated_total(l) }
      end

      def sum_field(group, field)
        group.sum { |l| l[field] || BigDecimal(0) }
      end

      # `GetExoneratedTotalAmount` del legacy: resta proporcionalmente la
      # parte exonerada del monto total gravado.
      #
      # ── Guard que el legacy no tenía ──────────────────────────────────────
      # El original divide por `ImpTarifa` sin más; con tarifa `0` o ausente
      # eso es una división por cero. Acá, cuando no se puede calcular la
      # proporción exonerada, se usa el monto total tal cual — es la opción
      # que no hace explotar la validación completa por una línea con datos
      # incompletos, a costa de no ajustar esa línea puntual.
      def exonerated_total(line)
        exoneracion = line.dig('Impuesto', 'Exoneracion')
        tarifa = line.dig('Impuesto', 'Tarifa')
        monto_total = line['MontoTotal'] || BigDecimal(0)
        return monto_total if exoneracion.nil? || exoneracion['TipoDocumentoEX1'].blank?
        return monto_total if tarifa.nil? || tarifa.zero?

        tarifa_exonerada = exoneracion['TarifaExonerada'] || BigDecimal(0)
        tarifa_no_exonerada = 100 - ((tarifa_exonerada / tarifa) * 100)
        (monto_total * tarifa_no_exonerada) / 100
      end

      def compare_total(field, recomputed)
        declarado = resumen[field]
        return nil if declarado.nil?
        return nil if (declarado - recomputed).abs <= TOLERANCE

        error("El total #{field} declarado (#{declarado}) no coincide con lo recalculado " \
              "desde las líneas (#{recomputed}).", field: "ResumenFactura.#{field}")
      end

      # ── Bloque G: los totales del resumen cuadran ENTRE SÍ (reglas #59-67) ─
      def cross_total_errors
        [
          suma_igual('TotalGravado', %w[TotalServGravados TotalMercanciasGravadas]),
          suma_igual('TotalExento', %w[TotalServExentos TotalMercanciasExentas]),
          suma_igual('TotalExonerado', %w[TotalServExonerado TotalMercExonerada]),
          suma_igual('TotalVenta', %w[TotalGravado TotalExento TotalExonerado TotalNoSujeto]),
          total_descuentos_cuadra,
          suma_igual('TotalVentaNeta', %w[TotalVenta], restar: %w[TotalDescuentos]),
          total_impuesto_consistente,
          suma_igual('TotalNoSujeto', %w[TotalMercNoSujeta TotalServNoSujeto]),
          total_otros_cargos_no_subestimado
        ].compact
      end

      def suma_igual(field, sumandos, restar: [])
        declarado = resumen[field]
        return nil if declarado.nil?

        esperado = sumandos.sum { |s| resumen[s] || BigDecimal(0) } -
                   restar.sum { |s| resumen[s] || BigDecimal(0) }
        return nil if (declarado - esperado).abs <= TOLERANCE

        partes = (sumandos + restar.map { |s| "−#{s}" }).join(' + ').gsub('+ −', '− ')
        error("El total #{field} (#{declarado}) no coincide con #{partes} (#{esperado}).",
              field: "ResumenFactura.#{field}")
      end

      # Regla #63: contra la suma de los descuentos de línea, no contra otro
      # total del resumen.
      def total_descuentos_cuadra
        declarado = resumen['TotalDescuentos']
        return nil if declarado.nil?

        esperado = lines.sum { |l| l.dig('Descuento', 'MontoDescuento') || BigDecimal(0) }
        return nil if (declarado - esperado).abs <= TOLERANCE

        error("El total de descuentos (#{declarado}) no coincide con la suma de los " \
              "descuentos de línea (#{esperado}).", field: 'ResumenFactura.TotalDescuentos')
      end

      # Regla #65: chequeo laxo — solo detecta la inconsistencia grosera de
      # declarar impuesto en el resumen sin que ninguna línea lo respalde.
      def total_impuesto_consistente
        declarado = resumen['TotalImpuesto']
        return nil unless declarado.present? && declarado.positive?

        respaldo = lines.sum { |l| (l.dig('Impuesto', 'Monto') || BigDecimal(0)) + (l['ImpuestoNeto'] || BigDecimal(0)) }
        return nil if respaldo.positive?

        error('El total de impuesto no está respaldado por el impuesto de las líneas: revise ' \
              'los montos de impuesto en las líneas.', field: 'ResumenFactura.TotalImpuesto')
      end

      # Regla #67: solo se marca error si el total declarado es MENOR al real
      # (subestimado); uno mayor no se rechaza acá.
      def total_otros_cargos_no_subestimado
        declarado = resumen['TotalOtrosCargos']
        return nil if declarado.nil?

        real = (document['OtrosCargos'] || []).sum { |c| c['MontoCargo'] || BigDecimal(0) }
        return nil if declarado - real >= -TOLERANCE

        error("El total de otros cargos (#{declarado}) es menor a la suma real de las " \
              "líneas de otros cargos (#{real}).", field: 'ResumenFactura.TotalOtrosCargos')
      end

      def error(message, field:)
        InvoiceValidationError.new(message: message, field: field)
      end
    end
  end
end

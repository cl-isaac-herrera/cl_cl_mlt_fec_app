# frozen_string_literal: true

module Hacienda
  module Validations
    # Reglas de una línea de `DetalleServicio`: el CABYS, el código comercial,
    # el impuesto y su exoneración, y el cuadre matemático entre
    # cantidad/precio/descuento/impuesto/totales de la línea.
    #
    # Origen: `Validations.cs#OwnValidations`, bloque de líneas (reglas #17,
    # #19-41 del reporte de la migración). Excluidas por no aplicar a Factura
    # Electrónica: #18 (partida arancelaria, solo Factura de Exportación).
    #
    # Los códigos de impuesto `08` (IVA Régimen de Bienes Usados) y el monto de
    # exportación (`MontoExportacion`) están BLOQUEADOS a propósito (reglas #24
    # y #32): el legacy los marca como "consulte a Clavisco", es decir, sin
    # soporte todavía. No es un error de captura del usuario — es una
    # funcionalidad que este producto no implementa.
    class LineItemValidator
      include Catalogs

      CODIGO_IMPUESTO_NO_SOPORTADO = '08'
      # Códigos de descuento que cambian la base del cálculo del impuesto
      # (regla #29): sobre el monto total de la línea y no sobre la base
      # imponible. El legacy los llama "Royalty".
      CODIGOS_DESCUENTO_REGALIA = %w[01 03].freeze
      CODIGO_IMPUESTO_IVA = '01'

      # @param line [Hash] un elemento de `document['DetalleServicio']`.
      # @param line_number [Integer] para identificar la línea en el mensaje.
      def initialize(line, line_number)
        @line = line
        @line_number = line_number
      end

      # @return [Array<Hacienda::InvoiceValidationError>]
      def call
        [
          cabys_requerido,
          codigo_comercial_valido,
          monto_total_cuadra,
          naturaleza_descuento_requerida,
          sub_total_cuadra,
          base_imponible_requerida,
          *validate_impuesto,
          *validate_exoneracion,
          # Regla #41: a diferencia de #33-40, aplica SIEMPRE — con o sin
          # exoneración — porque el reporte de la migración lo marca
          # explícitamente como excepción del sub-bloque de exoneración.
          impuesto_neto_cuadra,
          monto_total_linea_cuadra
        ].compact
      end

      private

      attr_reader :line, :line_number

      # Regla #17.
      def cabys_requerido
        return nil if line['CodigoCABYS'].present?

        error('El código CABYS es requerido.', field: 'CodigoCABYS')
      end

      # Regla #19.
      def codigo_comercial_valido
        codigo = line.dig('CodigoComercial', 'Codigo')
        return nil if codigo.blank?

        tipo = line.dig('CodigoComercial', 'Tipo')
        return nil if TIPO_CODIGO_COMERCIAL.include?(tipo)

        error("El tipo de código comercial #{tipo.inspect} no es permitido.",
              field: 'CodigoComercial.Tipo')
      end

      # Regla #20: `MontoTotal` tiene que ser `Cantidad × PrecioUnitario`.
      def monto_total_cuadra
        cantidad = line['Cantidad']
        precio   = line['PrecioUnitario']
        monto    = line['MontoTotal']
        return nil if cantidad.nil? || precio.nil? || monto.nil?

        esperado = cantidad * precio
        return nil if (monto - esperado).abs <= TOLERANCE

        error("El monto total de la línea (#{monto}) no coincide con cantidad × precio " \
              "unitario (#{esperado}).", field: 'MontoTotal')
      end

      # Regla #21.
      def naturaleza_descuento_requerida
        codigo = line.dig('Descuento', 'CodigoDescuento')
        return nil unless codigo == '99'
        return nil if line.dig('Descuento', 'NaturalezaDescuento').present?

        error('La naturaleza del descuento es requerida cuando el código de descuento es 99.',
              field: 'Descuento.NaturalezaDescuento')
      end

      # Regla #22: `SubTotal` tiene que ser `MontoTotal − MontoDescuento`.
      def sub_total_cuadra
        monto_total = line['MontoTotal']
        descuento   = line.dig('Descuento', 'MontoDescuento') || BigDecimal(0)
        sub_total   = line['SubTotal']
        return nil if monto_total.nil? || sub_total.nil?

        esperado = monto_total - descuento
        return nil if (sub_total - esperado).abs <= TOLERANCE

        error("El subtotal de la línea (#{sub_total}) no coincide con monto total − " \
              "descuento (#{esperado}).", field: 'SubTotal')
      end

      # Regla #23: solo se exige > 0 cuando el impuesto es IVA de cálculo
      # especial (07) — no es una obligatoriedad general del campo.
      def base_imponible_requerida
        return nil unless line.dig('Impuesto', 'Codigo') == '07'

        base = line['BaseImponible']
        return nil if base.present? && base.positive?

        error('La base imponible es requerida cuando el impuesto es de cálculo especial (07).',
              field: 'BaseImponible')
      end

      def validate_impuesto
        codigo = line.dig('Impuesto', 'Codigo')
        return [] if codigo.blank?

        [
          impuesto_no_soportado(codigo),
          impuesto_codigo_valido(codigo),
          codigo_tarifa_requerido(codigo),
          codigo_tarifa_valido,
          tarifa_no_negativa,
          monto_impuesto_cuadra(codigo),
          regalia_con_impuesto,
          monto_exportacion_no_soportado
        ].compact
      end

      # Regla #24.
      def impuesto_no_soportado(codigo)
        return nil unless codigo == CODIGO_IMPUESTO_NO_SOPORTADO

        error('El código de impuesto 08 (IVA Régimen de Bienes Usados) no está soportado. ' \
              'Consulte con soporte técnico antes de emitir este documento.',
              field: 'Impuesto.Codigo')
      end

      # Regla #25: solo se valida contra el catálogo si hay monto de impuesto.
      def impuesto_codigo_valido(codigo)
        monto = line.dig('Impuesto', 'Monto')
        return nil unless monto.present? && monto.positive?
        return nil if CODIGO_IMPUESTO.include?(codigo)

        error("El código de impuesto #{codigo.inspect} no es válido.", field: 'Impuesto.Codigo')
      end

      # Regla #26: no aplica cuando la línea usa `DetalleSurtido` (el impuesto
      # se calcula por componente del surtido, no a nivel de línea).
      def codigo_tarifa_requerido(codigo)
        return nil unless %w[01 07].include?(codigo)
        return nil if line['DetalleSurtido'].present?
        return nil if line.dig('Impuesto', 'CodigoTarifaIVA').present?

        error('El código de tarifa del impuesto es requerido para IVA (01) o IVA de ' \
              'cálculo especial (07).', field: 'Impuesto.CodigoTarifaIVA')
      end

      # Regla #27.
      def codigo_tarifa_valido
        tarifa = line.dig('Impuesto', 'CodigoTarifaIVA')
        return nil if tarifa.blank?
        return nil if CODIGO_TARIFA_IVA.include?(tarifa)

        error("El código de tarifa del impuesto #{tarifa.inspect} no es válido.",
              field: 'Impuesto.CodigoTarifaIVA')
      end

      # Regla #28.
      def tarifa_no_negativa
        monto = line.dig('Impuesto', 'Monto')
        return nil unless monto.present? && monto.positive?

        tarifa = line.dig('Impuesto', 'Tarifa')
        return nil if tarifa.present? && !tarifa.negative?

        error('La tarifa del impuesto es requerida cuando hay monto de impuesto.',
              field: 'Impuesto.Tarifa')
      end

      # Regla #29. El cálculo cambia de base según si el descuento es de tipo
      # "Royalty": sobre el monto total en vez de sobre la base imponible.
      # Solo aplica con precio positivo y sin `DetalleSurtido` (el surtido se
      # calcula por componente).
      def monto_impuesto_cuadra(codigo)
        precio = line['PrecioUnitario']
        return nil unless precio.present? && precio.positive?
        return nil if line['DetalleSurtido'].present?

        tarifa = line.dig('Impuesto', 'Tarifa')
        monto  = line.dig('Impuesto', 'Monto')
        return nil if tarifa.nil? || monto.nil?

        base = regalia_descuento?(codigo) ? line['MontoTotal'] : line['BaseImponible']
        return nil if base.nil?

        esperado = (base * (tarifa / BigDecimal(100))).round(2)
        return nil if (monto - esperado).abs <= TOLERANCE

        base_nombre = regalia_descuento?(codigo) ? 'el monto total' : 'la base imponible'
        error("El monto del impuesto (#{monto}) no coincide con el #{tarifa}% de " \
              "#{base_nombre} (#{esperado}).", field: 'Impuesto.Monto')
      end

      def regalia_descuento?(codigo)
        codigo == CODIGO_IMPUESTO_IVA &&
          CODIGOS_DESCUENTO_REGALIA.include?(line.dig('Descuento', 'CodigoDescuento'))
      end

      # Regla #30: un artículo de regalía (precio ≤ 0) con tarifa mayor a cero
      # tiene que llevar impuesto mayor a cero — no puede regalarse el
      # impuesto junto con el artículo.
      def regalia_con_impuesto
        precio = line['PrecioUnitario']
        return nil if precio.nil? || precio.positive?

        tarifa = line.dig('Impuesto', 'Tarifa')
        return nil unless tarifa.present? && tarifa.positive?

        monto = line.dig('Impuesto', 'Monto')
        return nil if monto.present? && monto.positive?

        error('Un artículo de regalía con tarifa de impuesto mayor a cero debe llevar ' \
              'un monto de impuesto mayor a cero.', field: 'Impuesto.Monto')
      end

      # Regla #32.
      def monto_exportacion_no_soportado
        monto = line.dig('Impuesto', 'MontoExportacion')
        return nil unless monto.present? && monto.positive?

        error('El monto de exportación no está soportado. Consulte con soporte técnico ' \
              'antes de emitir este documento.', field: 'Impuesto.MontoExportacion')
      end

      # Reglas #33-41: solo se validan cuando la línea declara exoneración
      # (`NumeroDocumento` presente en `Impuesto.Exoneracion`).
      def validate_exoneracion
        exoneracion = line.dig('Impuesto', 'Exoneracion')
        return [] if exoneracion.nil? || exoneracion['NumeroDocumento'].blank?

        [
          exoneracion_tipo_documento_valido(exoneracion),
          exoneracion_institucion_valida(exoneracion),
          exoneracion_institucion_otros_requerida(exoneracion),
          exoneracion_fecha_requerida(exoneracion),
          exoneracion_tarifa_requerida(exoneracion),
          exoneracion_tarifa_no_mayor_a_impuesto(exoneracion),
          exoneracion_monto_cuadra(exoneracion)
        ].compact
      end

      def exoneracion_tipo_documento_valido(exoneracion)
        tipo = exoneracion['TipoDocumentoEX1']
        return nil if TIPO_DOCUMENTO_EXONERACION.include?(tipo)

        error("El tipo de documento de exoneración #{tipo.inspect} no es válido.",
              field: 'Impuesto.Exoneracion.TipoDocumentoEX1')
      end

      def exoneracion_institucion_valida(exoneracion)
        institucion = exoneracion['NombreInstitucion']
        return nil if NOMBRE_INSTITUCION_EXONERACION.include?(institucion)

        error("La institución de exoneración #{institucion.inspect} no es válida.",
              field: 'Impuesto.Exoneracion.NombreInstitucion')
      end

      def exoneracion_institucion_otros_requerida(exoneracion)
        return nil unless exoneracion['NombreInstitucion'] == '99'
        return nil if exoneracion['NombreInstitucionOtros'].present?

        error('El nombre de la institución de exoneración es requerido cuando la ' \
              'institución es 99.', field: 'Impuesto.Exoneracion.NombreInstitucionOtros')
      end

      def exoneracion_fecha_requerida(exoneracion)
        return nil if exoneracion['FechaEmisionEX'].present?

        error('La fecha de emisión de la exoneración es requerida.',
              field: 'Impuesto.Exoneracion.FechaEmisionEX')
      end

      def exoneracion_tarifa_requerida(exoneracion)
        return nil if exoneracion['TarifaExonerada'].present? && exoneracion['TarifaExonerada'].positive?

        error('La tarifa exonerada es requerida y no puede ser cero.',
              field: 'Impuesto.Exoneracion.TarifaExonerada')
      end

      # Regla #31, agrupada acá porque depende del mismo bloque de exoneración.
      def exoneracion_tarifa_no_mayor_a_impuesto(exoneracion)
        exonerada = exoneracion['TarifaExonerada']
        tarifa    = line.dig('Impuesto', 'Tarifa')
        return nil if exonerada.nil? || tarifa.nil?
        return nil if exonerada <= tarifa

        error('La tarifa exonerada no puede ser mayor a la tarifa del impuesto.',
              field: 'Impuesto.Exoneracion.TarifaExonerada')
      end

      # Regla #39: `MontoExoneracion = TarifaExonerada% × SubTotal`, y no
      # puede ser cero (una exoneración sin monto no exonera nada).
      def exoneracion_monto_cuadra(exoneracion)
        tarifa      = exoneracion['TarifaExonerada']
        sub_total   = line['SubTotal']
        monto_exon  = exoneracion['MontoExoneracion']
        return nil if tarifa.nil? || sub_total.nil? || monto_exon.nil?

        if monto_exon.zero?
          return error('El monto de exoneración es requerido y no puede ser cero.',
                       field: 'Impuesto.Exoneracion.MontoExoneracion')
        end

        esperado = ((tarifa / BigDecimal(100)) * sub_total).round(2)
        return nil if (monto_exon - esperado).abs <= TOLERANCE

        error("El monto de exoneración (#{monto_exon}) no coincide con el #{tarifa}% " \
              "del subtotal (#{esperado}).", field: 'Impuesto.Exoneracion.MontoExoneracion')
      end

      # Regla #40: `ImpuestoNeto = Impuesto.Monto − MontoExoneracion`.
      #
      # ── Diferencia deliberada con el legacy ──────────────────────────────
      # El reporte de la migración ubica esta regla DENTRO del sub-bloque que
      # solo corre si hay exoneración, así que el .NET no verificaba esta
      # igualdad en absoluto cuando una línea no exoneraba nada. Acá se corre
      # siempre: la fórmula sigue siendo válida con `MontoExoneracion = 0`
      # (`|| BigDecimal(0)` más abajo), así que la línea "sin exoneración
      # exonera cero" es el mismo caso general y no una excepción — validarlo
      # siempre detecta más, sin cambiar el resultado de las líneas que sí
      # cuadraban.
      def impuesto_neto_cuadra
        monto_impuesto = line.dig('Impuesto', 'Monto')
        monto_exon     = line.dig('Impuesto', 'Exoneracion', 'MontoExoneracion') || BigDecimal(0)
        impuesto_neto  = line['ImpuestoNeto']
        return nil if monto_impuesto.nil? || impuesto_neto.nil?

        esperado = monto_impuesto - monto_exon
        return nil if (impuesto_neto - esperado).abs <= TOLERANCE

        error("El impuesto neto (#{impuesto_neto}) no coincide con impuesto − " \
              "exoneración (#{esperado}).", field: 'ImpuestoNeto')
      end

      # Regla #41: aplica SIEMPRE (no solo con exoneración), pero vive acá
      # porque necesita el `ImpuestoNeto` que el bloque de arriba valida.
      def monto_total_linea_cuadra
        sub_total = line['SubTotal']
        impuesto_neto = line['ImpuestoNeto']
        total = line['MontoTotalLinea']
        return nil if sub_total.nil? || impuesto_neto.nil? || total.nil?

        esperado = sub_total + impuesto_neto
        return nil if (total - esperado).abs <= TOLERANCE

        error("El monto total de la línea (#{total}) no coincide con subtotal + " \
              "impuesto neto (#{esperado}).", field: 'MontoTotalLinea')
      end

      def error(message, field:)
        InvoiceValidationError.new(message: message, field: field, line_number: line_number)
      end
    end
  end
end

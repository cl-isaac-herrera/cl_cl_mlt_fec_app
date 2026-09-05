# frozen_string_literal: true

module Hacienda
  module Validations
    # Catálogos de códigos del Anexo 4.4 de Hacienda (resolución DGT-R-48-2016)
    # y del XSD `FacturaElectronica_V4.4.xsd`, en un solo lugar para que los
    # validadores de cada bloque no repitan la misma lista.
    #
    # Cada constante cita su origen (número de regla de `Validations.cs` en el
    # legacy .NET, o el `simpleType` del XSD) para poder verificarla contra la
    # fuente sin tener que releer el reporte completo de la migración.
    module Catalogs
      # Tolerancia monetaria de TODAS las comparaciones de cuadre de totales.
      # Es la misma que usaba el legacy (±0.5): las diferencias de centavos por
      # redondeo entre lo que arma SAP y lo que suma este validador no son un
      # error de negocio.
      TOLERANCE = BigDecimal('0.5')

      # `CondicionVenta` (regla #4). El XSD 4.4 excluye 09 y 11 de la
      # enumeración aunque la anotación textual los mencione — se replica el
      # XSD, que es lo que Hacienda valida de verdad.
      CONDICION_VENTA = %w[01 02 03 04 05 06 07 08 10 12 13 14 15 99].freeze

      # Las tres que exigen medio de pago y, si es crédito, plazo (regla #11-15).
      CONDICION_VENTA_CONTADO  = '01'
      CONDICION_VENTA_CREDITO  = '02'
      CONDICION_VENTA_OTROS    = '99'
      CONDICIONES_DE_CREDITO   = %w[02 08 10].freeze

      # `Identificacion.Tipo`, emisor y receptor (reglas #5-10, XSD `EmisorType`
      # / `ReceptorType`). 05 y 06 son los que usa un receptor no costarricense.
      TIPO_IDENTIFICACION = %w[01 02 03 04 05 06].freeze

      # Longitud exacta de `Identificacion.Numero` según el tipo (regla #10).
      # El XSD no la exige (`maxLength` 20 nada más); es una regla de negocio.
      LONGITUD_IDENTIFICACION = {
        '01' => [9],     # Cédula física
        '02' => [10],    # Cédula jurídica
        '03' => [11, 12], # DIMEX
        '04' => [10]     # NITE
      }.freeze

      # `CodigoTipoProducto.Tipo` del código comercial de línea (regla #19).
      TIPO_CODIGO_COMERCIAL = %w[01 02 03 04 99].freeze

      # `Impuesto.Codigo` (regla #25). El 08 (IVA Régimen de Bienes Usados) y
      # el 07 (IVA cálculo especial) SÍ están permitidos; el 08 de la lista de
      # "impuestos específicos" de la regla #6 es un código de EXONERACIÓN
      # distinto — no confundir los dos catálogos.
      CODIGO_IMPUESTO = %w[01 02 03 04 05 06 07 08 12 99].freeze

      # Impuestos específicos no tarifarios: exigen `DatosImpuestoEspecifico`
      # (regla #6 del bloque de impuesto).
      CODIGO_IMPUESTO_ESPECIFICO = %w[03 04 05 06].freeze

      # `Impuesto.CodigoTarifaIVA` (regla #27, XSD `CodigoTarifaIVAType`).
      CODIGO_TARIFA_IVA = %w[01 02 03 04 05 06 07 08 09 10 11].freeze
      TARIFA_EXENTA          = '10'
      TARIFA_SIN_DERECHO_CREDITO = '11'

      # `Exoneracion.TipoDocumentoEX1` (regla #33, XSD `TipoExoneracionType`).
      TIPO_DOCUMENTO_EXONERACION = %w[01 02 03 04 05 06 07 08 09 10 11 99].freeze

      # `Exoneracion.NombreInstitucion` (regla #34, XSD).
      NOMBRE_INSTITUCION_EXONERACION = %w[01 02 03 04 05 06 07 08 09 10 11 12 99].freeze

      # `OtrosCargos.TipoDocumentoOC` (regla #42, XSD `TipoDocOtrosCargosType`).
      TIPO_DOCUMENTO_OTROS_CARGOS = %w[01 02 03 04 05 06 07 99].freeze
      TIPO_OTROS_CARGOS_COBRO_TERCERO = '04'

      # `NaturalezaDescuento.CodigoDescuento` (XSD `CodigoDescuentoType`).
      CODIGO_DESCUENTO = %w[01 02 03 04 05 06 07 08 09 99].freeze

      # `InformacionReferencia.InfRefTipoDoc` (regla #68, XSD `TipoDocReferenciaType`).
      TIPO_DOC_REFERENCIA = ((1..18).map { |n| format('%02d', n) } + ['99']).freeze
      # Facturación de mes vencido: exime a `InfRefCodigo`/`InfRefRazon` de ser
      # obligatorios (regla #71-72).
      TIPO_DOC_REFERENCIA_MES_VENCIDO = '13'

      # `InformacionReferencia.InfRefCodigo` (regla #71, XSD `CodigoReferenciaType`).
      CODIGO_REFERENCIA = %w[01 02 04 05 06 07 08 09 10 11 12 99].freeze

      # `ResumenFactura.MedioPago.TipoMedioPago` (XSD).
      TIPO_MEDIO_PAGO = %w[01 02 03 04 05 06 07 99].freeze

      # Unidades de medida de SERVICIOS (regla #52-58: separan "servicios" de
      # "mercancías" para los totales del resumen). Lista tomada literal del
      # legacy — el XSD trae 101 unidades en total y estas son las que cuentan
      # como servicio.
      UNIDADES_DE_SERVICIO = %w[Al Alc Cm I Os Sp Spe St].freeze

      # `ResumenFactura.CodigoTipoMoneda.CodigoMoneda`. El XSD trae una lista
      # blanca cerrada de ~170 códigos ISO 4217; acá se valida solo la FORMA
      # (tres letras mayúsculas) y no la pertenencia a esa lista completa —
      # replicarla entera no aporta nada que el patrón no cubra ya para el
      # 99% de los casos reales (CRC, USD, EUR). Si hace falta la whitelist
      # exacta, está documentada en el reporte de la migración del XSD.
      CODIGO_MONEDA_PATTERN = /\A[A-Z]{3}\z/
      MONEDA_LOCAL = 'CRC'
    end
  end
end

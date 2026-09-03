# frozen_string_literal: true

module Documents
  # Junta las seis consultas de SAP en el objeto único del documento.
  #
  #   payload = Documents::UnifiedBuilder.new(
  #     company: company, doc_type: DocType::FE, details: details
  #   ).call
  #
  # Es el punto 10 de `docs/sync-documents-flow.md`. La forma del resultado es la
  # del `objToSend` del .NET: llaves en PascalCase y anidadas como el XML de
  # Hacienda, para que el generador del XML sea una traducción directa y no otra
  # ronda de decisiones.
  #
  # ── Solo factura electrónica, por ahora ──────────────────────────────────────
  # El documento dice que este objeto unificado es **solo para factura
  # electrónica** (punto 10, última línea). Las consultas iniciales son las mismas
  # para todos los tipos; lo que cambia por tipo es justamente este armado
  # (aclaración final del documento). Por eso el tipo viaja en el resultado
  # (`DocType`) en vez de quedar implícito: el paso que elige el XML lo necesita.
  #
  # ── Tipos ────────────────────────────────────────────────────────────────────
  # Los montos salen como `BigDecimal` y no como `Float` (ver `Documents::Row`):
  # se suman para armar el desglose de impuestos y Hacienda compara esos totales
  # contra los suyos. Un centavo de diferencia por coma flotante es un rechazo.
  #
  # ── Lo que todavía NO se puede llenar ────────────────────────────────────────
  # Un campo del mapeo no tiene origen en las vistas declaradas hoy. Se deja en
  # `[]` y NO se inventa: `DetalleSurtido`, porque no hay vista de surtidos (el
  # mapeo la nombra, pero `docs/sync-documents-flow.md` no la define).
  #
  # `ProveedorSistemas` se sigue leyendo de la cabecera, donde la vista lo trae
  # hardcodeado. Está decidido que se mueve al ajuste `GENERAL_PROVIDER_ID` —es un
  # dato del producto y no del documento— pero mientras la vista lo devuelva, esto
  # funciona. Anotado en `TODOS.md` → Emisión de documentos.
  class UnifiedBuilder
    # @param company [Company]
    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param details [Sap::DocumentDetails::Result]
    def initialize(company:, doc_type:, details:)
      @company = company
      @doc_type = doc_type
      @details = details
    end

    # @return [Hash] el `objToSend`: tipo, documento y datos del envío.
    def call
      {
        'DocType' => doc_type,
        'Document' => document,
        'SendDocumentHacienda' => send_document_hacienda
      }
    end

    private

    attr_reader :company, :doc_type, :details

    def header = details.header

    # ── Documento ─────────────────────────────────────────────────────────────

    def document
      {
        'NumeroConsecutivo' => header.string('NumeroConsecutivo'),
        'Clave' => header.string('Clave'),
        'ProveedorSistemas' => header.string('ProveedorSistemas'),
        'FechaEmision' => header.string('FechaEmision'),
        'CodigoActividadEmisor' => codigo_actividad_emisor,
        'CodigoActividadReceptor' => header.string('CodigoActividadReceptor'),
        'CondicionVenta' => header.string('CondicionVenta'),
        'CondicionVentaOtros' => header.string('CondicionVentaOtros'),
        'PlazoCredito' => header.integer('PlazoCredito'),
        'Emisor' => emisor,
        'Receptor' => receptor,
        'DetalleServicio' => details.lines.map { |line| linea_detalle(line) },
        'ResumenFactura' => resumen_factura,
        'InformacionReferencia' => details.references.map { |row| informacion_referencia(row) },
        'Otros' => otros,
        'OtrosCargos' => details.other_charges.map { |row| otro_cargo(row) }
      }
    end

    # La cabecera manda si algún día la vista lo expone; mientras tanto sale de la
    # compañía. El orden importa: si las dos tienen valor, el de SAP es el que
    # viajó con el documento.
    def codigo_actividad_emisor
      header.string('CodigoActividadEmisor') || company.economic_activity_code.presence
    end

    # El emisor tiene DOS orígenes, y la línea que los separa es si el dato cambia
    # por sucursal:
    #
    #   · Identidad (nombre, identificación, nombre comercial, registro 8707) —
    #     `companies`. Es una por compañía y no depende del documento: la misma
    #     cédula jurídica emite desde cualquier sucursal.
    #   · Ubicación, teléfono y correo — la cabecera, que los trae de la UDT
    #     `@CL_FEC_SUCURSALES` (`config/sap_schemas/sucursales_udt.json`) con el
    #     prefijo `Emsr`. Estos SÍ cambian por sucursal, así que no podrían salir
    #     de `companies`, que es una sola fila.
    #
    # Por eso `#ubicacion` y `#telefono` siguen leyendo de `header` mientras el
    # resto sale de `company`.
    def emisor
      {
        'Nombre' => company.issuer_legal_name.presence,
        'Identificacion' => {
          'Tipo' => company.issuer_id_type.presence,
          'Numero' => company.issuer_id_number.presence
        },
        # La columna nació como el UDF `CL_FEC_EmsrRegFiscal8707`: es el registro
        # del emisor, no el del receptor —que la cabecera trae aparte como
        # `RcprRegistrofiscal8707` y no se usa acá.
        'Registrofiscal8707' => company.tax_registry_8707.presence,
        # El nombre comercial NO tiene columna propia: es `companies.name`, que ya
        # existía y es el que usa el resto de la app. Ver la migración
        # `20260819130000_add_issuer_fields_to_companies.rb`.
        'NombreComercial' => company.name.presence,
        'Ubicacion' => ubicacion(header, 'Emsr'),
        'Telefono' => telefono(header, 'Emsr'),
        'CorreoElectronico' => header.string('EmsrCorreoElectronico')
      }
    end

    # El receptor lleva dos campos que el emisor no tiene: la identificación de
    # extranjero y las señas en el exterior, que Hacienda pide cuando el receptor
    # no es costarricense.
    def receptor
      {
        'Nombre' => header.string('RcprNombre'),
        'Identificacion' => {
          'Tipo' => header.string('RcprIdeTipo'),
          'Numero' => header.string('RcprIdeNumero')
        },
        'IdentificacionExtranjero' => header.string('RcprIdentificacionExtranjero'),
        'NombreComercial' => header.string('RcprNombreComercial'),
        'Ubicacion' => ubicacion(header, 'Rcpr'),
        'OtrasSenasExtranjero' => header.string('RcprOtrasSenasExtranjero'),
        'Telefono' => telefono(header, 'Rcpr'),
        'CorreoElectronico' => header.string('RcprCorreoElectronico')
      }
    end

    # Emisor y receptor traen el mismo bloque con distinto prefijo (`Emsr…` /
    # `Rcpr…`). Se arma una sola vez para que no puedan divergir.
    def ubicacion(row, prefix)
      {
        'Provincia' => row.string("#{prefix}UbProvincia"),
        'Canton' => row.string("#{prefix}UbCanton"),
        'Distrito' => row.string("#{prefix}UbDistrito"),
        'Barrio' => row.string("#{prefix}UbBarrio"),
        'OtrasSenas' => row.string("#{prefix}UbOtrasSenas")
      }
    end

    def telefono(row, prefix)
      {
        'CodigoPais' => row.integer("#{prefix}TlfCodigoPais"),
        'NumTelefono' => row.string("#{prefix}TlfNumTelefono")
      }
    end

    # ── Líneas de detalle ─────────────────────────────────────────────────────

    def linea_detalle(line)
      {
        'NumeroLinea' => line.integer('NumeroLinea'),
        'CodigoCABYS' => line.string('Codigo'),
        'CodigoComercial' => {
          'Tipo' => line.string('CodTipo'),
          'Codigo' => line.string('CodCodigo')
        },
        'Cantidad' => line.decimal('Cantidad'),
        'UnidadMedida' => line.string('UnidadMedida'),
        'UnidadMedidaComercial' => line.string('UnidadMedidaComercial'),
        'Detalle' => line.string('Detalle'),
        'RegistroMedicamento' => line.string('RegistroMedicamento'),
        'FormaFarmaceutica' => line.string('FormaFarmaceutica'),
        'PrecioUnitario' => line.decimal('PrecioUnitario'),
        'MontoTotal' => line.decimal('MontoTotal'),
        'Descuento' => descuento(line),
        'SubTotal' => line.decimal('SubTotal'),
        'BaseImponible' => line.decimal('BaseImponible'),
        'Impuesto' => impuesto(line),
        # Sin vista de surtidos todavía; ver la nota de la cabecera de la clase.
        'DetalleSurtido' => [],
        'MontoTotalLinea' => line.decimal('MontoTotalLinea'),
        'ImpuestoNeto' => line.decimal('ImpuestoNeto'),
        'TipoTransaccion' => line.string('TipoTransaccion'),
        'IVACobradoFabrica' => line.string('IVACobradoFabrica'),
        'NumeroVINoSerie' => line.string('NumeroVINoSerie'),
        'ImpuestoAsumidoEmisorFabrica' => line.decimal('ImpuestoAsumidoEmisorFabrica')
      }
    end

    # `MontoDescuento` es el único no anulable del bloque: la vista lo declara
    # requerido, así que un descuento ausente es 0 y no nulo.
    def descuento(line)
      {
        'MontoDescuento' => line.decimal('MontoDescuento'),
        'NaturalezaDescuento' => line.string('NaturalezaDescuento'),
        'CodigoDescuento' => line.string('DCodigoDescuento'),
        'CodigoDescuentoOTRO' => line.string('DCodigoDescuentoOTRO'),
        'PorcentajeDescuento' => line.decimal('PorcentajeDescuento')
      }
    end

    def impuesto(line)
      {
        'Codigo' => line.string('ImpCodigo'),
        'CodigoTarifaIVA' => line.string('ImpCodigoTarifa'),
        'CodigoImpuestoOTRO' => line.string('ImpCodigoImpuestoOTRO'),
        'Tarifa' => line.decimal('ImpTarifa'),
        'FactorCalculoIVA' => line.decimal('ImpFactorIVA'),
        'DatosImpuestoEspecifico' => {
          'ImpuestoUnidad' => line.decimal('ImpImpuestoUnidad'),
          'Porcentaje' => line.decimal('ImpPorcentaje'),
          'Proporcion' => line.decimal('ImpProporcion'),
          'CantidadUnidadMedida' => line.decimal('ImpCantidadUnidadMedida'),
          'VolumenUnidadConsumo' => line.decimal('ImpVolumenUnidadConsumo')
        },
        'Monto' => line.decimal('ImpMonto'),
        'MontoExportacion' => line.decimal('ImpMontoExportacion'),
        'Exoneracion' => exoneracion(line)
      }
    end

    def exoneracion(line)
      {
        'TipoDocumentoEX1' => line.string('ETipoDocumento'),
        'TipoDocumentoOTRO' => line.string('ETipoDocumentoOtro'),
        'NumeroDocumento' => line.string('ENumeroDocumento'),
        'NombreInstitucion' => line.string('ENombreInstitucion'),
        'NombreInstitucionOtros' => line.string('ENombreInstitucionOtros'),
        'FechaEmisionEX' => line.string('EFechaEmision'),
        'TarifaExonerada' => line.decimal('ETarifaExonerada'),
        # La vista lo declara `string` y no decimal — se conserva su tipo en vez
        # de convertirlo: es dato del origen y el XML lo escribe tal cual.
        'MontoExoneracion' => line.string('EMontoExoneracion'),
        'Articulo' => line.integer('EArticulo'),
        'Inciso' => line.integer('EInciso')
      }
    end

    # ── Resumen ───────────────────────────────────────────────────────────────

    def resumen_factura
      {
        'MedioPago' => details.payment_methods.map { |row| medio_pago(row) },
        'CodigoTipoMoneda' => {
          'CodigoMoneda' => header.string('CodigoMoneda'),
          'TipoCambio' => header.decimal('TipoCambio')
        },
        'TotalServGravados' => header.decimal('TotalServGravados'),
        'TotalServExentos' => header.decimal('TotalServExentos'),
        'TotalServExonerado' => header.decimal('TotalServExonerado'),
        'TotalServNoSujeto' => header.decimal('TotalServNoSujeto'),
        'TotalMercanciasGravadas' => header.decimal('TotalMercanciasGravadas'),
        'TotalMercanciasExentas' => header.decimal('TotalMercanciasExentas'),
        'TotalMercExonerada' => header.decimal('TotalMercExonerada'),
        'TotalMercNoSujeta' => header.decimal('TotalMercNoSujeta'),
        'TotalGravado' => header.decimal('TotalGravado'),
        'TotalExento' => header.decimal('TotalExento'),
        'TotalExonerado' => header.decimal('TotalExonerado'),
        'TotalNoSujeto' => header.decimal('TotalNoSujeto'),
        'TotalVenta' => header.decimal('TotalVenta'),
        'TotalDescuentos' => header.decimal('TotalDescuentos'),
        'TotalVentaNeta' => header.decimal('TotalVentaNeta'),
        'TotalDesgloseImpuesto' => desglose_impuesto,
        'TotalImpuesto' => header.decimal('TotalImpuesto'),
        'TotalImpAsumEmisorFabrica' => header.decimal('TotalImpAsumEmisorFabrica'),
        'TotalIVADevuelto' => header.decimal('TotalIVADevuelto'),
        'TotalOtrosCargos' => header.decimal('TotalOtrosCargos'),
        'TotalComprobante' => header.decimal('TotalComprobante')
      }
    end

    def medio_pago(row)
      {
        'TipoMedioPago' => row.string('TipoMedioPago'),
        'MedioPagoOtros' => row.string('MedioPagoOtros'),
        'TotalMedioPago' => row.decimal('TotalMedioPago')
      }
    end

    # Impuestos agrupados por (código, tarifa) con los montos sumados.
    #
    # Hacienda pide el desglose una sola vez por combinación, no una por línea: si
    # cinco líneas llevan IVA 13%, va un renglón con la suma. Agrupar con las
    # líneas ya leídas evita una consulta más a SAP.
    #
    # Se descartan las líneas sin código de impuesto —no hay nada que desglosar— y
    # el monto ausente cuenta como cero para no perder el renglón cuando una línea
    # de la combinación no trae monto.
    def desglose_impuesto
      details.lines.filter_map { |line| tax_key_and_amount(line) }
             .group_by(&:first)
             .map do |(codigo, tarifa), pairs|
        {
          'Codigo' => codigo,
          'CodigoTarifaIVA' => tarifa,
          'TotalMontoImpuesto' => pairs.sum { |pair| pair.last }
        }
      end
    end

    def tax_key_and_amount(line)
      codigo = line.string('ImpCodigo')
      return nil if codigo.nil?

      [[codigo, line.string('ImpCodigoTarifa')], line.decimal('ImpMonto') || BigDecimal(0)]
    end

    # ── Bloques sueltos ───────────────────────────────────────────────────────

    def informacion_referencia(row)
      {
        'TipoDocIR' => row.string('InfRefTipoDoc'),
        'TipoDocRefOTRO' => row.string('InfRefTipoDocRefOTRO'),
        'Numero' => row.string('InfRefNumero'),
        'FechaEmisionIR' => row['InfRefFechaEmision'],
        'Codigo' => row.string('InfRefCodigo'),
        'CodigoReferenciaOTRO' => row.string('InfCodigoReferenciaOTRO'),
        'Razon' => row.string('InfRefRazon')
      }
    end

    # `Otros` tiene dos orígenes que se concatenan: las observaciones de la
    # cabecera —un texto libre bajo el código literal `Observaciones`— y los pares
    # código/valor de la consulta adicional, que solo se pidió si la compañía tiene
    # `use_additional_fields` (ver `Sap::DocumentDetails#fetch_others`).
    #
    # El renglón de observaciones se omite cuando no hay texto: un `Otros` con el
    # código puesto y el contenido vacío es un elemento de más en el XML.
    def otros
      observaciones = header.string('OtroTexto')
      renglones = []
      renglones << { 'Codigo' => 'Observaciones', 'Texto' => observaciones } if observaciones

      renglones + details.others.map do |row|
        { 'Codigo' => row.string('Codigo'), 'Texto' => row.string('Valor') }
      end
    end

    def otro_cargo(row)
      {
        'TipoDocumentoOC' => row.string('TipoDocumento'),
        'TipoDocumentoOTROS' => row.string('TipoDocumentoOTROS'),
        'IdentificacionTercero' => {
          'Tipo' => row.string('TipoIdentidadTercero'),
          'Numero' => row.string('NumeroIdentidadTercero')
        },
        'NombreTercero' => row.string('NombreTercero'),
        'Detalle' => row.string('Detalle'),
        'PorcentajeOC' => row.decimal('Porcentaje'),
        'MontoCargo' => row.decimal('MontoCargo')
      }
    end

    # ── Envío ─────────────────────────────────────────────────────────────────

    # Lo que necesita el POST a Hacienda, aparte del XML: la fecha y las dos
    # identificaciones. Llaves en camelCase porque son las del cuerpo que espera
    # Hacienda, no las del XML.
    def send_document_hacienda
      {
        'fecha' => header.string('FechaEmision'),
        # La misma identificación que va en el XML, del mismo lugar: si el cuerpo
        # del POST y el comprobante no coinciden, Hacienda rechaza el envío.
        'emisor' => {
          'numeroIdentificacion' => company.issuer_id_number.presence,
          'tipoIdentificacion' => company.issuer_id_type.presence
        },
        'receptor' => {
          'numeroIdentificacion' => header.string('RcprIdeNumero'),
          'tipoIdentificacion' => header.string('RcprIdeTipo')
        }
      }
    end
  end
end

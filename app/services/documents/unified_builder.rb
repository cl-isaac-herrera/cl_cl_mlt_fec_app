# frozen_string_literal: true

module Documents
  # Junta las seis consultas de SAP en el objeto único del documento.
  #
  #   payload = Documents::UnifiedBuilder.new(doc_type: DocType::FE, details: details).call
  #
  # Es el punto 10 de `docs/sync-documents-flow.md`. La forma del resultado es la
  # del `objToSend` del .NET: llaves en PascalCase y anidadas como el XML de
  # Hacienda, para que el generador del XML sea una traducción directa y no otra
  # ronda de decisiones.
  #
  # ── Sirve para FE, TE, ND, NC y FEC, sin ninguna bifurcación ────────────────
  # El documento dice que este objeto unificado es **solo para factura
  # electrónica** (punto 10, última línea), pero los XSD reales de Hacienda
  # definen un único esquema para FE y TE (`DocumentoFETE` en
  # `FacturaElectronica_V4.4.xsd` — el nombre es literalmente "Factura
  # Electrónica / Tiquete Electrónico") y otro para ND y NC (`DocumentoNCND`),
  # que difiere del primero en DOS campos opcionales de línea y en nada más. El
  # legacy .NET arma los cinco con el mismo `objToSend`.
  #
  # La forma del objeto es una sola para todos; lo que cambia por tipo es qué se
  # emite de él (`Hacienda::XmlBuilder`). La Factura Electrónica de Compra
  # invierte los roles —la emite el proveedor y la compañía es el receptor—,
  # pero eso ya NO es una bifurcación de esta clase: la vista de cabecera que
  # arma `details.header` (`Sap::DocumentDetails`) resuelve la identidad de
  # `Emsr*`/`Rcpr*` para el rol que corresponda en cada tipo, así que
  # `identidad_emisor`/`identidad_receptor` siempre leen del mismo lugar. Es la
  # razón por la que esta clase ya no recibe `company` ni habla con SAP por su
  # cuenta — antes sí lo hacía, para la identidad del rol que fuera la
  # compañía; ahora la vista se la da resuelta.
  #
  # `Hacienda::DocumentValidator` cubre los cinco: comparten casi todas las
  # reglas, y las que no están listadas una por una en su cabecera.
  #
  # Las consultas iniciales son las mismas para todos los tipos; lo que cambia
  # por tipo es justamente este armado (aclaración final del documento). Por eso
  # el tipo viaja en el resultado (`DocType`) en vez de quedar implícito: el paso
  # que elige el XML lo necesita.
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
  class UnifiedBuilder
    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param details [Sap::DocumentDetails::Result]
    def initialize(doc_type:, details:)
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

    attr_reader :doc_type, :details

    def header = details.header

    # ── Documento ─────────────────────────────────────────────────────────────

    def document
      {
        'NumeroConsecutivo' => header.string('NumeroConsecutivo'),
        'Clave' => header.string('Clave'),
        'ProveedorSistemas' => proveedor_sistemas,
        'FechaEmision' => header.string('FechaEmision'),
        'CodigoActividadEmisor' => codigo_actividad_emisor,
        'CodigoActividadReceptor' => codigo_actividad_receptor,
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

    # ── Los dos códigos de actividad ──────────────────────────────────────────
    # Los dos salen SIEMPRE de la cabecera: la vista resuelve cuál de los dos
    # roles es la compañía y le pone su actividad económica al prefijo que
    # corresponda —en la factura de compra eso queda al revés que en el resto,
    # y es la vista la que ya lo resuelve, no esta clase.
    #
    # El XSD lo confirma por su lado: en `FacturaElectronicaCompra_V4.4.xsd`
    # `CodigoActividadReceptor` es `minOccurs="1"` y el del emisor `minOccurs="0"`;
    # en el de factura es exactamente al revés.
    def codigo_actividad_emisor = header.string('CodigoActividadEmisor')

    def codigo_actividad_receptor = header.string('CodigoActividadReceptor')

    # La cédula del proveedor de software ante Hacienda. Es un dato del
    # PRODUCTO y no del documento —la vista lo traía hardcodeado antes de que
    # existiera este ajuste—, así que vive en Configuraciones → Generales y no
    # en ninguna vista de SAP.
    def proveedor_sistemas
      Setting.value_for('GENERAL_PROVIDER_ID')
    end

    # La ubicación, el teléfono y el correo del emisor salen SIEMPRE de la
    # cabecera, sea quien sea el emisor:
    #
    #   · Cuando el emisor es la compañía, los trae de la UDT
    #     `@CL_FEC_SUCURSALES` (`config/sap_schemas/sucursales_udt.json`) con el
    #     prefijo `Emsr`. Cambian por SUCURSAL, así que no podrían salir de
    #     `companies`, que es una sola fila por compañía.
    #   · Cuando el emisor es el proveedor (FEC), son sus propios datos, que solo
    #     SAP conoce.
    #
    # Lo que sí cambia de fuente es la identidad — ver `#identidad_emisor`.
    def emisor
      identidad_emisor.merge(
        # Solo el EMISOR lo declara, en los tres esquemas y también en el de la
        # factura de compra (`EmisorType`): el receptor no tiene dónde ponerlo,
        # así que no se lee ningún `Rcpr…8707` exista o no en la vista.
        'Registrofiscal8707' => registro_fiscal8707,
        'Ubicacion' => ubicacion(header, 'Emsr'),
        # Solo lo emite el XML de FEC; en los demás tipos el emisor es la
        # compañía y el esquema no declara el elemento.
        'OtrasSenasExtranjero' => header.string('EmsrOtrasSenasExtranjero'),
        'Telefono' => telefono(header, 'Emsr'),
        'CorreoElectronico' => header.string('EmsrCorreoElectronico')
      )
    end

    # El receptor lleva dos campos que el emisor no tiene: la identificación de
    # extranjero y las señas en el exterior, que Hacienda pide cuando el receptor
    # no es costarricense. Los dos salen siempre de la cabecera, incluso en la
    # factura de compra: ahí el receptor es la compañía y `companies` no tiene
    # dónde guardarlos, pero tampoco hacen falta —ese esquema ni siquiera los
    # declara— y `Hacienda::XmlBuilder` no los emite.
    #
    # La ubicación, el teléfono y el correo tampoco cambian de fuente: en FEC la
    # vista los llena con los de la compañía, que es la que compra.
    def receptor
      identidad_receptor.merge(
        'IdentificacionExtranjero' => header.string('RcprIdentificacionExtranjero'),
        'Ubicacion' => ubicacion(header, 'Rcpr'),
        'OtrasSenasExtranjero' => header.string('RcprOtrasSenasExtranjero'),
        'Telefono' => telefono(header, 'Rcpr'),
        'CorreoElectronico' => primer_correo(header.string('RcprCorreoElectronico'))
      )
    end

    # ── La identidad de cada rol ──────────────────────────────────────────────
    # Los dos salen SIEMPRE de la cabecera, con su prefijo (`Emsr`/`Rcpr`): la
    # vista de `Sap::DocumentDetails` ya resuelve cuál de los dos roles es la
    # compañía y le pone la identidad que corresponda al prefijo —la suya
    # propia, o la del otro lado del documento—, así que esta clase no necesita
    # saber cuál es cuál. Antes esto se leía de `companies` para el rol que
    # fuera la compañía; ahora la vista ya lo trae resuelto.
    def identidad_emisor = identidad_de_la_cabecera('Emsr')

    def identidad_receptor = identidad_de_la_cabecera('Rcpr')

    # Las tres llaves que los dos bloques comparten. Lo que cada rol agrega
    # aparte —`Registrofiscal8707` en el emisor, los campos de extranjero en el
    # receptor— se mezcla en `#emisor` y `#receptor`.
    def identidad_de_la_cabecera(prefix)
      {
        'Nombre' => header.string("#{prefix}Nombre"),
        'Identificacion' => {
          'Tipo' => header.string("#{prefix}IdeTipo"),
          'Numero' => header.string("#{prefix}IdeNumero")
        },
        'NombreComercial' => header.string("#{prefix}NombreComercial")
      }
    end

    # Solo el EMISOR lo declara (`Registrofiscal8707`, `EmisorType` en los
    # cuatro esquemas): sale siempre de la cabecera, con el mismo prefijo fijo
    # `Emsr` — no depende de cuál rol sea la compañía, porque el campo
    # describe al emisor sea quien sea.
    def registro_fiscal8707 = header.string('EmsrRegistrofiscal8707')

    # Hacienda exige un único correo en `Receptor.CorreoElectronico`, pero SAP
    # puede traer varios separados por `;` (mismo campo que usa
    # `CheckSentDocumentsJob#recipients` para armar el correo de recepción) —
    # se manda solo el primero.
    def primer_correo(raw)
      return nil if raw.nil?

      raw.split(';').map(&:strip).reject(&:blank?).first
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
        # La emiten NC, ND y FEE: el esquema de FE/TE no la declara. Se mapea
        # igual para todos porque este armado es uno solo y el que decide qué
        # sale al XML es `Hacienda::XmlBuilder`.
        'PartidaArancelaria' => line.string('PartidaArancelaria'),
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
      emisor_id = identidad_emisor['Identificacion']
      receptor_id = identidad_receptor['Identificacion']

      {
        'fecha' => header.string('FechaEmision'),
        # Las MISMAS identificaciones que van en el XML, y del mismo lugar —por
        # eso se leen de `#identidad_*` y no de `company` ni de la cabecera, que
        # son sus dos fuentes—: si el cuerpo del POST y el comprobante no
        # coinciden, Hacienda rechaza el envío. En la factura de compra los dos
        # quedan invertidos a la vez, que es la única forma de que sigan
        # coincidiendo.
        'emisor' => {
          'numeroIdentificacion' => emisor_id['Numero'],
          'tipoIdentificacion' => emisor_id['Tipo']
        },
        'receptor' => {
          'numeroIdentificacion' => receptor_id['Numero'],
          'tipoIdentificacion' => receptor_id['Tipo']
        }
      }
    end
  end
end

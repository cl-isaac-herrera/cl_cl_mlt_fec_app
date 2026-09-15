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
  # ── Sirve para FE, TE, ND, NC y FEC, con UNA sola bifurcación ───────────────
  # El documento dice que este objeto unificado es **solo para factura
  # electrónica** (punto 10, última línea), pero los XSD reales de Hacienda
  # definen un único esquema para FE y TE (`DocumentoFETE` en
  # `FacturaElectronica_V4.4.xsd` — el nombre es literalmente "Factura
  # Electrónica / Tiquete Electrónico") y otro para ND y NC (`DocumentoNCND`),
  # que difiere del primero en DOS campos opcionales de línea y en nada más. El
  # legacy .NET arma los cinco con el mismo `objToSend`.
  #
  # La forma del objeto es una sola para todos; lo que cambia por tipo es qué se
  # emite de él (`Hacienda::XmlBuilder`). La ÚNICA bifurcación de este armado es
  # CUÁL DE LOS DOS ROLES es la compañía, porque la factura de compra los
  # invierte — ver `#compania_es_el_emisor?`.
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

    # ── Cuál de los dos roles es la compañía ──────────────────────────────────
    # En todo comprobante de VENTA el emisor es la compañía y el receptor es el
    # cliente. La Factura Electrónica de Compra invierte los roles: la emite el
    # proveedor que no puede facturar —un extranjero no domiciliado o un no
    # contribuyente— y la compañía es el RECEPTOR. Poner ahí la cédula de la
    # compañía no sería un campo mal llenado: sería declararle a Hacienda que la
    # compañía se compró a sí misma.
    #
    # La inversión está confirmada por tres fuentes independientes: el legacy
    # mapea `Emisor` ← `Emsr*` también en FEC (`GetData.cs#GetDocToSendFEC`
    # L1142), `Validations.cs` (L299/L303) exime al emisor de declarar código de
    # actividad y se lo exige al receptor, y el XSD mueve `OtrasSenasExtranjero`
    # del receptor al emisor.
    #
    # ── Cada rol tiene UNA sola fuente, y este predicado la elige ─────────────
    # El rol que NO es la compañía sale de la vista; el que sí lo es sale de
    # `companies`, que es donde el operador lo administra y por eso la vista lo
    # devuelve en NULL a propósito.
    #
    # No hay respaldo de una fuente en la otra ni mapeo entre bloques (el .NET
    # copiaba `Rcpr*` sobre `Emsr*` justo después de consultar la vista): un
    # `||` entre las dos le prestaría al proveedor la identidad de la compañía
    # el día que la vista venga vacía, y ese comprobante —que Hacienda
    # aceptaría— dice que la compañía se compró a sí misma. Sin respaldo, la
    # vista vacía corta en `Hacienda::Validations::HeaderValidator` y el
    # documento queda en `Error` en la cola, que es el desenlace correcto.
    def compania_es_el_emisor? = doc_type != DocType::FEC

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

    # ── Los dos códigos de actividad, cada uno con la fuente de su rol ────────
    # Quien tiene la actividad económica inscrita ante Hacienda es la compañía, y
    # su código sale de `companies`; el del otro rol lo trae la vista. En la
    # factura de compra eso queda al revés que en el resto, igual que todo lo
    # demás de esta clase (ver `#compania_es_el_emisor?`).
    #
    # El XSD lo confirma por su lado: en `FacturaElectronicaCompra_V4.4.xsd`
    # `CodigoActividadReceptor` es `minOccurs="1"` y el del emisor `minOccurs="0"`;
    # en el de factura es exactamente al revés.
    def codigo_actividad_emisor
      return actividad_de_la_compania if compania_es_el_emisor?

      header.string('CodigoActividadEmisor')
    end

    def codigo_actividad_receptor
      return header.string('CodigoActividadReceptor') if compania_es_el_emisor?

      actividad_de_la_compania
    end

    def actividad_de_la_compania = company.economic_activity_code.presence

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

    # ── La identidad de cada rol, según cuál de los dos es la compañía ────────
    # El rol que ES la compañía sale de `companies`; el otro, de la vista, que
    # deja el bloque del primero en NULL a propósito. Sin respaldo entre las dos
    # fuentes — el porqué está en `#compania_es_el_emisor?`.

    def identidad_emisor
      compania_es_el_emisor? ? identidad_de_la_compania : identidad_de_la_cabecera('Emsr')
    end

    def identidad_receptor
      compania_es_el_emisor? ? identidad_de_la_cabecera('Rcpr') : identidad_de_la_compania
    end

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

    def identidad_de_la_compania
      {
        'Nombre' => company.issuer_legal_name.presence,
        'Identificacion' => {
          'Tipo' => company.issuer_id_type.presence,
          'Numero' => company.issuer_id_number.presence
        },
        # El nombre comercial NO tiene columna propia: es `companies.name`, que ya
        # existía y es el que usa el resto de la app. Ver la migración
        # `20260819130000_add_issuer_fields_to_companies.rb`.
        'NombreComercial' => company.name.presence
      }
    end

    # La columna nació como el UDF `CL_FEC_EmsrRegFiscal8707`: es el registro del
    # EMISOR. En la factura de compra ese emisor es el proveedor, así que el dato
    # viene en la cabecera y no de `companies`.
    def registro_fiscal8707
      return company.tax_registry_8707.presence if compania_es_el_emisor?

      header.string('EmsrRegistrofiscal8707')
    end

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

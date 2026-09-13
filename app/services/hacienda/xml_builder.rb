# frozen_string_literal: true

module Hacienda
  # Serializa el objeto unificado al XML del comprobante, versión 4.4.
  #
  #   xml = Hacienda::XmlBuilder.new(payload).call   # => String, XML sin firmar
  #
  # Es el punto 11 de `docs/sync-documents-flow.md` y la pieza que le faltaba a
  # `Hacienda::XmlSigner`, que recibe justamente esto.
  #
  #   Documents::UnifiedBuilder → Hacienda::DocumentValidator → XmlBuilder → XmlSigner
  #
  # @param payload [Hash] lo que devuelve `Documents::UnifiedBuilder#call`
  #   COMPLETO (con `DocType` y `Document`), no solo el documento: el tipo elige
  #   la raíz y el namespace.
  #
  # ── El ORDEN de los elementos es obligatorio ────────────────────────────────
  # El XSD declara cada bloque como `xs:sequence`, así que un elemento fuera de
  # lugar es un rechazo de Hacienda —no una advertencia. Por eso esta clase
  # emite campo por campo en un orden explícito y NO recorre el Hash: el orden
  # de las llaves de `UnifiedBuilder` es el del mapeo funcional y **no coincide**
  # con el del XSD. Los tres desfases que ya existen hoy:
  #
  #   · `ResumenFactura` tiene `MedioPago` de PRIMERO en el objeto unificado y
  #     de penúltimo en el XSD (después de `TotalOtrosCargos`).
  #   · En la línea de detalle, `TipoTransaccion`, `NumeroVINoSerie` e
  #     `IVACobradoFabrica` van intercalados en el XSD y al final en el objeto.
  #   · `DetalleServicio` es una lista plana en el objeto y en el XML va
  #     ENVUELTA: `<DetalleServicio><LineaDetalle>…</LineaDetalle>…</>`.
  #
  # El orden se tomó del modelo C# que el legacy serializaba
  # (`CLVS_FE.Models/Consumo/FETE/FETE.cs` + `CLVS_FE.Models/Hacienda/*.cs`) y
  # se cotejó contra `FacturaElectronica_V4.4.xsd`.
  #
  # ⚠️ Ese XSD del legacy está INCOMPLETO: es una copia con la raíz renombrada a
  # `DocumentoFETE`, sin `targetNamespace` y **sin el elemento `Clave`**, aunque
  # conserva su tipo (`ClaveType`). El modelo C# sí lo tiene, de primero, y es
  # el que de verdad se serializaba y Hacienda aceptaba. No usar esa copia como
  # única fuente.
  #
  # ── Campos del objeto unificado que NO van en el XML ────────────────────────
  # El objeto unificado es uno solo para todos los tipos y trae campos que los
  # esquemas que esta clase serializa no definen. Se OMITEN a propósito;
  # emitirlos donde el esquema no los declara es un rechazo:
  #
  #   · `Receptor.IdentificacionExtranjero` — solo existe en FEE.
  #   · `Descuento.PorcentajeDescuento`     — no está en ninguno de los dos modelos.
  #   · `Impuesto.MontoExportacion`         — el esquema de NC/ND SÍ lo declara
  #     (opcional), pero `Validations::LineItemValidator` rechaza cualquier valor
  #     mayor a cero, así que el elemento solo podría salir en cero. Se omite en
  #     los cuatro tipos; el día que se soporte, se emite como la partida.
  #   · `LineaDetalle.PartidaArancelaria`   — al revés: existe en NC/ND y no en
  #     FE/TE, así que se emite solo ahí (`PARTIDA_ARANCELARIA_DOC_TYPES`).
  #
  # ── Qué se omite por estar vacío ────────────────────────────────────────────
  # Un elemento sin valor NO se emite en blanco: se omite. Para los opcionales
  # (`minOccurs="0"`) es lo correcto, y para uno obligatorio la omisión es un
  # error mucho más legible que un `<TotalVenta></TotalVenta>`. Lo que NO se
  # omite es el CERO: `0` es un monto válido y es lo que Hacienda espera en los
  # totales que no aplican.
  class XmlBuilder
    # Un valor no se puede representar en el XML (una fecha que no se puede
    # interpretar). Se levanta acá y no se manda un XML malo: el rechazo de
    # Hacienda por un `xs:dateTime` inválido no dice qué campo fue.
    class InvalidValue < StandardError; end

    # El tipo de comprobante todavía no tiene su XML armado en este producto.
    class UnsupportedDocType < StandardError; end

    NAMESPACE_BASE = 'https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4'

    # Raíz y último segmento del namespace, por tipo de comprobante. Los valores
    # salen del `Web.config` del legacy (`namespacefe`, `namespacete`,
    # `namespacenc`, `namespacend`) y de los `XmlRootAttribute` de
    # `SerializeDoc.getSerializeDocFETE` / `getSerializeDocNCND`.
    #
    # Son TRES esquemas, no cinco: FE y TE comparten `DocumentoFETE` (el nombre
    # del tipo es literalmente "Factura Electrónica / Tiquete Electrónico"), ND
    # y NC comparten `DocumentoNCND`, y FEC tiene el suyo. Dentro de cada par,
    # lo único que cambia es la raíz y el namespace. Los dos tipos que faltan
    # (FEE, REP) tienen estructura propia y su armado es otro trabajo; ver
    # `TODOS.md` → Emisión de documentos.
    DOCUMENTS = {
      DocType::FE  => ['FacturaElectronica', 'facturaElectronica'],
      DocType::TE  => ['TiqueteElectronico', 'tiqueteElectronico'],
      DocType::ND  => ['NotaDebitoElectronica', 'notaDebitoElectronica'],
      DocType::NC  => ['NotaCreditoElectronica', 'notaCreditoElectronica'],
      DocType::FEC => ['FacturaElectronicaCompra', 'facturaElectronicaCompra']
    }.freeze

    # Tipos cuyo esquema define `PartidaArancelaria` en la línea de detalle.
    #
    # Es la ÚNICA diferencia de forma entre `DocumentoFETE` y `DocumentoNCND`
    # que este producto puede llenar: el XSD de NC/ND la declara opcional entre
    # `NumeroLinea` y `CodigoCABYS` (`NotaCreditoElectronica_V4.4.xsd` L198) y
    # el de FE/TE no la tiene. Emitirla en una factura es un rechazo.
    #
    # La otra diferencia del esquema, `Impuesto.MontoExportacion`, NO se emite
    # en ningún tipo: `Validations::LineItemValidator` la rechaza si viene con
    # un valor mayor a cero —el legacy también, y sin excluir a ningún tipo—,
    # así que el elemento solo podría salir en cero. Ver la nota de "Campos del
    # objeto unificado que NO van en el XML" más arriba.
    PARTIDA_ARANCELARIA_DOC_TYPES = [DocType::ND, DocType::NC].freeze

    # ── `DocumentoFEC` es `DocumentoFETE` MENOS cinco elementos ───────────────
    # La factura de compra comparte el orden de la raíz, del resumen, de la
    # línea y del impuesto con la factura de venta; lo que hace es QUITAR
    # elementos (verificado uno por uno entre `FacturaElectronica_V4.4.xsd` y
    # `FacturaElectronicaCompra_V4.4.xsd`, 168 vs 128 elementos):
    #
    #   · `LineaDetalle.IVACobradoFabrica`
    #   · `LineaDetalle.ImpuestoAsumidoEmisorFabrica`
    #   · `Impuesto.DatosImpuestoEspecifico` (el bloque entero)
    #   · `ResumenFactura.TotalIVADevuelto`
    #   · `LineaDetalle.DetalleSurtido` (que este producto nunca emitió)
    #
    # Los cuatro primeros son de impuestos que solo existen en una venta al
    # consumidor final; la factura de compra documenta lo contrario.
    #
    # La quinta diferencia NO es una baja sino un CAMBIO DE BLOQUE:
    # `OtrasSenasExtranjero` está en el receptor de FE/TE/ND/NC y en el EMISOR
    # de FEC. Es la misma inversión de roles que invierte el código de
    # actividad (`HeaderValidator::ACTIVIDAD_*`): en una factura de compra el
    # que puede ser extranjero es quien emite, no quien recibe.
    #
    # Las cinco se resuelven con el predicado `#factura_de_compra?` y un guard
    # en la línea donde el elemento se emitiría, en vez de con una tabla de
    # rutas: esta clase emite campo por campo a propósito (ver la cabecera), y
    # una omisión se tiene que poder leer justo donde ocurre.

    # Los dos prefijos que declaraba el legacy en la raíz
    # (`SerializeDoc.cs:77-78`). No se usan en ningún elemento, así que la
    # canonicalización exclusiva de la firma los descarta del digest; se
    # declaran igual para que el XML sea idéntico al que emitía el .NET.
    EXTRA_NAMESPACES = {
      'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
      'xmlns:xsd' => 'http://www.w3.org/2001/XMLSchema'
    }.freeze

    # Decimales MÁXIMOS de cada familia de números, según los `xs:fractionDigits`
    # del XSD 4.4. Son topes y no un largo fijo: `226` es tan válido como
    # `226.00000`, así que se emite la representación más corta.
    # Un `xs:dateTime` que ya trae offset explícito (`Z` o `±HH:MM`). El que lo
    # trae se respeta; al que no, se le pone el de la aplicación.
    XS_DATETIME_WITH_OFFSET = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/

    MONEY = 5      # DecimalDineroType — todos los montos y totales
    QUANTITY = 3   # Cantidad
    RATE = 2       # Tarifa, Porcentaje, Proporcion, CantidadUnidadMedida, …
    IVA_FACTOR = 4 # FactorCalculoIVA
    CHARGE_RATE = 5 # PorcentajeOC

    def initialize(payload)
      @doc_type = payload['DocType']
      @document = payload['Document'] || {}
    end

    # @return [String] el XML del comprobante, UTF-8 y sin firmar.
    def call
      root_name, namespace = DOCUMENTS[doc_type] || raise(
        UnsupportedDocType,
        "Este producto todavía no sabe armar el XML de #{DocType.label(doc_type)} (#{doc_type.inspect})."
      )

      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.send(root_name, { 'xmlns' => "#{NAMESPACE_BASE}/#{namespace}" }.merge(EXTRA_NAMESPACES)) do
          emit_document(xml)
        end
      end

      # Sin indentación: los espacios entre elementos son legales y la firma los
      # tolera, pero engordan el Base64 que viaja a Hacienda sin aportar nada.
      builder.to_xml(indent: 0)
    end

    private

    attr_reader :doc_type, :document

    def emit_document(xml)
      text xml, 'Clave', document['Clave']
      text xml, 'ProveedorSistemas', document['ProveedorSistemas']
      text xml, 'CodigoActividadEmisor', document['CodigoActividadEmisor']
      text xml, 'CodigoActividadReceptor', document['CodigoActividadReceptor']
      text xml, 'NumeroConsecutivo', document['NumeroConsecutivo']
      date xml, 'FechaEmision', document['FechaEmision']
      emit_emisor(xml)
      emit_receptor(xml)
      text xml, 'CondicionVenta', document['CondicionVenta']
      text xml, 'CondicionVentaOtros', document['CondicionVentaOtros']
      integer xml, 'PlazoCredito', document['PlazoCredito']
      emit_lines(xml)
      emit_other_charges(xml)
      emit_summary(xml)
      emit_references(xml)
      emit_others(xml)
    end

    # ── Emisor y receptor ─────────────────────────────────────────────────────

    def emit_emisor(xml)
      emisor = document['Emisor'] || {}

      xml.Emisor do
        text xml, 'Nombre', emisor['Nombre']
        emit_identificacion(xml, emisor['Identificacion'])
        text xml, 'Registrofiscal8707', emisor['Registrofiscal8707']
        text xml, 'NombreComercial', emisor['NombreComercial']
        emit_ubicacion(xml, emisor['Ubicacion'])
        # Solo en la factura de compra: en los demás tipos el emisor es la
        # compañía y el esquema no declara este elemento.
        text xml, 'OtrasSenasExtranjero', emisor['OtrasSenasExtranjero'] if factura_de_compra?
        emit_telefono(xml, emisor['Telefono'])
        text xml, 'CorreoElectronico', emisor['CorreoElectronico']
      end
    end

    # `IdentificacionExtranjero` del objeto unificado NO se emite: el esquema de
    # FE/TE no lo define (es de FEE). Ver la cabecera de la clase.
    def emit_receptor(xml)
      receptor = document['Receptor'] || {}

      xml.Receptor do
        text xml, 'Nombre', receptor['Nombre']
        emit_identificacion(xml, receptor['Identificacion'])
        text xml, 'NombreComercial', receptor['NombreComercial']
        emit_ubicacion(xml, receptor['Ubicacion'])
        # Al revés que en el emisor: el receptor de una factura de compra es la
        # compañía, así que ahí el esquema no lo declara.
        text xml, 'OtrasSenasExtranjero', receptor['OtrasSenasExtranjero'] unless factura_de_compra?
        emit_telefono(xml, receptor['Telefono'])
        text xml, 'CorreoElectronico', receptor['CorreoElectronico']
      end
    end

    def emit_identificacion(xml, identificacion)
      return if blank_block?(identificacion)

      xml.Identificacion do
        text xml, 'Tipo', identificacion['Tipo']
        text xml, 'Numero', identificacion['Numero']
      end
    end

    def emit_ubicacion(xml, ubicacion)
      return if blank_block?(ubicacion)

      xml.Ubicacion do
        text xml, 'Provincia', ubicacion['Provincia']
        text xml, 'Canton', ubicacion['Canton']
        text xml, 'Distrito', ubicacion['Distrito']
        text xml, 'Barrio', ubicacion['Barrio']
        text xml, 'OtrasSenas', ubicacion['OtrasSenas']
      end
    end

    def emit_telefono(xml, telefono)
      return if blank_block?(telefono)

      xml.Telefono do
        integer xml, 'CodigoPais', telefono['CodigoPais']
        text xml, 'NumTelefono', telefono['NumTelefono']
      end
    end

    # ── Líneas de detalle ─────────────────────────────────────────────────────

    # `DetalleServicio` es un ENVOLTORIO con una `LineaDetalle` por línea, no una
    # lista de `DetalleServicio` repetidos — al revés de `OtrosCargos` y
    # `InformacionReferencia`, que sí se repiten sueltos.
    def emit_lines(xml)
      lines = document['DetalleServicio'] || []
      return if lines.empty?

      xml.DetalleServicio do
        lines.each { |line| emit_line(xml, line) }
      end
    end

    def emit_line(xml, line)
      xml.LineaDetalle do
        integer xml, 'NumeroLinea', line['NumeroLinea']
        text xml, 'PartidaArancelaria', line['PartidaArancelaria'] if partida_arancelaria?
        text xml, 'CodigoCABYS', line['CodigoCABYS']
        emit_codigo_comercial(xml, line['CodigoComercial'])
        decimal xml, 'Cantidad', line['Cantidad'], QUANTITY
        text xml, 'UnidadMedida', line['UnidadMedida']
        text xml, 'TipoTransaccion', line['TipoTransaccion']
        text xml, 'UnidadMedidaComercial', line['UnidadMedidaComercial']
        text xml, 'Detalle', line['Detalle']
        text xml, 'NumeroVINoSerie', line['NumeroVINoSerie']
        text xml, 'RegistroMedicamento', line['RegistroMedicamento']
        text xml, 'FormaFarmaceutica', line['FormaFarmaceutica']
        decimal xml, 'PrecioUnitario', line['PrecioUnitario'], MONEY
        decimal xml, 'MontoTotal', line['MontoTotal'], MONEY
        emit_descuento(xml, line['Descuento'])
        decimal xml, 'SubTotal', line['SubTotal'], MONEY
        text xml, 'IVACobradoFabrica', line['IVACobradoFabrica'] unless factura_de_compra?
        decimal xml, 'BaseImponible', line['BaseImponible'], MONEY
        emit_impuesto(xml, line['Impuesto'])
        unless factura_de_compra?
          decimal xml, 'ImpuestoAsumidoEmisorFabrica', line['ImpuestoAsumidoEmisorFabrica'], MONEY
        end
        decimal xml, 'ImpuestoNeto', line['ImpuestoNeto'], MONEY
        decimal xml, 'MontoTotalLinea', line['MontoTotalLinea'], MONEY
      end
    end

    def partida_arancelaria? = PARTIDA_ARANCELARIA_DOC_TYPES.include?(doc_type)

    # ⚠️ "FEC" acá es el TIPO de comprobante (`08`, Factura Electrónica de
    # Compra), no el identificador del producto — que también es FEC y aparece
    # en cada UDF (`U_CL_FEC_*`) y en cada descripción de schema (§32). El
    # predicado se llama por el nombre largo justamente para que nadie lea
    # `fec?` como "¿es de esta aplicación?".
    def factura_de_compra? = doc_type == DocType::FEC

    def emit_codigo_comercial(xml, codigo)
      return if blank_block?(codigo)

      xml.CodigoComercial do
        text xml, 'Tipo', codigo['Tipo']
        text xml, 'Codigo', codigo['Codigo']
      end
    end

    # `PorcentajeDescuento` del objeto unificado no se emite: el modelo de FE/TE
    # no lo tiene. Ver la cabecera de la clase.
    def emit_descuento(xml, descuento)
      return if descuento.nil? || descuento['MontoDescuento'].nil?
      # Un descuento de cero no es un descuento: el bloque entero se omite en
      # vez de mandar `<MontoDescuento>0</MontoDescuento>` sin naturaleza, que
      # es lo que Hacienda exige junto al monto.
      return if descuento['MontoDescuento'].to_d.zero?

      xml.Descuento do
        decimal xml, 'MontoDescuento', descuento['MontoDescuento'], MONEY
        text xml, 'CodigoDescuento', descuento['CodigoDescuento']
        text xml, 'CodigoDescuentoOTRO', descuento['CodigoDescuentoOTRO']
        text xml, 'NaturalezaDescuento', descuento['NaturalezaDescuento']
      end
    end

    # `MontoExportacion` del objeto unificado no se emite: es de FEE.
    def emit_impuesto(xml, impuesto)
      return if blank_block?(impuesto)

      xml.Impuesto do
        text xml, 'Codigo', impuesto['Codigo']
        text xml, 'CodigoImpuestoOTRO', impuesto['CodigoImpuestoOTRO']
        text xml, 'CodigoTarifaIVA', impuesto['CodigoTarifaIVA']
        decimal xml, 'Tarifa', impuesto['Tarifa'], RATE
        decimal xml, 'FactorCalculoIVA', impuesto['FactorCalculoIVA'], IVA_FACTOR
        emit_datos_impuesto_especifico(xml, impuesto['DatosImpuestoEspecifico']) unless factura_de_compra?
        decimal xml, 'Monto', impuesto['Monto'], MONEY
        emit_exoneracion(xml, impuesto['Exoneracion'])
      end
    end

    # Todo en cero significa "no hay impuesto específico": el bloque se omite en
    # vez de mandar cinco ceros que no describen nada.
    def emit_datos_impuesto_especifico(xml, datos)
      return if datos.nil? || datos.values.all? { |value| value.nil? || value.to_d.zero? }

      xml.DatosImpuestoEspecifico do
        decimal xml, 'CantidadUnidadMedida', datos['CantidadUnidadMedida'], RATE
        decimal xml, 'Porcentaje', datos['Porcentaje'], RATE
        decimal xml, 'Proporcion', datos['Proporcion'], RATE
        decimal xml, 'VolumenUnidadConsumo', datos['VolumenUnidadConsumo'], RATE
        decimal xml, 'ImpuestoUnidad', datos['ImpuestoUnidad'], MONEY
      end
    end

    def emit_exoneracion(xml, exoneracion)
      return if blank_block?(exoneracion)

      xml.Exoneracion do
        text xml, 'TipoDocumentoEX1', exoneracion['TipoDocumentoEX1']
        text xml, 'TipoDocumentoOTRO', exoneracion['TipoDocumentoOTRO']
        text xml, 'NumeroDocumento', exoneracion['NumeroDocumento']
        integer xml, 'Articulo', exoneracion['Articulo']
        integer xml, 'Inciso', exoneracion['Inciso']
        text xml, 'NombreInstitucion', exoneracion['NombreInstitucion']
        text xml, 'NombreInstitucionOtros', exoneracion['NombreInstitucionOtros']
        date xml, 'FechaEmisionEX', exoneracion['FechaEmisionEX']
        decimal xml, 'TarifaExonerada', exoneracion['TarifaExonerada'], RATE
        decimal xml, 'MontoExoneracion', exoneracion['MontoExoneracion'], MONEY
      end
    end

    # ── Otros cargos ──────────────────────────────────────────────────────────

    # Se repiten SUELTOS (hasta 15), sin envoltorio: en el legacy es el
    # `[XmlElement]` sobre `List<OtrosCargos>`.
    def emit_other_charges(xml)
      (document['OtrosCargos'] || []).each do |charge|
        next if blank_block?(charge)

        xml.OtrosCargos do
          text xml, 'TipoDocumentoOC', charge['TipoDocumentoOC']
          text xml, 'TipoDocumentoOTROS', charge['TipoDocumentoOTROS']
          emit_identificacion_tercero(xml, charge['IdentificacionTercero'])
          text xml, 'NombreTercero', charge['NombreTercero']
          text xml, 'Detalle', charge['Detalle']
          decimal xml, 'PorcentajeOC', charge['PorcentajeOC'], CHARGE_RATE
          decimal xml, 'MontoCargo', charge['MontoCargo'], MONEY
        end
      end
    end

    def emit_identificacion_tercero(xml, identificacion)
      return if blank_block?(identificacion)

      xml.IdentificacionTercero do
        text xml, 'Tipo', identificacion['Tipo']
        text xml, 'Numero', identificacion['Numero']
      end
    end

    # ── Resumen ───────────────────────────────────────────────────────────────

    # ⚠️ `MedioPago` va casi al final —entre `TotalOtrosCargos` y
    # `TotalComprobante`—, no al principio como en el objeto unificado.
    def emit_summary(xml)
      resumen = document['ResumenFactura'] || {}

      xml.ResumenFactura do
        emit_moneda(xml, resumen['CodigoTipoMoneda'])
        %w[TotalServGravados TotalServExentos TotalServExonerado TotalServNoSujeto
           TotalMercanciasGravadas TotalMercanciasExentas TotalMercExonerada TotalMercNoSujeta
           TotalGravado TotalExento TotalExonerado TotalNoSujeto
           TotalVenta TotalDescuentos TotalVentaNeta].each do |field|
          decimal xml, field, resumen[field], MONEY
        end
        emit_tax_breakdown(xml, resumen['TotalDesgloseImpuesto'])
        summary_tax_totals.each { |field| decimal xml, field, resumen[field], MONEY }
        emit_payment_methods(xml, resumen['MedioPago'])
        decimal xml, 'TotalComprobante', resumen['TotalComprobante'], MONEY
      end
    end

    # Los totales de impuesto del resumen, entre el desglose y el medio de
    # pago. `TotalIVADevuelto` no existe en el esquema de la factura de compra.
    def summary_tax_totals
      fields = %w[TotalImpuesto TotalImpAsumEmisorFabrica TotalIVADevuelto TotalOtrosCargos]
      factura_de_compra? ? fields - ['TotalIVADevuelto'] : fields
    end

    def emit_moneda(xml, moneda)
      return if blank_block?(moneda)

      xml.CodigoTipoMoneda do
        text xml, 'CodigoMoneda', moneda['CodigoMoneda']
        decimal xml, 'TipoCambio', moneda['TipoCambio'], MONEY
      end
    end

    def emit_tax_breakdown(xml, breakdown)
      (breakdown || []).each do |tax|
        xml.TotalDesgloseImpuesto do
          text xml, 'Codigo', tax['Codigo']
          text xml, 'CodigoTarifaIVA', tax['CodigoTarifaIVA']
          decimal xml, 'TotalMontoImpuesto', tax['TotalMontoImpuesto'], MONEY
        end
      end
    end

    def emit_payment_methods(xml, methods)
      (methods || []).each do |method|
        next if blank_block?(method)

        xml.MedioPago do
          text xml, 'TipoMedioPago', method['TipoMedioPago']
          text xml, 'MedioPagoOtros', method['MedioPagoOtros']
          decimal xml, 'TotalMedioPago', method['TotalMedioPago'], MONEY
        end
      end
    end

    # ── Referencias y Otros ───────────────────────────────────────────────────

    def emit_references(xml)
      (document['InformacionReferencia'] || []).each do |reference|
        next if blank_block?(reference)

        xml.InformacionReferencia do
          text xml, 'TipoDocIR', reference['TipoDocIR']
          text xml, 'TipoDocRefOTRO', reference['TipoDocRefOTRO']
          text xml, 'Numero', reference['Numero']
          date xml, 'FechaEmisionIR', reference['FechaEmisionIR']
          text xml, 'Codigo', reference['Codigo']
          text xml, 'CodigoReferenciaOTRO', reference['CodigoReferenciaOTRO']
          text xml, 'Razon', reference['Razon']
        end
      end
    end

    # `<Otros>` envuelve un `<OtroTexto codigo="…">` por renglón: el código va
    # como ATRIBUTO y el texto como contenido del elemento.
    def emit_others(xml)
      others = (document['Otros'] || []).reject { |row| row['Texto'].to_s.strip.empty? }
      return if others.empty?

      xml.Otros do
        others.each do |row|
          attributes = row['Codigo'].present? ? { 'codigo' => row['Codigo'].to_s } : {}
          xml.OtroTexto(attributes, row['Texto'].to_s.strip)
        end
      end
    end

    # ── Emisión de valores ────────────────────────────────────────────────────

    def text(xml, name, value)
      formatted = value.to_s.strip
      return if formatted.empty?

      xml.send(name, formatted)
    end

    # El CERO sí se emite: es un monto válido y es lo que Hacienda espera en los
    # totales que no aplican. Solo se omite el `nil`.
    def decimal(xml, name, value, scale)
      return if value.nil?
      return if value.is_a?(String) && value.strip.empty?

      xml.send(name, format_decimal(value, scale))
    end

    def integer(xml, name, value)
      return if value.nil?
      return if value.is_a?(String) && value.strip.empty?

      xml.send(name, value.to_i.to_s)
    end

    def date(xml, name, value)
      formatted = format_datetime(value, name)
      return if formatted.nil?

      xml.send(name, formatted)
    end

    # ¿El bloque entero no tiene nada que emitir? Un `<Ubicacion/>` con los
    # cinco hijos vacíos no aporta y el XSD lo rechaza por los obligatorios.
    def blank_block?(block)
      block.nil? || block.values.all? { |value| value.nil? || value.to_s.strip.empty? }
    end

    # `xs:fractionDigits` es un MÁXIMO, no un largo fijo, así que se redondea al
    # tope y se emite la representación más corta: `226`, no `226.00000`. Sin
    # notación científica —`to_s('F')`— porque `xs:decimal` no la acepta.
    def format_decimal(value, scale)
      rounded = value.to_d.round(scale)
      return rounded.to_i.to_s if rounded.frac.zero?

      rounded.to_s('F').sub(/0+\z/, '')
    end

    # Los tres campos de fecha del esquema son `xs:dateTime`, así que necesitan
    # el offset. Lo que llega de la vista de SAP es texto y nadie lo valida
    # antes (`Hacienda::Validations::HeaderValidator` no mira `FechaEmision`),
    # así que acá se normaliza y una fecha ilegible se corta con el nombre del
    # campo: el rechazo de Hacienda por un `xs:dateTime` inválido no dice cuál.
    #
    # El texto que YA trae offset se pasa tal cual: es lo que mandó SAP y
    # reinterpretarlo solo puede alejarlo del original. Al que no lo trae se le
    # pone el de la aplicación (`America/Costa_Rica`) con `Time.zone.parse`.
    #
    # ⚠️ NO usar `String#to_time`: interpreta en la zona del SISTEMA operativo,
    # no en la de Rails, así que en un servidor en otra zona escribiría una hora
    # de emisión corrida.
    def format_datetime(value, field)
      return nil if value.nil? || value.to_s.strip.empty?
      return value.iso8601 if value.is_a?(Time) || value.is_a?(DateTime)
      return value.in_time_zone.iso8601 if value.is_a?(Date)

      raw = value.to_s.strip
      return raw if raw.match?(XS_DATETIME_WITH_OFFSET)

      parsed = Time.zone.parse(raw)
      raise InvalidValue, invalid_date_message(value, field) if parsed.nil?

      parsed.iso8601
    rescue ArgumentError, TypeError
      raise InvalidValue, invalid_date_message(value, field)
    end

    def invalid_date_message(value, field)
      "El valor #{value.to_s.strip.inspect} del campo #{field} no es una fecha y hora válida."
    end
  end
end

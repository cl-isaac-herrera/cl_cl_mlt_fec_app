# frozen_string_literal: true

module MailReception
  # Extrae del XML de un comprobante (FE/ND/NC, `MailReception::IncomingDocument
  # ::SUPPORTED_DOC_TYPES`) todos los campos que las UDTs de mensaje receptor
  # (`config/sap_schemas/reception_messages_udt.json` y sus hijas) necesitan.
  #
  #   parsed = MailReception::ReceivedDocument.new(attachment.root, doc_type: attachment.doc_type)
  #   parsed.header      # => Hash de campos de @CL_FEC_RECEPTORMSG
  #   parsed.lines       # => Array<Hash>, cada uno con su 'surtido' anidado
  #   parsed.payments / other_charges / others / references
  #
  # Migra `MapMessageReceiver` del mail parser legacy
  # (`legacy/reception/clvsfemailsconector/FEProcesadorCorreoLib/Classes/
  # InvoiceHandler.cs:589-842`), pero por XPath genérico contra el nombre de
  # elemento (namespaces ya removidos por `IncomingDocument.parse`) en vez de
  # deserializar contra una clase por versión de esquema — el legacy tenía DOS
  # mapeos casi gemelos (v4.3/v4.4, `fe.cs`/`fe43.cs`) porque deserializaba
  # tipado; acá un elemento ausente simplemente da `nil`, así que un solo
  # mapeo cubre las dos formas sin duplicar código. **Solo v4.4** — v4.3 ya no
  # es lo que emite ningún proveedor activo; si apareciera, los campos que
  # v4.3 no tiene (surtido, `DatosImpuestoEspecifico`, `MedioPago`/
  # `InformacionReferencia` como lista) simplemente saldrían vacíos, no habría
  # un error.
  #
  # Los nombres de elemento están tomados de `Hacienda::XmlBuilder` (que arma
  # este mismo XML del lado de emisión, verificado contra el XSD real), no
  # inventados ni copiados de los nombres de PROPIEDAD del modelo C# legacy
  # (que a veces difieren del nombre de elemento real — p. ej. la exoneración
  # de línea es `TipoDocumentoEX1`/`NumeroDocumento`/`Articulo`/`Inciso` en el
  # XML, aunque `MensajeReceptorLinea` los guarde como `ETipoDocumento`/
  # `ENumeroDocumento`/`EArticulo`/`EInciso`).
  #
  # ⚠️ `DetalleSurtido`/`LineaDetalleSurtido` no lo emite `Hacienda::XmlBuilder`
  # (este producto nunca lo generó del lado de emisión), así que sus nombres
  # de sub-elemento acá se tomaron por SIMETRÍA con `LineaDetalle` (mismos
  # campos que una línea normal), sin poder cotejarlos contra el XSD real como
  # el resto de esta clase. Ver `TODOS.md` → Recepción de documentos.
  class ReceivedDocument
    # @param root [Nokogiri::XML::Element] la raíz del documento, con
    #   namespaces ya removidos (`IncomingDocument::Attachment#root`).
    # @param doc_type [String] `DocType::FE`, `DocType::ND` o `DocType::NC`.
    def initialize(root, doc_type:)
      @root = root
      @doc_type = doc_type
    end

    # @return [Hash] campos de la cabecera (`@CL_FEC_RECEPTORMSG`) que salen
    #   del XML. Los que dependen del cuerpo del correo, de la compañía o del
    #   propio proceso (Mensaje, DetalleMensaje, CondicionImpuesto, TaxFactor,
    #   Status, fechas de proceso) NO están acá — los resuelve
    #   `Sap::ReceptionMessages.create_from_document`.
    def header
      {
        'Clave' => text('Clave'),
        'DocType' => @doc_type,
        'ProveedorSistemas' => text('ProveedorSistemas'),
        'NumeroConsecutivoEmisor' => text('NumeroConsecutivo'),
        'FechaEmisionDoc' => text('FechaEmision'),
        'FechaEmisionXML' => text('FechaEmision'),
        'CondicionVenta' => text('CondicionVenta'),
        'CondicionVentaOtros' => text('CondicionVentaOtros'),
        'PlazoCredito' => integer('PlazoCredito')
      }.merge(emisor_fields).merge(receptor_fields).merge(summary_fields).merge(first_reference_fields)
    end

    # @return [Array<Hash>] una por `LineaDetalle`, con 'surtido' anidado
    #   (Array<Hash>, vacío si la línea no trae `DetalleSurtido`).
    def lines
      @root.xpath('DetalleServicio/LineaDetalle').map { |node| line_fields(node) }
    end

    def payments
      @root.xpath('ResumenFactura/MedioPago').map { |node| payment_fields(node) }
    end

    def other_charges
      @root.xpath('OtrosCargos').map { |node| other_charge_fields(node) }
    end

    def others
      @root.xpath('Otros/OtroTexto').map { |node| other_fields(node) }
    end

    # Memoizado: `header` reusa la primera para la copia plana de cabecera
    # (mismo criterio que el legacy, que duplica la primera referencia en los
    # campos `InfRef*` de `MensajeReceptor` además de la colección completa).
    def references
      @references ||= @root.xpath('InformacionReferencia').map { |node| reference_fields(node) }
    end

    private

    def emisor_fields
      emisor = @root.at_xpath('Emisor')

      {
        'NumeroCedulaEmisor' => text('Identificacion/Numero', emisor),
        'TipoIdentificacionEmisor' => text('Identificacion/Tipo', emisor),
        'EmsrIdeTipo' => text('Identificacion/Tipo', emisor),
        'EmsrIdeNumero' => text('Identificacion/Numero', emisor),
        'EmsrNombre' => text('Nombre', emisor),
        'EmsrNombreComercial' => text('NombreComercial', emisor),
        'EmsrCorreoElectronico' => text('CorreoElectronico', emisor),
        'EmsrUbProvincia' => text('Ubicacion/Provincia', emisor),
        'EmsrUbCanton' => text('Ubicacion/Canton', emisor),
        'EmsrUbDistrito' => text('Ubicacion/Distrito', emisor),
        'EmsrUbBarrio' => text('Ubicacion/Barrio', emisor),
        'EmsrUbOtrasSenas' => text('Ubicacion/OtrasSenas', emisor),
        'EmsrTlfCodigoPais' => integer('Telefono/CodigoPais', emisor),
        'EmsrTlfNumTelefono' => text('Telefono/NumTelefono', emisor),
        'EmsrRegistrofiscal8707' => text('Registrofiscal8707', emisor)
        # `EmsrOtrasSenasExtranjero` no se lee: en FE/ND/NC ese elemento va en
        # el RECEPTOR, no en el emisor — es propio de FEC, fuera de alcance
        # (`Hacienda::XmlBuilder#emit_emisor`, guard `factura_de_compra?`).
      }
    end

    def receptor_fields
      receptor = @root.at_xpath('Receptor')

      {
        'NumeroCedulaReceptor' => text('Identificacion/Numero', receptor),
        'TipoIdentificacionReceptor' => text('Identificacion/Tipo', receptor),
        'RcprIdeTipo' => text('Identificacion/Tipo', receptor),
        'RcprIdeNumero' => text('Identificacion/Numero', receptor),
        'RcprNombre' => text('Nombre', receptor),
        'RcprNombreComercial' => text('NombreComercial', receptor),
        'RcprCorreoElectronico' => text('CorreoElectronico', receptor),
        'RcprUbProvincia' => text('Ubicacion/Provincia', receptor),
        'RcprUbCanton' => text('Ubicacion/Canton', receptor),
        'RcprUbDistrito' => text('Ubicacion/Distrito', receptor),
        'RcprUbBarrio' => text('Ubicacion/Barrio', receptor),
        'RcprUbOtrasSenas' => text('Ubicacion/OtrasSenas', receptor),
        'RcprOtrasSenasExtranjero' => text('OtrasSenasExtranjero', receptor),
        'RcprTlfCodigoPais' => integer('Telefono/CodigoPais', receptor),
        'RcprTlfNumTelefono' => text('Telefono/NumTelefono', receptor)
        # `RcprIdentificacionExtranjero` no se lee: el esquema de FE/ND/NC no
        # lo declara (es de FEE, fuera de alcance).
      }
    end

    def summary_fields
      resumen = @root.at_xpath('ResumenFactura')

      {
        'CodigoMoneda' => text('CodigoTipoMoneda/CodigoMoneda', resumen),
        'TipoCambio' => decimal('CodigoTipoMoneda/TipoCambio', resumen),
        'TotalServGravados' => decimal('TotalServGravados', resumen),
        'TotalServExentos' => decimal('TotalServExentos', resumen),
        'TotalServExonerado' => decimal('TotalServExonerado', resumen),
        'TotalServNoSujeto' => decimal('TotalServNoSujeto', resumen),
        'TotalMercanciasGravadas' => decimal('TotalMercanciasGravadas', resumen),
        'TotalMercanciasExentas' => decimal('TotalMercanciasExentas', resumen),
        'TotalMercExonerada' => decimal('TotalMercExonerada', resumen),
        'TotalMercNoSujeta' => decimal('TotalMercNoSujeta', resumen),
        'TotalGravado' => decimal('TotalGravado', resumen),
        'TotalExento' => decimal('TotalExento', resumen),
        'TotalExonerado' => decimal('TotalExonerado', resumen),
        'TotalNoSujeto' => decimal('TotalNoSujeto', resumen),
        'TotalVenta' => decimal('TotalVenta', resumen),
        'TotalDescuentos' => decimal('TotalDescuentos', resumen),
        'TotalVentaNeta' => decimal('TotalVentaNeta', resumen),
        'TotalImpuesto' => decimal('TotalImpuesto', resumen),
        'MontoTotalImpuesto' => decimal('TotalImpuesto', resumen),
        'TotalImpAsumEmisorFabrica' => decimal('TotalImpAsumEmisorFabrica', resumen),
        'TotalIVADevuelto' => decimal('TotalIVADevuelto', resumen),
        'TotalOtrosCargos' => decimal('TotalOtrosCargos', resumen),
        'TotalComprobante' => decimal('TotalComprobante', resumen),
        'TotalFactura' => decimal('TotalComprobante', resumen)
      }
    end

    def first_reference_fields
      first = references.first
      return {} unless first

      first.slice('InfRefTipoDoc', 'InfRefTipoDocRefOTRO', 'InfRefNumero', 'InfRefFechaEmision',
                  'InfRefCodigo', 'InfCodigoReferenciaOTRO', 'InfRefRazon')
    end

    def line_fields(node)
      impuesto = node.at_xpath('Impuesto')
      exoneracion = impuesto&.at_xpath('Exoneracion')
      especifico = impuesto&.at_xpath('DatosImpuestoEspecifico')
      descuento = node.at_xpath('Descuento')

      {
        'NumeroLinea' => integer('NumeroLinea', node),
        'Codigo' => text('CodigoCABYS', node),
        'CodTipo' => text('CodigoComercial/Tipo', node),
        'CodCodigo' => text('CodigoComercial/Codigo', node),
        'PartidaArancelaria' => text('PartidaArancelaria', node),
        'Cantidad' => decimal('Cantidad', node),
        'UnidadMedida' => text('UnidadMedida', node),
        'UnidadMedidaComercial' => text('UnidadMedidaComercial', node),
        'Detalle' => text('Detalle', node),
        'PrecioUnitario' => decimal('PrecioUnitario', node),
        'MontoTotal' => decimal('MontoTotal', node),
        'MontoDescuento' => decimal('MontoDescuento', descuento),
        'NaturalezaDescuento' => text('NaturalezaDescuento', descuento),
        'DCodigoDescuento' => text('CodigoDescuento', descuento),
        'DCodigoDescuentoOTRO' => text('CodigoDescuentoOTRO', descuento),
        'SubTotal' => decimal('SubTotal', node),
        'BaseImponible' => decimal('BaseImponible', node),
        'ImpuestoNeto' => decimal('ImpuestoNeto', node),
        'MontoTotalLinea' => decimal('MontoTotalLinea', node),
        'ImpCodigo' => text('Codigo', impuesto),
        'ImpCodigoImpuestoOTRO' => text('CodigoImpuestoOTRO', impuesto),
        'ImpCodigoTarifa' => text('CodigoTarifaIVA', impuesto),
        'ImpTarifa' => decimal('Tarifa', impuesto),
        'ImpFactorIVA' => decimal('FactorCalculoIVA', impuesto),
        'ImpMonto' => decimal('Monto', impuesto),
        'ImpCantidadUnidadMedida' => decimal('CantidadUnidadMedida', especifico),
        'ImpPorcentaje' => decimal('Porcentaje', especifico),
        'ImpProporcion' => decimal('Proporcion', especifico),
        'ImpVolumenUnidadConsumo' => decimal('VolumenUnidadConsumo', especifico),
        'ImpImpuestoUnidad' => decimal('ImpuestoUnidad', especifico),
        'IVACobradoFabrica' => text('IVACobradoFabrica', node),
        'ImpuestoAsumidoEmisorFabrica' => decimal('ImpuestoAsumidoEmisorFabrica', node),
        'ETipoDocumento' => text('TipoDocumentoEX1', exoneracion),
        'ETipoDocumentoOtro' => text('TipoDocumentoOTRO', exoneracion),
        'ENumeroDocumento' => text('NumeroDocumento', exoneracion),
        'EFechaEmision' => text('FechaEmisionEX', exoneracion),
        'ENombreInstitucion' => text('NombreInstitucion', exoneracion),
        'ENombreInstitucionOtros' => text('NombreInstitucionOtros', exoneracion),
        'ETarifaExonerada' => decimal('TarifaExonerada', exoneracion),
        'EMontoExoneracion' => decimal('MontoExoneracion', exoneracion),
        'EArticulo' => integer('Articulo', exoneracion),
        'EInciso' => integer('Inciso', exoneracion),
        'TipoTransaccion' => text('TipoTransaccion', node),
        'NumeroVINoSerie' => text('NumeroVINoSerie', node),
        'RegistroMedicamento' => text('RegistroMedicamento', node),
        'FormaFarmaceutica' => text('FormaFarmaceutica', node),
        'surtido' => node.xpath('DetalleSurtido/LineaDetalleSurtido').map { |s| surtido_fields(s) }
      }
    end

    # ⚠️ Sin verificar contra el XSD real — ver el comentario de cabecera de
    # la clase y `TODOS.md` → Recepción de documentos.
    def surtido_fields(node)
      impuesto = node.at_xpath('Impuesto')
      descuento = node.at_xpath('Descuento')

      {
        'CodigoCABYSSurtido' => text('CodigoCABYS', node),
        'CodTipoSurtido' => text('CodigoComercial/Tipo', node),
        'CodCodigoSurtido' => text('CodigoComercial/Codigo', node),
        'CantidadSurtido' => decimal('Cantidad', node),
        'UnidadMedidaSurtido' => text('UnidadMedida', node),
        'UnidadMedidaComercialSurtido' => text('UnidadMedidaComercial', node),
        'Detalle' => text('Detalle', node),
        'PrecioUnitarioSurtido' => decimal('PrecioUnitario', node),
        'MontoTotalSurtido' => decimal('MontoTotal', node),
        'MontoDescuentoSurtido' => decimal('MontoDescuento', descuento),
        'CodigoDescuentoSurtido' => text('CodigoDescuento', descuento),
        'DescuentoSurtidoOtros' => text('CodigoDescuentoOTRO', descuento),
        'SubTotalSurtido' => decimal('SubTotal', node),
        'BaseImponibleSurtido' => decimal('BaseImponible', node),
        'IVACobradoFabricaSurtido' => text('IVACobradoFabrica', node),
        'ImpCodigoImpuestoSurtido' => text('Codigo', impuesto),
        'ImpCodigoImpuestoOTROSurtido' => text('CodigoImpuestoOTRO', impuesto),
        'ImpTarifaIVASurtido' => text('CodigoTarifaIVA', impuesto),
        'ImpTarifaSurtido' => decimal('Tarifa', impuesto),
        'ImpMontoSurtido' => decimal('Monto', impuesto)
      }
    end

    def payment_fields(node)
      {
        'TipoMedioPago' => text('TipoMedioPago', node),
        'MedioPagoOtros' => text('MedioPagoOtros', node),
        'TotalMedioPago' => decimal('TotalMedioPago', node)
      }
    end

    def other_charge_fields(node)
      identificacion = node.at_xpath('IdentificacionTercero')

      {
        'TipoDocumento' => text('TipoDocumentoOC', node),
        'TipoIdentidadTercero' => text('Tipo', identificacion),
        'NumeroIdentidadTercero' => text('Numero', identificacion),
        'NombreTercero' => text('NombreTercero', node),
        'Detalle' => text('Detalle', node),
        'Porcentaje' => decimal('PorcentajeOC', node),
        'MontoCargo' => decimal('MontoCargo', node)
      }
    end

    # `codigo` viaja como ATRIBUTO del elemento (`<OtroTexto codigo="…">…`),
    # no como hijo — mismo criterio que `Hacienda::XmlBuilder#emit_others`.
    # `TipoDocumento`/`Compania`/`NumeroDocumento` no salen del XML: el
    # legacy los arma con datos que no están en el comprobante (el propio
    # `DocType` del mensaje, y el id de compañía multi-tenant que ya no
    # existe, CLAUDE.md §31) — acá `TipoDocumento` sí se puede reponer
    # (`@doc_type`), pero `Compania`/`NumeroDocumento` quedan sin dato.
    def other_fields(node)
      {
        'Codigo' => node['codigo'],
        'TipoDocumento' => @doc_type,
        'Valor' => node.text&.strip&.presence
      }
    end

    def reference_fields(node)
      {
        'InfRefTipoDoc' => text('TipoDocIR', node),
        'InfRefTipoDocRefOTRO' => text('TipoDocRefOTRO', node),
        'InfRefNumero' => text('Numero', node),
        'InfRefFechaEmision' => text('FechaEmisionIR', node),
        'InfRefCodigo' => text('Codigo', node),
        'InfCodigoReferenciaOTRO' => text('CodigoReferenciaOTRO', node),
        'InfRefRazon' => text('Razon', node)
      }
    end

    def text(path, node = @root)
      node&.at_xpath(path)&.text&.strip&.presence
    end

    def integer(path, node = @root)
      text(path, node)&.to_i
    end

    def decimal(path, node = @root)
      text(path, node)&.to_d
    end
  end
end

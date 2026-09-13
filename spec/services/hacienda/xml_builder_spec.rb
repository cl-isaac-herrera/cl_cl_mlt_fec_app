# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::XmlBuilder do
  # El orden es el CONTRATO con Hacienda: el XSD declara cada bloque como
  # `xs:sequence`, así que un elemento fuera de lugar es un rechazo. Estas
  # listas son la secuencia del esquema 4.4, escritas a mano a propósito: si
  # alguien reordena el emisor, el spec falla y dice exactamente dónde.
  # Sin `CondicionVentaOtros`, `OtrosCargos`, `InformacionReferencia` ni `Otros`:
  # el documento de prueba no los trae y los opcionales vacíos se omiten. Cada
  # uno tiene su propio ejemplo más abajo.
  ROOT_SEQUENCE = %w[
    Clave ProveedorSistemas CodigoActividadEmisor CodigoActividadReceptor
    NumeroConsecutivo FechaEmision Emisor Receptor CondicionVenta
    PlazoCredito DetalleServicio ResumenFactura
  ].freeze

  LINE_SEQUENCE = %w[
    NumeroLinea CodigoCABYS CodigoComercial Cantidad UnidadMedida Detalle
    PrecioUnitario MontoTotal SubTotal BaseImponible Impuesto
    ImpuestoAsumidoEmisorFabrica ImpuestoNeto MontoTotalLinea
  ].freeze

  SUMMARY_SEQUENCE = %w[
    CodigoTipoMoneda TotalServGravados TotalServExentos TotalServExonerado
    TotalServNoSujeto TotalMercanciasGravadas TotalMercanciasExentas
    TotalMercExonerada TotalMercNoSujeta TotalGravado TotalExento
    TotalExonerado TotalNoSujeto TotalVenta TotalDescuentos TotalVentaNeta
    TotalDesgloseImpuesto TotalImpuesto TotalImpAsumEmisorFabrica
    TotalIVADevuelto TotalOtrosCargos TotalComprobante
  ].freeze

  def build(document = valid_unified_document, doc_type: DocType::FE)
    described_class.new('DocType' => doc_type, 'Document' => document).call
  end

  def parse(document = valid_unified_document, doc_type: DocType::FE)
    Nokogiri::XML(build(document, doc_type: doc_type))
  end

  # Se quita el namespace por defecto para poder consultar con XPath sin
  # prefijos en todo el spec. La presencia del namespace se verifica aparte.
  def doc_without_ns(document = valid_unified_document, doc_type: DocType::FE)
    parse(document, doc_type: doc_type).tap(&:remove_namespaces!)
  end

  describe 'raíz y namespace' do
    it 'la factura electrónica usa su raíz y su namespace 4.4' do
      root = parse.root

      expect(root.name).to eq('FacturaElectronica')
      expect(root.namespace.href)
        .to eq('https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/facturaElectronica')
    end

    # FE y TE comparten el esquema entero: solo cambian la raíz y el namespace.
    it 'el tiquete electrónico solo cambia la raíz y el namespace' do
      root = parse(doc_type: DocType::TE).root

      expect(root.name).to eq('TiqueteElectronico')
      expect(root.namespace.href)
        .to eq('https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/tiqueteElectronico')
    end

    # ND y NC comparten `DocumentoNCND` entre sí, igual que FE y TE comparten
    # `DocumentoFETE`. Los valores salen del `Web.config` del legacy
    # (`namespacend`, `namespacenc`).
    it 'la nota de débito usa su raíz y su namespace' do
      root = parse(doc_type: DocType::ND).root

      expect(root.name).to eq('NotaDebitoElectronica')
      expect(root.namespace.href)
        .to eq('https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/notaDebitoElectronica')
    end

    it 'la nota de crédito usa su raíz y su namespace' do
      root = parse(doc_type: DocType::NC).root

      expect(root.name).to eq('NotaCreditoElectronica')
      expect(root.namespace.href)
        .to eq('https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/notaCreditoElectronica')
    end

    # Los hijos van SIN prefijo y heredan el namespace por defecto de la raíz;
    # si quedaran fuera del namespace, Hacienda no reconoce el comprobante.
    it 'los hijos heredan el namespace del comprobante' do
      clave = parse.root.elements.first

      expect(clave.name).to eq('Clave')
      expect(clave.namespace.href).to include('facturaElectronica')
    end

    it 'la factura de compra usa su raíz y su namespace' do
      root = parse(doc_type: DocType::FEC).root

      expect(root.name).to eq('FacturaElectronicaCompra')
      expect(root.namespace.href)
        .to eq('https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/facturaElectronicaCompra')
    end

    it 'no arma el XML de un tipo que todavía no sabe serializar' do
      expect { build(doc_type: DocType::FEE) }
        .to raise_error(described_class::UnsupportedDocType, /Factura electrónica de exportación/)
    end
  end

  describe 'orden de los elementos' do
    it 'emite la raíz en el orden del xs:sequence' do
      names = doc_without_ns.root.elements.map(&:name)

      expect(names).to eq(ROOT_SEQUENCE)
    end

    it 'emite la línea de detalle en el orden del xs:sequence' do
      names = doc_without_ns.xpath('//LineaDetalle').first.elements.map(&:name)

      expect(names).to eq(LINE_SEQUENCE)
    end

    # `MedioPago` está de PRIMERO en el objeto unificado y va de penúltimo en el
    # XSD. Es el desfase que más fácil se cuela.
    it 'emite el resumen en el orden del xs:sequence' do
      names = doc_without_ns.at_xpath('//ResumenFactura').elements.map(&:name)

      expect(names).to eq(SUMMARY_SEQUENCE)
    end

    it 'pone MedioPago entre TotalOtrosCargos y TotalComprobante' do
      document = valid_unified_document
      document['ResumenFactura'] = valid_resumen_factura(
        'MedioPago' => [{ 'TipoMedioPago' => '01', 'MedioPagoOtros' => nil,
                          'TotalMedioPago' => BigDecimal(226) }]
      )
      names = doc_without_ns(document).at_xpath('//ResumenFactura').elements.map(&:name)

      expect(names.each_cons(3)).to include(%w[TotalOtrosCargos MedioPago TotalComprobante])
    end

    # Los opcionales que el documento de prueba no trae: cuando SÍ vienen, van
    # en su lugar del `xs:sequence` y no al final.
    it 'intercala los opcionales en su posición del xs:sequence' do
      document = valid_unified_document
      document['CondicionVenta'] = '99'
      document['CondicionVentaOtros'] = 'Permuta'
      document['InformacionReferencia'] = [
        { 'TipoDocIR' => '01', 'TipoDocRefOTRO' => nil, 'Numero' => '00100001010000000001',
          'FechaEmisionIR' => '2026-09-01T08:00:00-06:00', 'Codigo' => '01',
          'CodigoReferenciaOTRO' => nil, 'Razon' => 'Anula factura' }
      ]
      document['Otros'] = [{ 'Codigo' => 'Observaciones', 'Texto' => 'Nota' }]
      names = doc_without_ns(document).root.elements.map(&:name)

      expect(names).to eq(%w[Clave ProveedorSistemas CodigoActividadEmisor
                             CodigoActividadReceptor NumeroConsecutivo FechaEmision
                             Emisor Receptor CondicionVenta CondicionVentaOtros
                             PlazoCredito DetalleServicio ResumenFactura
                             InformacionReferencia Otros])
    end

    it 'emite el emisor en el orden del xs:sequence' do
      names = doc_without_ns.at_xpath('//Emisor').elements.map(&:name)

      expect(names).to eq(%w[Nombre Identificacion NombreComercial Ubicacion Telefono
                             CorreoElectronico])
    end
  end

  # `DetalleServicio` va ENVUELTO y `OtrosCargos` / `InformacionReferencia` van
  # sueltos y repetidos. Confundirlo es un rechazo.
  describe 'listas envueltas y sueltas' do
    it 'envuelve las líneas en DetalleServicio/LineaDetalle' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line, valid_line('NumeroLinea' => 2)]
      doc = doc_without_ns(document)

      expect(doc.xpath('/FacturaElectronica/DetalleServicio').size).to eq(1)
      expect(doc.xpath('/FacturaElectronica/DetalleServicio/LineaDetalle').size).to eq(2)
    end

    it 'repite OtrosCargos suelto, sin envoltorio' do
      document = valid_unified_document
      document['OtrosCargos'] = [
        { 'TipoDocumentoOC' => '01', 'TipoDocumentoOTROS' => nil,
          'IdentificacionTercero' => { 'Tipo' => nil, 'Numero' => nil },
          'NombreTercero' => nil, 'Detalle' => 'Servicio', 'PorcentajeOC' => nil,
          'MontoCargo' => BigDecimal(10) }
      ]
      doc = doc_without_ns(document)

      expect(doc.xpath('/FacturaElectronica/OtrosCargos').size).to eq(1)
      expect(doc.at_xpath('//OtrosCargos').elements.map(&:name))
        .to eq(%w[TipoDocumentoOC Detalle MontoCargo])
    end

    it 'repite TotalDesgloseImpuesto suelto dentro del resumen' do
      doc = doc_without_ns

      expect(doc.xpath('//ResumenFactura/TotalDesgloseImpuesto').size).to eq(1)
      expect(doc.at_xpath('//TotalDesgloseImpuesto').elements.map(&:name))
        .to eq(%w[Codigo CodigoTarifaIVA TotalMontoImpuesto])
    end

    # El código va como ATRIBUTO y el texto como contenido del elemento.
    it 'emite Otros con el código como atributo de OtroTexto' do
      document = valid_unified_document
      document['Otros'] = [{ 'Codigo' => 'Observaciones', 'Texto' => 'Entrega en sitio' }]
      other = doc_without_ns(document).at_xpath('//Otros/OtroTexto')

      expect(other['codigo']).to eq('Observaciones')
      expect(other.text).to eq('Entrega en sitio')
    end

    it 'omite Otros cuando ningún renglón tiene texto' do
      document = valid_unified_document
      document['Otros'] = [{ 'Codigo' => 'Observaciones', 'Texto' => '  ' }]

      expect(doc_without_ns(document).at_xpath('//Otros')).to be_nil
    end
  end

  describe 'formato de los números' do
    # `xs:fractionDigits` es un MÁXIMO, no un largo fijo: se emite la
    # representación más corta y nunca notación científica.
    it 'recorta los ceros de más en los montos' do
      document = valid_unified_document
      document['ResumenFactura'] = valid_resumen_factura('TotalComprobante' => BigDecimal('226.50000'))

      expect(doc_without_ns(document).at_xpath('//TotalComprobante').text).to eq('226.5')
    end

    it 'emite un entero sin punto decimal' do
      expect(doc_without_ns.at_xpath('//TotalComprobante').text).to eq('226')
    end

    # Un total en cero es un dato, no un campo ausente: Hacienda lo espera en
    # los renglones que no aplican.
    it 'emite el cero en vez de omitir el elemento' do
      expect(doc_without_ns.at_xpath('//TotalServGravados').text).to eq('0')
    end

    it 'redondea al tope de decimales del esquema' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line('PrecioUnitario' => BigDecimal('100.1234567'))]

      expect(doc_without_ns(document).at_xpath('//PrecioUnitario').text).to eq('100.12346')
    end

    it 'no usa notación científica en montos grandes' do
      document = valid_unified_document
      document['ResumenFactura'] = valid_resumen_factura('TotalComprobante' => BigDecimal('1e12'))

      expect(doc_without_ns(document).at_xpath('//TotalComprobante').text).to eq('1000000000000')
    end
  end

  describe 'fechas' do
    it 'respeta el offset que ya trae la vista de SAP' do
      expect(doc_without_ns.at_xpath('//FechaEmision').text).to eq('2026-09-05T10:00:00-06:00')
    end

    # SAP puede devolver la fecha sin zona; el comprobante la necesita.
    it 'le pone el offset de la aplicación a una fecha sin zona' do
      document = valid_unified_document
      document['FechaEmision'] = '2026-09-05 10:00:00'

      expect(doc_without_ns(document).at_xpath('//FechaEmision').text)
        .to eq('2026-09-05T10:00:00-06:00')
    end

    # Mejor cortar acá que mandar un `xs:dateTime` inválido: el rechazo de
    # Hacienda no dice qué campo fue.
    it 'corta con el nombre del campo si la fecha no se puede interpretar' do
      document = valid_unified_document
      document['FechaEmision'] = 'el jueves pasado'

      expect { build(document) }
        .to raise_error(described_class::InvalidValue, /FechaEmision/)
    end
  end

  # La ÚNICA diferencia de forma entre `DocumentoFETE` y `DocumentoNCND` que
  # este producto llena. En el XSD de NC/ND va entre `NumeroLinea` y
  # `CodigoCABYS` (`NotaCreditoElectronica_V4.4.xsd` L198); en el de FE/TE no
  # existe, y emitirla ahí es un rechazo.
  describe 'partida arancelaria' do
    it 'la emite en la nota de crédito, después de NumeroLinea' do
      names = doc_without_ns(doc_type: DocType::NC).at_xpath('//LineaDetalle').elements.map(&:name)

      expect(names).to eq(['NumeroLinea', 'PartidaArancelaria', *LINE_SEQUENCE.drop(1)])
    end

    it 'la emite en la nota de débito' do
      doc = doc_without_ns(doc_type: DocType::ND)

      expect(doc.at_xpath('//PartidaArancelaria').text).to eq('0102290000')
    end

    it 'no la emite en la factura ni en el tiquete' do
      expect(doc_without_ns.at_xpath('//PartidaArancelaria')).to be_nil
      expect(doc_without_ns(doc_type: DocType::TE).at_xpath('//PartidaArancelaria')).to be_nil
    end

    it 'la omite en la nota cuando la línea no la trae' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line('PartidaArancelaria' => nil)]

      expect(doc_without_ns(document, doc_type: DocType::NC).at_xpath('//PartidaArancelaria'))
        .to be_nil
    end
  end

  # `DocumentoFEC` es `DocumentoFETE` menos cuatro elementos, con
  # `OtrasSenasExtranjero` cambiado de bloque. Cada ejemplo verifica una de las
  # cinco diferencias, y su contracara en la factura de venta.
  describe 'factura electrónica de compra' do
    it 'omite IVACobradoFabrica y ImpuestoAsumidoEmisorFabrica de la línea' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line('IVACobradoFabrica' => 'S')]
      doc = doc_without_ns(document, doc_type: DocType::FEC)

      expect(doc.at_xpath('//IVACobradoFabrica')).to be_nil
      expect(doc.at_xpath('//ImpuestoAsumidoEmisorFabrica')).to be_nil
      expect(doc.at_xpath('//LineaDetalle').elements.map(&:name))
        .to eq(LINE_SEQUENCE - ['ImpuestoAsumidoEmisorFabrica'])
    end

    it 'omite el bloque DatosImpuestoEspecifico del impuesto' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line(
        'Impuesto' => valid_impuesto('DatosImpuestoEspecifico' => {
                                       'ImpuestoUnidad' => BigDecimal(5), 'Porcentaje' => BigDecimal(1),
                                       'Proporcion' => BigDecimal(0), 'CantidadUnidadMedida' => BigDecimal(0),
                                       'VolumenUnidadConsumo' => BigDecimal(0)
                                     })
      )]

      expect(doc_without_ns(document, doc_type: DocType::FEC).at_xpath('//DatosImpuestoEspecifico'))
        .to be_nil
      expect(doc_without_ns(document).at_xpath('//DatosImpuestoEspecifico')).not_to be_nil
    end

    it 'omite TotalIVADevuelto del resumen' do
      names = doc_without_ns(doc_type: DocType::FEC).at_xpath('//ResumenFactura').elements.map(&:name)

      expect(names).to eq(SUMMARY_SEQUENCE - ['TotalIVADevuelto'])
    end

    # La inversión de roles: el que puede ser extranjero en una compra es quien
    # emite, no quien recibe.
    it 'emite OtrasSenasExtranjero en el emisor y no en el receptor' do
      document = valid_unified_document
      document['Emisor']['OtrasSenasExtranjero'] = 'Miami, Florida'
      document['Receptor']['OtrasSenasExtranjero'] = 'no corresponde'
      doc = doc_without_ns(document, doc_type: DocType::FEC)

      expect(doc.at_xpath('//Emisor/OtrasSenasExtranjero').text).to eq('Miami, Florida')
      expect(doc.at_xpath('//Receptor/OtrasSenasExtranjero')).to be_nil
    end

    it 'en la factura de venta es al revés' do
      document = valid_unified_document
      document['Emisor']['OtrasSenasExtranjero'] = 'no corresponde'
      document['Receptor']['OtrasSenasExtranjero'] = 'Miami, Florida'
      doc = doc_without_ns(document)

      expect(doc.at_xpath('//Emisor/OtrasSenasExtranjero')).to be_nil
      expect(doc.at_xpath('//Receptor/OtrasSenasExtranjero').text).to eq('Miami, Florida')
    end

    it 'no emite la partida arancelaria, que es de las notas' do
      expect(doc_without_ns(doc_type: DocType::FEC).at_xpath('//PartidaArancelaria')).to be_nil
    end

    it 'conserva el orden de la raíz' do
      expect(doc_without_ns(doc_type: DocType::FEC).root.elements.map(&:name)).to eq(ROOT_SEQUENCE)
    end
  end

  # El objeto unificado sirve a todos los tipos y trae campos que el esquema de
  # FE/TE no define. Emitirlos es un rechazo.
  describe 'campos que NO pertenecen al esquema de FE/TE' do
    it 'no emite IdentificacionExtranjero del receptor' do
      document = valid_unified_document
      document['Receptor']['IdentificacionExtranjero'] = 'A-123456'

      expect(doc_without_ns(document).at_xpath('//IdentificacionExtranjero')).to be_nil
    end

    it 'no emite PorcentajeDescuento' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line(
        'Descuento' => { 'MontoDescuento' => BigDecimal(10), 'NaturalezaDescuento' => 'Promoción',
                         'CodigoDescuento' => '01', 'CodigoDescuentoOTRO' => nil,
                         'PorcentajeDescuento' => BigDecimal(5) }
      )]
      doc = doc_without_ns(document)

      expect(doc.at_xpath('//PorcentajeDescuento')).to be_nil
      expect(doc.at_xpath('//Descuento').elements.map(&:name))
        .to eq(%w[MontoDescuento CodigoDescuento NaturalezaDescuento])
    end

    # El esquema de NC/ND SÍ lo declara (opcional), pero `LineItemValidator`
    # rechaza cualquier valor mayor a cero en los cuatro tipos, así que el
    # elemento solo podría salir en cero. Se omite en todos.
    it 'no emite MontoExportacion del impuesto, en ningún tipo' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line(
        'Impuesto' => valid_impuesto('MontoExportacion' => BigDecimal(50))
      )]

      expect(doc_without_ns(document).at_xpath('//MontoExportacion')).to be_nil
      expect(doc_without_ns(document, doc_type: DocType::NC).at_xpath('//MontoExportacion'))
        .to be_nil
    end
  end

  describe 'bloques vacíos' do
    it 'omite el descuento cuando el monto es cero' do
      expect(doc_without_ns.at_xpath('//Descuento')).to be_nil
    end

    it 'omite DatosImpuestoEspecifico cuando todo viene en cero' do
      expect(doc_without_ns.at_xpath('//DatosImpuestoEspecifico')).to be_nil
    end

    it 'omite la exoneración cuando no hay ninguna' do
      expect(doc_without_ns.at_xpath('//Exoneracion')).to be_nil
    end

    it 'omite la ubicación cuando no trae ningún dato' do
      document = valid_unified_document
      document['Receptor']['Ubicacion'] = { 'Provincia' => nil, 'Canton' => nil, 'Distrito' => nil,
                                            'Barrio' => nil, 'OtrasSenas' => nil }

      expect(doc_without_ns(document).at_xpath('//Receptor/Ubicacion')).to be_nil
    end
  end

  # Lo que sigue del flujo: el XML se firma. Si no fuera parseable en estricto,
  # `XmlSigner` reventaría en producción y no acá.
  it 'produce un XML que el firmador puede parsear en modo estricto' do
    expect { Nokogiri::XML(build) { |cfg| cfg.strict } }.not_to raise_error
  end
end

# frozen_string_literal: true

# Un objeto unificado de factura electrónica, MATEMÁTICAMENTE CONSISTENTE de
# punta a punta: pasa las siete reglas de cuadre de `SummaryTotalsValidator` y
# todas las demás. Sirve de punto de partida para los specs de
# `Hacienda::InvoiceValidator` y sus colaboradores: cada ejemplo rompe UN dato
# puntual con `deep_merge`/reasignación y verifica que aparezca (y solo
# aparezca) el error esperado.
#
# Los números están elegidos para que el cuadre sea exacto (sin depender de la
# tolerancia ±0.5): 2 unidades × 100 = 200, IVA 13% = 26.00.
module HaciendaDocumentHelpers
  def valid_invoice_document
    {
      'NumeroConsecutivo' => '00100001010000000001',
      'Clave' => '5' * 50,
      'ProveedorSistemas' => '3101822733',
      'FechaEmision' => '2026-09-05T10:00:00-06:00',
      'CodigoActividadEmisor' => '620100',
      'CodigoActividadReceptor' => '620100',
      'CondicionVenta' => '02',
      'CondicionVentaOtros' => nil,
      'PlazoCredito' => 5,
      'Emisor' => {
        'Nombre' => 'ACME S.A.',
        'Identificacion' => { 'Tipo' => '02', 'Numero' => '3101822733' },
        'Registrofiscal8707' => nil,
        'NombreComercial' => 'ACME',
        'Ubicacion' => valid_ubicacion,
        'Telefono' => { 'CodigoPais' => 506, 'NumTelefono' => '22223333' },
        'CorreoElectronico' => 'facturas@acme.cr'
      },
      'Receptor' => {
        'Nombre' => 'Cliente de prueba',
        'Identificacion' => { 'Tipo' => '01', 'Numero' => '123456789' },
        'IdentificacionExtranjero' => nil,
        'NombreComercial' => nil,
        'Ubicacion' => valid_ubicacion,
        'OtrasSenasExtranjero' => nil,
        'Telefono' => { 'CodigoPais' => 506, 'NumTelefono' => '88889999' },
        'CorreoElectronico' => 'cliente@example.com'
      },
      'DetalleServicio' => [valid_line],
      'ResumenFactura' => valid_resumen_factura,
      'InformacionReferencia' => [],
      'Otros' => [],
      'OtrosCargos' => []
    }
  end

  def valid_ubicacion
    { 'Provincia' => '1', 'Canton' => '01', 'Distrito' => '01', 'Barrio' => 'Centro',
      'OtrasSenas' => 'Frente al parque' }
  end

  # Línea "de oro": 2 × 100 = 200 de venta, IVA 13% = 26.00, sin descuento ni
  # exoneración. `UnidadMedida` NO está en `UNIDADES_DE_SERVICIO`, así que
  # cuenta como mercancía para el recalculo de totales.
  def valid_line(overrides = {})
    {
      'NumeroLinea' => 1,
      'CodigoCABYS' => '1' * 13,
      'CodigoComercial' => { 'Tipo' => '01', 'Codigo' => 'SKU-1' },
      'Cantidad' => BigDecimal(2),
      'UnidadMedida' => 'Unid',
      'UnidadMedidaComercial' => nil,
      'Detalle' => 'Producto de prueba',
      'RegistroMedicamento' => nil,
      'FormaFarmaceutica' => nil,
      'PrecioUnitario' => BigDecimal(100),
      'MontoTotal' => BigDecimal(200),
      'Descuento' => {
        'MontoDescuento' => BigDecimal(0), 'NaturalezaDescuento' => nil,
        'CodigoDescuento' => nil, 'CodigoDescuentoOTRO' => nil,
        'PorcentajeDescuento' => BigDecimal(0)
      },
      'SubTotal' => BigDecimal(200),
      'BaseImponible' => BigDecimal(200),
      'Impuesto' => valid_impuesto,
      'DetalleSurtido' => [],
      'MontoTotalLinea' => BigDecimal(226),
      'ImpuestoNeto' => BigDecimal(26),
      'TipoTransaccion' => nil,
      'IVACobradoFabrica' => nil,
      'NumeroVINoSerie' => nil,
      'ImpuestoAsumidoEmisorFabrica' => BigDecimal(0)
    }.merge(overrides)
  end

  def valid_impuesto(overrides = {})
    {
      'Codigo' => '01', 'CodigoTarifaIVA' => '08', 'CodigoImpuestoOTRO' => nil,
      'Tarifa' => BigDecimal(13), 'FactorCalculoIVA' => nil,
      'DatosImpuestoEspecifico' => {
        'ImpuestoUnidad' => BigDecimal(0), 'Porcentaje' => BigDecimal(0),
        'Proporcion' => BigDecimal(0), 'CantidadUnidadMedida' => BigDecimal(0),
        'VolumenUnidadConsumo' => BigDecimal(0)
      },
      'Monto' => BigDecimal(26), 'MontoExportacion' => BigDecimal(0),
      'Exoneracion' => valid_exoneracion
    }.merge(overrides)
  end

  def valid_exoneracion(overrides = {})
    {
      'TipoDocumentoEX1' => nil, 'TipoDocumentoOTRO' => nil, 'NumeroDocumento' => nil,
      'NombreInstitucion' => nil, 'NombreInstitucionOtros' => nil, 'FechaEmisionEX' => nil,
      'TarifaExonerada' => nil, 'MontoExoneracion' => nil, 'Articulo' => nil, 'Inciso' => nil
    }.merge(overrides)
  end

  def valid_resumen_factura(overrides = {})
    {
      'MedioPago' => [],
      'CodigoTipoMoneda' => { 'CodigoMoneda' => 'CRC', 'TipoCambio' => BigDecimal(1) },
      'TotalServGravados' => BigDecimal(0), 'TotalServExentos' => BigDecimal(0),
      'TotalServExonerado' => BigDecimal(0), 'TotalServNoSujeto' => BigDecimal(0),
      'TotalMercanciasGravadas' => BigDecimal(200), 'TotalMercanciasExentas' => BigDecimal(0),
      'TotalMercExonerada' => BigDecimal(0), 'TotalMercNoSujeta' => BigDecimal(0),
      'TotalGravado' => BigDecimal(200), 'TotalExento' => BigDecimal(0),
      'TotalExonerado' => BigDecimal(0), 'TotalNoSujeto' => BigDecimal(0),
      'TotalVenta' => BigDecimal(200), 'TotalDescuentos' => BigDecimal(0),
      'TotalVentaNeta' => BigDecimal(200),
      'TotalDesgloseImpuesto' => [{ 'Codigo' => '01', 'CodigoTarifaIVA' => '08',
                                    'TotalMontoImpuesto' => BigDecimal(26) }],
      'TotalImpuesto' => BigDecimal(26), 'TotalImpAsumEmisorFabrica' => BigDecimal(0),
      'TotalIVADevuelto' => BigDecimal(0), 'TotalOtrosCargos' => BigDecimal(0),
      'TotalComprobante' => BigDecimal(226)
    }.merge(overrides)
  end
end

RSpec.configure { |config| config.include HaciendaDocumentHelpers }

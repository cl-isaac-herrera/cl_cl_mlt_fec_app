# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::UnifiedBuilder do
  let(:company) { Company.new(name: 'ACME S.A.', sap_db: 'SBO_ACME', economic_activity_code: '620100') }

  def row(attrs) = Documents::Row.new(attrs)

  def build(header: {}, lines: [], other_charges: [], payment_methods: [], references: [], others: [],
            doc_type: DocType::FE)
    details = Sap::DocumentDetails::Result.new(
      header: row(header), lines: lines.map { |l| row(l) },
      other_charges: other_charges.map { |o| row(o) },
      payment_methods: payment_methods.map { |p| row(p) },
      references: references.map { |r| row(r) },
      others: others.map { |o| row(o) }
    )

    described_class.new(company: company, doc_type: doc_type, details: details).call
  end

  describe 'raíz' do
    it 'lleva el tipo de documento, porque el XML que se genere depende de él' do
      expect(build(doc_type: DocType::NC)['DocType']).to eq('03')
    end

    it 'arma el cuerpo del envío a Hacienda con las dos identificaciones' do
      payload = build(header: { 'FechaEmision' => '2026-08-25', 'EmsrIdeNumero' => '3101123456',
                                'EmsrIdeTipo' => '02', 'RcprIdeNumero' => '112345678',
                                'RcprIdeTipo' => '01' })

      expect(payload['SendDocumentHacienda']).to eq(
        'fecha' => '2026-08-25',
        'emisor' => { 'numeroIdentificacion' => '3101123456', 'tipoIdentificacion' => '02' },
        'receptor' => { 'numeroIdentificacion' => '112345678', 'tipoIdentificacion' => '01' }
      )
    end
  end

  describe 'código de actividad del emisor' do
    # La cabecera trae el del RECEPTOR nada más. El del emisor vive en
    # `companies` desde que la configuración de FE bajó de los UDFs de OADM.
    it 'sale de la compañía cuando la vista no lo devuelve' do
      expect(build['Document']['CodigoActividadEmisor']).to eq('620100')
    end

    # Si la vista alguna vez lo expone, ese es el que viajó con el documento.
    it 'prefiere el de SAP si la vista lo devuelve' do
      payload = build(header: { 'CodigoActividadEmisor' => '999999' })

      expect(payload['Document']['CodigoActividadEmisor']).to eq('999999')
    end
  end

  describe 'desglose de impuestos' do
    # Hacienda pide el desglose una vez por combinación código/tarifa, no una por
    # línea: si cinco líneas llevan IVA 13%, va un renglón con la suma.
    it 'agrupa por código y tarifa sumando los montos' do
      payload = build(lines: [
                        { 'ImpCodigo' => '01', 'ImpCodigoTarifa' => '08', 'ImpMonto' => '6.50' },
                        { 'ImpCodigo' => '01', 'ImpCodigoTarifa' => '08', 'ImpMonto' => '6.50' },
                        { 'ImpCodigo' => '01', 'ImpCodigoTarifa' => '04', 'ImpMonto' => '4.00' }
                      ])

      expect(payload['Document']['ResumenFactura']['TotalDesgloseImpuesto']).to eq(
        [
          { 'Codigo' => '01', 'CodigoTarifaIVA' => '08', 'TotalMontoImpuesto' => BigDecimal('13.00') },
          { 'Codigo' => '01', 'CodigoTarifaIVA' => '04', 'TotalMontoImpuesto' => BigDecimal('4.00') }
        ]
      )
    end

    it 'no pierde el renglón cuando una línea de la combinación no trae monto' do
      payload = build(lines: [
                        { 'ImpCodigo' => '01', 'ImpCodigoTarifa' => '08', 'ImpMonto' => '6.50' },
                        { 'ImpCodigo' => '01', 'ImpCodigoTarifa' => '08' }
                      ])

      expect(payload['Document']['ResumenFactura']['TotalDesgloseImpuesto'].first['TotalMontoImpuesto'])
        .to eq(BigDecimal('6.50'))
    end

    it 'ignora las líneas sin código de impuesto' do
      payload = build(lines: [{ 'Detalle' => 'sin impuesto' }])

      expect(payload['Document']['ResumenFactura']['TotalDesgloseImpuesto']).to eq([])
    end
  end

  describe 'bloque Otros' do
    it 'pone las observaciones de la cabecera bajo el código literal' do
      payload = build(header: { 'OtroTexto' => 'Gracias por su compra' })

      expect(payload['Document']['Otros']).to eq(
        [{ 'Codigo' => 'Observaciones', 'Texto' => 'Gracias por su compra' }]
      )
    end

    # Un `Otros` con el código puesto y el contenido vacío es un elemento de más
    # en el XML.
    it 'omite el renglón de observaciones cuando no hay texto' do
      expect(build['Document']['Otros']).to eq([])
    end

    it 'concatena las observaciones con los campos adicionales' do
      payload = build(header: { 'OtroTexto' => 'Nota' },
                      others: [{ 'Codigo' => 'OC1', 'Valor' => 'Valor 1' }])

      expect(payload['Document']['Otros']).to eq(
        [
          { 'Codigo' => 'Observaciones', 'Texto' => 'Nota' },
          { 'Codigo' => 'OC1', 'Texto' => 'Valor 1' }
        ]
      )
    end
  end

  describe 'emisor y receptor' do
    # El mismo bloque con distinto prefijo. Se arma una sola vez para que no
    # puedan divergir.
    it 'arma la ubicación de los dos desde su prefijo' do
      payload = build(header: { 'EmsrUbProvincia' => '1', 'EmsrUbCanton' => '01',
                                'RcprUbProvincia' => '2', 'RcprUbCanton' => '02' })
      document = payload['Document']

      expect(document.dig('Emisor', 'Ubicacion')).to include('Provincia' => '1', 'Canton' => '01')
      expect(document.dig('Receptor', 'Ubicacion')).to include('Provincia' => '2', 'Canton' => '02')
    end

    it 'incluye en el receptor los campos de extranjero que el emisor no tiene' do
      payload = build(header: { 'RcprIdentificacionExtranjero' => 'X123',
                                'RcprOtrasSenasExtranjero' => 'Miami' })

      expect(payload['Document']['Receptor']).to include(
        'IdentificacionExtranjero' => 'X123', 'OtrasSenasExtranjero' => 'Miami'
      )
    end
  end

  describe 'líneas' do
    it 'mapea el CABYS desde la columna Codigo de la vista' do
      payload = build(lines: [{ 'Codigo' => '2311101000000', 'NumeroLinea' => 1 }])

      expect(payload['Document']['DetalleServicio'].first['CodigoCABYS']).to eq('2311101000000')
    end

    # Todavía no hay vista de surtidos: se deja vacío en vez de inventar el dato.
    it 'deja DetalleSurtido vacío mientras no exista la vista' do
      payload = build(lines: [{ 'NumeroLinea' => 1 }])

      expect(payload['Document']['DetalleServicio'].first['DetalleSurtido']).to eq([])
    end

    it 'conserva los montos como BigDecimal' do
      payload = build(lines: [{ 'PrecioUnitario' => '25.00' }])

      expect(payload['Document']['DetalleServicio'].first['PrecioUnitario']).to be_a(BigDecimal)
    end
  end

  describe 'otros cargos' do
    it 'anida la identificación del tercero' do
      payload = build(other_charges: [{ 'TipoIdentidadTercero' => '02',
                                        'NumeroIdentidadTercero' => '3101999888',
                                        'MontoCargo' => '2.50' }])

      expect(payload['Document']['OtrosCargos'].first['IdentificacionTercero'])
        .to eq('Tipo' => '02', 'Numero' => '3101999888')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::UnifiedBuilder do
  # No recibe `company` ni habla con SAP por su cuenta: la vista de cabecera
  # que arma `details.header` (`Sap::DocumentDetails`) ya trae resuelta la
  # identidad de `Emsr*`/`Rcpr*` para el rol que corresponda en cada tipo de
  # documento — sea la compañía o el otro lado (el cliente, o el proveedor en
  # FEC). Estos specs arman esa vista a mano con `header:`.
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

    described_class.new(doc_type: doc_type, details: details).call
  end

  describe 'raíz' do
    it 'lleva el tipo de documento, porque el XML que se genere depende de él' do
      expect(build(doc_type: DocType::NC)['DocType']).to eq('03')
    end

    # Es la cédula del proveedor de software ante Hacienda: un dato del
    # producto y no del documento. La vista lo traía hardcodeado antes de que
    # existiera este ajuste; ahora sale de Configuraciones → Generales.
    it 'toma ProveedorSistemas del ajuste GENERAL_PROVIDER_ID y no de la vista' do
      create(:setting, code: 'GENERAL_PROVIDER_ID', value: '3101822733')

      payload = build(header: { 'ProveedorSistemas' => 'lo que traiga la vista' })

      expect(payload['Document']['ProveedorSistemas']).to eq('3101822733')
    end

    it 'queda en nil mientras el ajuste no esté configurado' do
      expect(build['Document']['ProveedorSistemas']).to be_nil
    end

    # Las dos identificaciones salen de la cabecera; tienen que ser las MISMAS
    # que van en el XML: si el cuerpo del POST y el comprobante no coinciden,
    # Hacienda rechaza el envío.
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

  describe 'códigos de actividad' do
    # Los dos salen SIEMPRE de la cabecera: la vista ya resuelve cuál de los
    # dos roles es la compañía y le pone la actividad económica que
    # corresponda al prefijo — esta clase no distingue.
    it 'el del emisor sale de la cabecera' do
      payload = build(header: { 'CodigoActividadEmisor' => '620100' })

      expect(payload['Document']['CodigoActividadEmisor']).to eq('620100')
    end

    it 'el del receptor sale de la cabecera' do
      payload = build(header: { 'CodigoActividadReceptor' => '722003' })

      expect(payload['Document']['CodigoActividadReceptor']).to eq('722003')
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
    # La identidad del emisor sale siempre de la cabecera, con el prefijo fijo
    # `Emsr` — para el caso normal (compañía = emisor) la vista ya la trae
    # resuelta con los datos de la compañía; ver la cabecera de la clase.
    it 'toma la identidad del emisor de la cabecera' do
      payload = build(header: { 'EmsrNombre' => 'Acme Sociedad Anónima', 'EmsrIdeTipo' => '02',
                                'EmsrIdeNumero' => '3101123456', 'EmsrRegistrofiscal8707' => '8707-99' })

      expect(payload['Document']['Emisor']).to include(
        'Nombre' => 'Acme Sociedad Anónima',
        'Identificacion' => { 'Tipo' => '02', 'Numero' => '3101123456' },
        'Registrofiscal8707' => '8707-99'
      )
    end

    it 'toma el nombre comercial del emisor de la cabecera' do
      payload = build(header: { 'EmsrNombreComercial' => 'ACME S.A.' })

      expect(payload['Document']['Emisor']['NombreComercial']).to eq('ACME S.A.')
    end

    # Estos tres SÍ cambian por sucursal: los trae la cabecera desde la UDT
    # `@CL_FEC_SUCURSALES`, no `companies`.
    it 'toma ubicación, teléfono y correo del emisor de la cabecera' do
      payload = build(header: { 'EmsrUbBarrio' => 'Escalante', 'EmsrTlfNumTelefono' => '22334455',
                                'EmsrCorreoElectronico' => 'sucursal@acme.cr' })
      emisor = payload['Document']['Emisor']

      expect(emisor['Ubicacion']).to include('Barrio' => 'Escalante')
      expect(emisor['Telefono']).to include('NumTelefono' => '22334455')
      expect(emisor['CorreoElectronico']).to eq('sucursal@acme.cr')
    end

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

    # Hacienda exige un único correo en `Receptor.CorreoElectronico`; SAP puede
    # traer varios separados por `;` (mismo campo que arma el correo de
    # recepción en `CheckSentDocumentsJob#recipients`) — se manda solo el
    # primero.
    it 'manda solo el primer correo del receptor a Hacienda, aunque la cabecera traiga varios' do
      payload = build(header: { 'RcprCorreoElectronico' => 'cliente@test.com;copia@test.com' })

      expect(payload['Document']['Receptor']['CorreoElectronico']).to eq('cliente@test.com')
    end

    it 'deja el correo del receptor en nil cuando la cabecera no trae ninguno' do
      payload = build(header: {})

      expect(payload['Document']['Receptor']['CorreoElectronico']).to be_nil
    end
  end

  # La factura de compra la emite el proveedor que no puede facturar, y la
  # compañía es el receptor. Poner ahí la cédula de la compañía sería declararle
  # a Hacienda que se compró a sí misma.
  describe 'factura electrónica de compra — el emisor es el proveedor' do
    let(:proveedor) do
      { 'EmsrNombre' => 'Proveedor del Sur S.A.', 'EmsrIdeTipo' => '02',
        'EmsrIdeNumero' => '3101999999', 'EmsrNombreComercial' => 'Prosur',
        'EmsrRegistrofiscal8707' => '8707-11' }
    end

    it 'toma la identidad del emisor de la cabecera y no de la compañía' do
      payload = build(header: proveedor, doc_type: DocType::FEC)

      expect(payload['Document']['Emisor']).to include(
        'Nombre' => 'Proveedor del Sur S.A.',
        'Identificacion' => { 'Tipo' => '02', 'Numero' => '3101999999' },
        'NombreComercial' => 'Prosur',
        'Registrofiscal8707' => '8707-11'
      )
    end

    # Si el cuerpo del POST y el comprobante no coinciden, Hacienda rechaza el
    # envío — así que los dos tienen que invertirse a la vez.
    it 'manda la identificación del proveedor también en el cuerpo del envío' do
      payload = build(header: proveedor, doc_type: DocType::FEC)

      expect(payload['SendDocumentHacienda']['emisor'])
        .to eq('numeroIdentificacion' => '3101999999', 'tipoIdentificacion' => '02')
    end

    # Las señas en el exterior del emisor solo existen en este tipo; en los
    # demás el emisor es la compañía y el esquema ni siquiera las declara.
    it 'mapea las señas en el exterior del emisor' do
      payload = build(header: proveedor.merge('EmsrOtrasSenasExtranjero' => 'Miami, Florida'),
                      doc_type: DocType::FEC)

      expect(payload['Document']['Emisor']['OtrasSenasExtranjero']).to eq('Miami, Florida')
    end

    # En FEC ese código es opcional para el emisor (el obligatorio es el del
    # receptor), pero sigue saliendo de la cabecera igual que en cualquier tipo.
    it 'toma el código de actividad del emisor de la cabecera' do
      payload = build(header: proveedor.merge('CodigoActividadEmisor' => '999999'),
                      doc_type: DocType::FEC)

      expect(payload['Document']['CodigoActividadEmisor']).to eq('999999')
    end

    it 'lo deja en nil si la cabecera no lo trae' do
      payload = build(header: proveedor, doc_type: DocType::FEC)

      expect(payload['Document']['CodigoActividadEmisor']).to be_nil
    end

    # El inscrito ante Hacienda es la compañía, que acá es quien compra: la
    # vista resuelve el bloque `Rcpr*` con los datos de la compañía cuando el
    # tipo es FEC — mismo mecanismo que resuelve `Emsr*` con el proveedor.
    it 'toma la identidad del receptor de la cabecera' do
      payload = build(header: proveedor.merge('RcprNombre' => 'Acme Sociedad Anónima',
                                              'RcprIdeTipo' => '02', 'RcprIdeNumero' => '3101123456',
                                              'RcprNombreComercial' => 'ACME S.A.'),
                      doc_type: DocType::FEC)

      expect(payload['Document']['Receptor']).to include(
        'Nombre' => 'Acme Sociedad Anónima',
        'Identificacion' => { 'Tipo' => '02', 'Numero' => '3101123456' },
        'NombreComercial' => 'ACME S.A.'
      )
    end

    it 'toma el código de actividad del receptor de la cabecera' do
      payload = build(header: proveedor.merge('CodigoActividadReceptor' => '620100'),
                      doc_type: DocType::FEC)

      expect(payload['Document']['CodigoActividadReceptor']).to eq('620100')
    end

    # `companies` no tiene dónde guardarlos y cambian por sucursal de compra.
    it 'deja la ubicación y el correo del receptor donde estaban' do
      payload = build(header: proveedor.merge('RcprUbBarrio' => 'Escalante',
                                              'RcprCorreoElectronico' => 'compras@acme.cr'),
                      doc_type: DocType::FEC)
      receptor = payload['Document']['Receptor']

      expect(receptor['Ubicacion']).to include('Barrio' => 'Escalante')
      expect(receptor['CorreoElectronico']).to eq('compras@acme.cr')
    end

    # Los dos lados del cuerpo se invierten a la vez: si uno solo se diera
    # vuelta, el POST y el comprobante dejarían de coincidir.
    it 'manda la compañía como receptor en el cuerpo del envío' do
      payload = build(header: proveedor.merge('RcprIdeNumero' => '3101123456', 'RcprIdeTipo' => '02'),
                      doc_type: DocType::FEC)

      expect(payload['SendDocumentHacienda']['receptor'])
        .to eq('numeroIdentificacion' => '3101123456', 'tipoIdentificacion' => '02')
    end

    # Solo el emisor lo declara, también en el esquema de la factura de compra:
    # el registro de la compañía no tiene dónde ir cuando ella es el receptor.
    it 'no le pasa al receptor el registro 8707 de la compañía' do
      payload = build(header: proveedor, doc_type: DocType::FEC)

      expect(payload['Document']['Receptor']).not_to have_key('Registrofiscal8707')
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

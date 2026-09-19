# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailReception::ReceivedDocument do
  def root_for(xml)
    doc = Nokogiri::XML(xml) { |cfg| cfg.strict }
    doc.remove_namespaces!
    doc.root
  end

  let(:xml) do
    <<~XML
      <FacturaElectronica xmlns="https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/facturaElectronica">
        <Clave>50601012500310182300100100001010000000001100000001</Clave>
        <ProveedorSistemas>ACME-ERP</ProveedorSistemas>
        <NumeroConsecutivo>00100001010000000001</NumeroConsecutivo>
        <FechaEmision>2026-09-19T10:00:00-06:00</FechaEmision>
        <Emisor>
          <Nombre>Proveedor SA</Nombre>
          <Identificacion><Tipo>02</Tipo><Numero>3101822733</Numero></Identificacion>
          <Registrofiscal8707>1</Registrofiscal8707>
          <NombreComercial>Proveedor</NombreComercial>
          <Ubicacion><Provincia>1</Provincia><Canton>01</Canton><Distrito>01</Distrito>
            <Barrio>Centro</Barrio><OtrasSenas>100m norte</OtrasSenas></Ubicacion>
          <Telefono><CodigoPais>506</CodigoPais><NumTelefono>22223333</NumTelefono></Telefono>
          <CorreoElectronico>facturas@proveedor.cr</CorreoElectronico>
        </Emisor>
        <Receptor>
          <Nombre>ACME</Nombre>
          <Identificacion><Tipo>02</Tipo><Numero>3101999999</Numero></Identificacion>
          <CorreoElectronico>compras@acme.cr</CorreoElectronico>
        </Receptor>
        <CondicionVenta>01</CondicionVenta>
        <PlazoCredito>0</PlazoCredito>
        <DetalleServicio>
          <LineaDetalle>
            <NumeroLinea>1</NumeroLinea>
            <CodigoCABYS>8399000000000</CodigoCABYS>
            <Cantidad>2</Cantidad>
            <UnidadMedida>Unid</UnidadMedida>
            <Detalle>Servicio de prueba</Detalle>
            <PrecioUnitario>1000</PrecioUnitario>
            <MontoTotal>2000</MontoTotal>
            <SubTotal>2000</SubTotal>
            <BaseImponible>2000</BaseImponible>
            <Impuesto>
              <Codigo>01</Codigo>
              <CodigoTarifaIVA>08</CodigoTarifaIVA>
              <Tarifa>13</Tarifa>
              <Monto>260</Monto>
              <Exoneracion>
                <TipoDocumentoEX1>03</TipoDocumentoEX1>
                <NumeroDocumento>EX-1</NumeroDocumento>
                <Articulo>9</Articulo>
                <Inciso>2</Inciso>
                <NombreInstitucion>01</NombreInstitucion>
                <FechaEmisionEX>2026-01-01T00:00:00-06:00</FechaEmisionEX>
                <TarifaExonerada>0</TarifaExonerada>
                <MontoExoneracion>0</MontoExoneracion>
              </Exoneracion>
            </Impuesto>
            <ImpuestoNeto>260</ImpuestoNeto>
            <MontoTotalLinea>2260</MontoTotalLinea>
            <DetalleSurtido>
              <LineaDetalleSurtido>
                <CodigoCABYS>1112223330000</CodigoCABYS>
                <Cantidad>1</Cantidad>
                <UnidadMedida>Unid</UnidadMedida>
                <Detalle>Ítem surtido</Detalle>
                <PrecioUnitario>500</PrecioUnitario>
                <MontoTotal>500</MontoTotal>
                <SubTotal>500</SubTotal>
              </LineaDetalleSurtido>
            </DetalleSurtido>
          </LineaDetalle>
        </DetalleServicio>
        <OtrosCargos>
          <TipoDocumentoOC>04</TipoDocumentoOC>
          <NombreTercero>Transportista</NombreTercero>
          <Detalle>Flete</Detalle>
          <MontoCargo>50</MontoCargo>
        </OtrosCargos>
        <ResumenFactura>
          <CodigoTipoMoneda><CodigoMoneda>CRC</CodigoMoneda><TipoCambio>1</TipoCambio></CodigoTipoMoneda>
          <TotalServGravados>2000</TotalServGravados>
          <TotalGravado>2000</TotalGravado>
          <TotalVenta>2000</TotalVenta>
          <TotalDescuentos>0</TotalDescuentos>
          <TotalVentaNeta>2000</TotalVentaNeta>
          <TotalImpuesto>260</TotalImpuesto>
          <TotalOtrosCargos>50</TotalOtrosCargos>
          <MedioPago><TipoMedioPago>02</TipoMedioPago><TotalMedioPago>2310</TotalMedioPago></MedioPago>
          <TotalComprobante>2310</TotalComprobante>
        </ResumenFactura>
        <InformacionReferencia>
          <TipoDocIR>08</TipoDocIR>
          <Numero>001</Numero>
          <Codigo>01</Codigo>
          <Razon>Referencia de prueba</Razon>
        </InformacionReferencia>
        <Otros>
          <OtroTexto codigo="X1">Nota interna</OtroTexto>
        </Otros>
      </FacturaElectronica>
    XML
  end

  subject(:parsed) { described_class.new(root_for(xml), doc_type: DocType::FE) }

  describe '#header' do
    it 'extrae identificación, emisor, receptor y totales del resumen' do
      header = parsed.header

      expect(header['Clave']).to eq('50601012500310182300100100001010000000001100000001')
      expect(header['DocType']).to eq(DocType::FE)
      expect(header['ProveedorSistemas']).to eq('ACME-ERP')
      expect(header['EmsrIdeNumero']).to eq('3101822733')
      expect(header['EmsrRegistrofiscal8707']).to eq('1')
      expect(header['EmsrTlfCodigoPais']).to eq(506)
      expect(header['RcprIdeNumero']).to eq('3101999999')
      expect(header['RcprUbProvincia']).to be_nil # el Receptor de este XML no trae Ubicacion
      expect(header['CodigoMoneda']).to eq('CRC')
      expect(header['TotalComprobante']).to eq(2310.to_d)
      expect(header['TotalFactura']).to eq(2310.to_d)
      expect(header['MontoTotalImpuesto']).to eq(260.to_d)
    end

    it 'copia la PRIMERA InformacionReferencia en los campos planos de cabecera' do
      header = parsed.header

      expect(header['InfRefTipoDoc']).to eq('08')
      expect(header['InfRefNumero']).to eq('001')
      expect(header['InfRefRazon']).to eq('Referencia de prueba')
    end
  end

  describe '#lines' do
    it 'extrae la línea con su impuesto, exoneración y surtido anidado' do
      line = parsed.lines.first

      expect(line['NumeroLinea']).to eq(1)
      expect(line['Codigo']).to eq('8399000000000')
      expect(line['Cantidad']).to eq(2.to_d)
      expect(line['MontoTotalLinea']).to eq(2260.to_d)
      expect(line['ImpMonto']).to eq(260.to_d)
      expect(line['ETipoDocumento']).to eq('03')
      expect(line['ENumeroDocumento']).to eq('EX-1')
      expect(line['EArticulo']).to eq(9)
      expect(line['EInciso']).to eq(2)

      surtido = line['surtido']
      expect(surtido.size).to eq(1)
      expect(surtido.first['CodigoCABYSSurtido']).to eq('1112223330000')
      expect(surtido.first['MontoTotalSurtido']).to eq(500.to_d)
    end

    it 'una línea sin DetalleSurtido devuelve un array vacío' do
      xml_sin_surtido = xml.sub(%r{<DetalleSurtido>.*</DetalleSurtido>}m, '')
      line = described_class.new(root_for(xml_sin_surtido), doc_type: DocType::FE).lines.first

      expect(line['surtido']).to eq([])
    end
  end

  describe '#payments' do
    it 'extrae los medios de pago del ResumenFactura' do
      expect(parsed.payments).to eq([
                                      { 'TipoMedioPago' => '02', 'MedioPagoOtros' => nil,
                                        'TotalMedioPago' => 2310.to_d }
                                    ])
    end
  end

  describe '#other_charges' do
    it 'extrae los OtrosCargos sueltos del nivel raíz' do
      charge = parsed.other_charges.first

      expect(charge['TipoDocumento']).to eq('04')
      expect(charge['NombreTercero']).to eq('Transportista')
      expect(charge['MontoCargo']).to eq(50.to_d)
    end
  end

  describe '#others' do
    it 'extrae Codigo del atributo y Valor del texto de cada OtroTexto' do
      other = parsed.others.first

      expect(other['Codigo']).to eq('X1')
      expect(other['TipoDocumento']).to eq(DocType::FE)
      expect(other['Valor']).to eq('Nota interna')
    end
  end

  describe '#references' do
    it 'extrae la lista completa de InformacionReferencia' do
      expect(parsed.references.size).to eq(1)
      expect(parsed.references.first['InfRefCodigo']).to eq('01')
    end
  end

  context 'cuando el documento no trae ningún bloque opcional' do
    let(:minimal_xml) do
      <<~XML
        <NotaCreditoElectronica xmlns="https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/notaCreditoElectronica">
          <Clave>50601012500310182300100300001010000000001100000001</Clave>
          <Emisor>
            <Nombre>Proveedor SA</Nombre>
            <Identificacion><Tipo>02</Tipo><Numero>3101822733</Numero></Identificacion>
          </Emisor>
        </NotaCreditoElectronica>
      XML
    end

    it 'no revienta y devuelve nil/[] en lo que falta' do
      doc = described_class.new(root_for(minimal_xml), doc_type: DocType::NC)

      expect(doc.header['RcprIdeNumero']).to be_nil
      expect(doc.header['TotalComprobante']).to be_nil
      expect(doc.lines).to eq([])
      expect(doc.payments).to eq([])
      expect(doc.other_charges).to eq([])
      expect(doc.others).to eq([])
      expect(doc.references).to eq([])
    end
  end
end

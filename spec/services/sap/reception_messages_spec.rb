# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::ReceptionMessages do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  def upsert_resource(code, resource)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: resource, query_params: nil, page_size: 0, is_active: true)
    end
  end

  before do
    upsert_resource('createReceptionMessage', 'U_CL_FEC_RECEPTORMSG')
    upsert_resource('createReceptionMessageLine', 'U_CL_FEC_RECEPTORLIN')
    upsert_resource('createReceptionMessageLineDetail', 'U_CL_FEC_RECEPTORSURT')
    upsert_resource('createReceptionMessagePayment', 'U_CL_FEC_RECEPTORPAGO')
    upsert_resource('createReceptionMessageOtherCharge', 'U_CL_FEC_RECEPTORCARG')
    upsert_resource('createReceptionMessageOther', 'U_CL_FEC_RECEPTOROTRO')
    upsert_resource('createReceptionMessageReference', 'U_CL_FEC_RECEPTORREF')

    allow(client).to receive(:post).with('U_CL_FEC_RECEPTORMSG', any_args).and_return({ 'Code' => 10 })
    allow(client).to receive(:post).with('U_CL_FEC_RECEPTORLIN', any_args).and_return({ 'Code' => 20 })
    allow(client).to receive(:post).with('U_CL_FEC_RECEPTORSURT', any_args).and_return({ 'Code' => 30 })
    allow(client).to receive(:post).with('U_CL_FEC_RECEPTORPAGO', any_args).and_return({ 'Code' => 40 })
    allow(client).to receive(:post).with('U_CL_FEC_RECEPTORCARG', any_args).and_return({ 'Code' => 50 })
    allow(client).to receive(:post).with('U_CL_FEC_RECEPTOROTRO', any_args).and_return({ 'Code' => 60 })
    allow(client).to receive(:post).with('U_CL_FEC_RECEPTORREF', any_args).and_return({ 'Code' => 70 })
  end

  let(:company) do
    build_stubbed(
      :company, economic_activity_code: '620102',
                default_recept_message: nil, default_recept_details: nil,
                default_recept_tax_factor: nil, default_recept_tax_condition: nil
    )
  end

  def root_for(xml)
    doc = Nokogiri::XML(xml) { |cfg| cfg.strict }
    doc.remove_namespaces!
    doc.root
  end

  let(:xml) do
    <<~XML
      <FacturaElectronica xmlns="https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/facturaElectronica">
        <Clave>50601012500310182300100100001010000000001100000001</Clave>
        <Emisor>
          <Nombre>Proveedor SA</Nombre>
          <Identificacion><Tipo>02</Tipo><Numero>3101822733</Numero></Identificacion>
        </Emisor>
        <Receptor>
          <Nombre>ACME</Nombre>
          <Identificacion><Tipo>02</Tipo><Numero>3101999999</Numero></Identificacion>
        </Receptor>
        <DetalleServicio>
          <LineaDetalle>
            <NumeroLinea>1</NumeroLinea>
            <CodigoCABYS>8399000000000</CodigoCABYS>
            <Cantidad>1</Cantidad>
            <UnidadMedida>Unid</UnidadMedida>
            <Detalle>Servicio de prueba</Detalle>
            <PrecioUnitario>1000</PrecioUnitario>
            <MontoTotal>1000</MontoTotal>
            <SubTotal>1000</SubTotal>
            <MontoTotalLinea>1130</MontoTotalLinea>
            <DetalleSurtido>
              <LineaDetalleSurtido>
                <CodigoCABYS>1112223330000</CodigoCABYS>
                <Detalle>Ítem surtido</Detalle>
              </LineaDetalleSurtido>
            </DetalleSurtido>
          </LineaDetalle>
        </DetalleServicio>
        <OtrosCargos>
          <NombreTercero>Transportista</NombreTercero>
          <MontoCargo>50</MontoCargo>
        </OtrosCargos>
        <ResumenFactura>
          <CodigoTipoMoneda><CodigoMoneda>CRC</CodigoMoneda><TipoCambio>1</TipoCambio></CodigoTipoMoneda>
          <TotalVenta>1000</TotalVenta>
          <TotalImpuesto>130</TotalImpuesto>
          <TotalComprobante>1130</TotalComprobante>
          <MedioPago><TipoMedioPago>02</TipoMedioPago><TotalMedioPago>1130</TotalMedioPago></MedioPago>
        </ResumenFactura>
        <InformacionReferencia>
          <TipoDocIR>08</TipoDocIR>
          <Numero>001</Numero>
        </InformacionReferencia>
        <Otros>
          <OtroTexto codigo="X1">Nota interna</OtroTexto>
        </Otros>
      </FacturaElectronica>
    XML
  end

  let(:document) { MailReception::ReceivedDocument.new(root_for(xml), doc_type: DocType::FE) }

  subject(:service) { described_class.new(client: client) }

  it 'resuelve Mensaje/DetalleMensaje/CondicionImpuesto por tag y crea la cabecera con Status Pending' do
    body = '[Status:ACEPTADO][DetalleMensaje:Recibido conforme][CondicionImpuesto:01]'

    service.create_from_document(document: document, company: company, email_body: body,
                                  mailbox_email: 'facturas@acme.cr')

    expect(client).to have_received(:post).with('U_CL_FEC_RECEPTORMSG', body: hash_including(
                                                   'U_Clave' => '50601012500310182300100100001010000000001100000001',
                                                   'U_Mensaje' => DocType::AT,
                                                   'U_DetalleMensaje' => 'Recibido conforme',
                                                   'U_CondicionImpuesto' => '01',
                                                   'U_MontoTotalImpuestoAcreditar' => 130.to_d,
                                                   'U_Status' => described_class::STATUS_PENDING,
                                                   'U_TaxesTag' => 'Y',
                                                   'U_BandejaReceptor' => 'facturas@acme.cr'
                                                 ))
  end

  it 'sin tags ni defaults de compañía, Mensaje queda sin resolver (no inventa un valor)' do
    service.create_from_document(document: document, company: company, email_body: 'sin tags',
                                  mailbox_email: 'facturas@acme.cr')

    expect(client).to have_received(:post).with('U_CL_FEC_RECEPTORMSG', body: hash_including('U_Mensaje' => nil))
  end

  it 'encadena el Code de la cabecera a la línea, y el de la línea a su surtido' do
    service.create_from_document(document: document, company: company, email_body: '',
                                  mailbox_email: 'facturas@acme.cr')

    expect(client).to have_received(:post).with(
      'U_CL_FEC_RECEPTORLIN', body: hash_including('U_MensajeReceptorCode' => 10, 'U_Codigo' => '8399000000000')
    )
    expect(client).to have_received(:post).with(
      'U_CL_FEC_RECEPTORSURT',
      body: hash_including('U_MensajeReceptorLineaCode' => 20, 'U_CodigoCABYSSurtido' => '1112223330000')
    )
  end

  it 'crea pagos, otros cargos, otros y referencias con el Code de la cabecera' do
    service.create_from_document(document: document, company: company, email_body: '',
                                  mailbox_email: 'facturas@acme.cr')

    expect(client).to have_received(:post).with(
      'U_CL_FEC_RECEPTORPAGO', body: hash_including('U_MensajeReceptorCode' => 10, 'U_TipoMedioPago' => '02')
    )
    expect(client).to have_received(:post).with(
      'U_CL_FEC_RECEPTORCARG', body: hash_including('U_MensajeReceptorCode' => 10, 'U_NombreTercero' => 'Transportista')
    )
    expect(client).to have_received(:post).with(
      'U_CL_FEC_RECEPTOROTRO', body: hash_including('U_MensajeReceptorCode' => 10, 'U_Codigo' => 'X1')
    )
    expect(client).to have_received(:post).with(
      'U_CL_FEC_RECEPTORREF', body: hash_including('U_MensajeReceptorCode' => 10, 'U_InfRefNumero' => '001')
    )
  end

  it 'devuelve el Code de la cabecera' do
    result = service.create_from_document(document: document, company: company, email_body: '',
                                           mailbox_email: 'facturas@acme.cr')

    expect(result).to eq(10)
  end
end

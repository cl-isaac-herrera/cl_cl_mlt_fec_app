# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailReception::IncomingDocument do
  def xml_for(clave:, receptor_id: '3101822733')
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <FacturaElectronica xmlns="https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/facturaElectronica">
        <Clave>#{clave}</Clave>
        <Receptor>
          <Identificacion>
            <Tipo>02</Tipo>
            <Numero>#{receptor_id}</Numero>
          </Identificacion>
        </Receptor>
      </FacturaElectronica>
    XML
  end

  def eml_with(attachments)
    mail = Mail.new
    mail.from = 'proveedor@ejemplo.com'
    mail.to = 'facturas@acme.com'
    mail.subject = 'Factura electrónica'
    mail.body = 'Adjunto la factura.'
    attachments.each { |name, content, type| mail.attachments[name] = { mime_type: type, content: content } }
    mail.to_s
  end

  it 'extrae la clave y la identificación del receptor de un XML adjunto' do
    xml = xml_for(clave: '50601012300031082733200XXXXXXXXX1200000001')
    raw = eml_with([['factura.xml', xml, 'application/xml']])

    attachments = described_class.attachments_from(raw)

    expect(attachments.size).to eq(1)
    expect(attachments.first.clave).to eq('50601012300031082733200XXXXXXXXX1200000001')
    expect(attachments.first.receptor_id_number).to eq('3101822733')
  end

  it 'ignora adjuntos que no son XML de Hacienda (un PDF, por ejemplo)' do
    raw = eml_with([['factura.pdf', '%PDF-1.4 no es xml', 'application/pdf']])

    expect(described_class.attachments_from(raw)).to be_empty
  end

  it 'ignora un XML sin Clave o sin identificación del receptor' do
    xml = '<Otro><Algo>x</Algo></Otro>'
    raw = eml_with([['algo.xml', xml, 'application/xml']])

    expect(described_class.attachments_from(raw)).to be_empty
  end

  it 'ignora un XML malformado sin reventar' do
    raw = eml_with([['roto.xml', '<Factura><Clave>123</Clave', 'application/xml']])

    expect(described_class.attachments_from(raw)).to be_empty
  end

  it 'extrae el XML comprimido dentro de un adjunto .zip' do
    xml = xml_for(clave: '50601012300031082733200XXXXXXXXX1200000002')
    zip_bytes = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry('factura.xml')
      zip.write(xml)
    end.string

    raw = eml_with([['documentos.zip', zip_bytes, 'application/zip']])

    attachments = described_class.attachments_from(raw)

    expect(attachments.size).to eq(1)
    expect(attachments.first.clave).to eq('50601012300031082733200XXXXXXXXX1200000002')
  end

  it 'expone el doc_type y el nodo raíz del XML para reutilizarlos sin reparsear' do
    xml = xml_for(clave: '50601012300031082733200XXXXXXXXX1200000003')
    raw = eml_with([['factura.xml', xml, 'application/xml']])

    attachment = described_class.attachments_from(raw).first

    expect(attachment.doc_type).to eq(DocType::FE)
    expect(attachment.root.name).to eq('FacturaElectronica')
  end

  it 'ignora un tipo de documento que este flujo no recepciona (tiquete, factura de compra, etc.)' do
    xml = <<~XML
      <TiqueteElectronico xmlns="https://cdn.comprobanteselectronicos.go.cr/xml-schemas/v4.4/tiqueteElectronico">
        <Clave>50601012300031082733200XXXXXXXXX1200000004</Clave>
        <Receptor><Identificacion><Tipo>02</Tipo><Numero>3101822733</Numero></Identificacion></Receptor>
      </TiqueteElectronico>
    XML
    raw = eml_with([['tiquete.xml', xml, 'application/xml']])

    expect(described_class.attachments_from(raw)).to be_empty
  end

  it 'ignora la respuesta de Hacienda (MensajeHacienda) cuando viaja junto al comprobante' do
    xml = '<MensajeHacienda><Clave>50601012300031082733200XXXXXXXXX1200000005</Clave></MensajeHacienda>'
    raw = eml_with([['respuesta.xml', xml, 'application/xml']])

    expect(described_class.attachments_from(raw)).to be_empty
  end

  it 'encuentra un documento por cada Clave distinta cuando hay varios adjuntos válidos' do
    factura = xml_for(clave: '111')
    nota_credito = xml_for(clave: '222', receptor_id: '3101822733')
    raw = eml_with([
                     ['factura.xml', factura, 'application/xml'],
                     ['nota_credito.xml', nota_credito, 'application/xml']
                   ])

    claves = described_class.attachments_from(raw).map(&:clave)

    expect(claves).to contain_exactly('111', '222')
  end
end

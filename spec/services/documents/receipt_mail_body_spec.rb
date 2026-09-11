# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::ReceiptMailBody do
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:status)  { Sap::MailDocumentInfo::ACCEPTED_STATUS }
  let(:info) do
    Documents::Row.new(
      'U_CL_FEC_NumConsecutivo' => '00100001010000000001', 'CardName' => 'Distribuidora El Sol S.A.',
      'U_CL_FEC_Clave' => '50601012600310182273300100001010000000001100000001',
      'U_CL_FEC_FechaEmision' => '2026-09-06T09:06:00Z', 'DocTotal' => '1284350.75',
      'DocCurrency' => 'CRC', 'U_CL_FEC_Status' => status
    )
  end

  subject(:rendered) { described_class.new(company: company, doc_type: DocType::FE, info: info).call }

  before { allow_any_instance_of(Attachments::LogoStore).to receive(:readable_path).and_return(nil) }

  describe 'asunto' do
    it 'dice el desenlace y el consecutivo' do
      expect(rendered.subject).to eq('Comprobante electrónico aceptado por Hacienda · 00100001010000000001')
    end

    context 'cuando Hacienda lo rechazó' do
      let(:status) { 5 }

      it 'lo dice en el asunto' do
        expect(rendered.subject).to start_with('Comprobante electrónico rechazado por Hacienda')
      end
    end

    it 'omite el separador si el comprobante no tiene consecutivo' do
      allow(info).to receive(:string).and_call_original
      allow(info).to receive(:string).with('U_CL_FEC_NumConsecutivo').and_return(nil)

      expect(rendered.subject).to eq('Comprobante electrónico aceptado por Hacienda')
    end
  end

  describe 'HTML' do
    it 'trae los datos del comprobante' do
      expect(rendered.html).to include('Distribuidora El Sol S.A.', '00100001010000000001',
                                       '50601012600310182273300100001010000000001100000001',
                                       'Factura electrónica', 'ACME S.A.')
    end

    it 'pinta el estado con el color de aceptado' do
      expect(rendered.html).to include('ACEPTADO POR HACIENDA', '#e8f5ee')
    end

    context 'cuando Hacienda lo rechazó' do
      let(:status) { 5 }

      it 'pinta el estado con el color de rechazado' do
        expect(rendered.html).to include('RECHAZADO POR HACIENDA', '#fdecea')
        expect(rendered.html).not_to include('ACEPTADO POR HACIENDA')
      end
    end

    # Es un correo: nada de estilos externos ni de imágenes por URL, que los
    # clientes bloquean por defecto.
    it 'no referencia hojas de estilo ni imágenes remotas' do
      expect(rendered.html).not_to include('<link')
      expect(rendered.html).not_to match(/<img[^>]+src="http/m)
    end

    it 'escapa lo que venga en los datos' do
      company.update!(name: 'ACME <script>alert(1)</script>')

      expect(rendered.html).to include('&lt;script&gt;')
      expect(rendered.html).not_to include('<script>alert(1)</script>')
    end
  end

  describe 'fecha de emisión' do
    it 'la reescribe al formato yyyy-MM-dd HH:mm:ss' do
      expect(rendered.text).to include('2026-09-06 09:06:00')
    end

    # El sufijo `Z` del UDF no significa que el dato esté en UTC: lo escribe SAP
    # con la hora local del documento. Convertirlo correría la hora seis horas —
    # y el día entero en un comprobante de la madrugada.
    it 'no convierte de zona horaria' do
      allow(info).to receive(:string).and_call_original
      allow(info).to receive(:string).with('U_CL_FEC_FechaEmision').and_return('2026-09-06T01:30:00Z')

      expect(rendered.text).to include('2026-09-06 01:30:00')
    end

    it 'muestra el valor tal cual si no tiene la forma esperada' do
      allow(info).to receive(:string).and_call_original
      allow(info).to receive(:string).with('U_CL_FEC_FechaEmision').and_return('el martes')

      expect(rendered.text).to include('el martes')
    end
  end

  describe 'texto plano' do
    it 'trae los mismos datos que el HTML' do
      expect(rendered.text).to include('Distribuidora El Sol S.A.', '00100001010000000001', 'Factura electrónica',
                                       '50601012600310182273300100001010000000001100000001')
    end

    it 'no trae etiquetas HTML' do
      expect(rendered.text).not_to match(/<[a-z]/i)
    end
  end

  describe 'imágenes incrustadas' do
    it 'declara el logo del pie, que viaja en el repositorio' do
      expect(rendered.inline_images).to eq('clavisco-logo' => described_class::FOOTER_LOGO_PATH.to_s)
      expect(described_class::FOOTER_LOGO_PATH).to exist
    end

    context 'con un logo de compañía legible' do
      let(:logo_path) { Rails.root.join('tmp/receipt_mail_body_spec_logo.png') }

      before do
        # 1200×300: más ancho que el máximo, para verificar el escalado.
        logo_path.binwrite([137, 80, 78, 71, 13, 10, 26, 10].pack('C*') +
                           [13].pack('N') + 'IHDR' + [1200].pack('N') + [300].pack('N') + ("\x00" * 5))
        allow_any_instance_of(Attachments::LogoStore).to receive(:readable_path).and_return(logo_path.to_s)
      end

      after { logo_path.delete if logo_path.exist? }

      it 'lo declara y lo referencia desde el HTML' do
        expect(rendered.inline_images).to include('company-logo' => logo_path.to_s)
        expect(rendered.html).to include('src="cid:company-logo"')
      end

      # Outlook ignora `max-width`/`max-height`: sin atributos, un logo de 1200
      # px de ancho se pinta a tamaño completo y rompe la tarjeta.
      it 'emite width y height escalados a la caja, conservando la proporción' do
        expect(rendered.html).to include('width="192" height="48"')
      end
    end

    # Quien escribe el `<img src="cid:x">` es quien declara `x`: si no hay logo,
    # no puede quedar un `cid:` colgando sin adjunto que lo resuelva — que es
    # exactamente lo que pintaba el ícono de imagen rota.
    it 'no referencia el logo de la compañía si no hay archivo legible' do
      expect(rendered.inline_images).not_to include('company-logo')
      expect(rendered.html).not_to include('cid:company-logo')
      expect(rendered.html).to include('ACME S.A.')
    end
  end

  describe 'datos ausentes' do
    let(:info) { Documents::Row.new('U_CL_FEC_Status' => status, 'CardName' => 'Solo el receptor') }

    it 'omite las filas sin valor en vez de dejarlas vacías' do
      expect(rendered.html).to include('Solo el receptor')
      expect(rendered.html).not_to include('Consecutivo', 'Clave numérica', 'Monto del comprobante')
    end

    it 'no promete adjuntos que no existen' do
      expect(rendered.text).not_to include('Se adjuntan')
    end
  end
end

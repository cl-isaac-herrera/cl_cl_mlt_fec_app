# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Images::Dimensions do
  let(:tmp) { Rails.root.join('tmp') }

  def write(name, bytes)
    path = tmp.join("dimensions_spec_#{name}")
    path.binwrite(bytes)
    path
  end

  after { Dir[tmp.join('dimensions_spec_*')].each { |f| File.delete(f) } }

  describe 'PNG' do
    it 'lee las medidas del logo del pie que viaja en el repositorio' do
      expect(described_class.of(Rails.root.join('app/assets/images/email-footer-logo.png'))).to eq([1080, 108])
    end

    it 'lee ancho y alto del chunk IHDR' do
      png = [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') +
            [13].pack('N') + 'IHDR' + [640].pack('N') + [480].pack('N') + ("\x00" * 5)

      expect(described_class.of(write('ok.png', png))).to eq([640, 480])
    end

    it 'devuelve nil si el archivo está truncado antes del IHDR' do
      png = [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + [13].pack('N')

      expect(described_class.of(write('trunc.png', png))).to be_nil
    end
  end

  describe 'JPEG' do
    # SOI, APP0, un segmento intermedio y el SOF0 — que es el que declara las
    # medidas, y viene con el ALTO primero.
    def jpeg(width, height, marker: 0xC0)
      [0xFF, 0xD8].pack('C*') +
        [0xFF, 0xE0].pack('C*') + [16].pack('n') + ('J' * 14) +
        [0xFF, 0xFE].pack('C*') + [6].pack('n') + ('c' * 4) +
        [0xFF, marker].pack('C*') + [17].pack('n') + [8].pack('C') +
        [height].pack('n') + [width].pack('n') + ('x' * 10)
    end

    it 'recorre los segmentos hasta el SOF y devuelve ancho y alto' do
      expect(described_class.of(write('ok.jpg', jpeg(640, 300)))).to eq([640, 300])
    end

    it 'también lee los SOF progresivos' do
      expect(described_class.of(write('prog.jpg', jpeg(800, 600, marker: 0xC2)))).to eq([800, 600])
    end

    # 0xC4 comparte el rango de los SOF pero es la tabla Huffman: tomarlo como
    # SOF devolvería dos bytes cualesquiera de su carga como si fueran medidas.
    it 'no confunde la tabla Huffman (0xC4) con un SOF' do
      expect(described_class.of(write('huff.jpg', jpeg(640, 300, marker: 0xC4)))).to be_nil
    end
  end

  describe 'lo que no se puede medir' do
    it 'devuelve nil con un archivo que no es imagen' do
      expect(described_class.of(write('basura.bin', 'no soy una imagen'))).to be_nil
    end

    it 'devuelve nil con un archivo vacío' do
      expect(described_class.of(write('vacio.png', ''))).to be_nil
    end

    # Está en la ruta de envío de un correo: no poder medir un logo no puede ser
    # motivo para que el comprobante no salga.
    it 'devuelve nil en vez de levantar si el archivo no existe' do
      expect(described_class.of(tmp.join('dimensions_spec_no_existe.png'))).to be_nil
    end
  end
end

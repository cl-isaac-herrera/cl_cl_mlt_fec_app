# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::Row do
  # La razón de ser de esta clase: el mismo catálogo de consultas sirve a
  # instalaciones sobre SQL Server y sobre HANA, y HANA devuelve los
  # identificadores en mayúsculas. Sin esto, `row['DocEntry']` funciona en una
  # instalación y devuelve nil en silencio en la otra.
  describe 'tolerancia a la caja' do
    it 'encuentra la columna aunque HANA la haya devuelto en mayúsculas' do
      row = described_class.new('DOCENTRY' => 25, 'CLAVE' => '506…')

      expect(row.integer('DocEntry')).to eq(25)
      expect(row.string('Clave')).to eq('506…')
    end

    it 'distingue una columna ausente de una que vino en nil' do
      row = described_class.new('Detalle' => nil)

      expect(row.key?('Detalle')).to be(true)
      expect(row.key?('NoExiste')).to be(false)
    end
  end

  describe '#string' do
    it 'recorta el relleno de espacios del char(n)' do
      expect(described_class.new('D' => '  producto  ').string('D')).to eq('producto')
    end

    # Una cadena vacía en el XML es un elemento vacío, no un campo ausente.
    it 'devuelve nil cuando solo había espacios' do
      expect(described_class.new('D' => '   ').string('D')).to be_nil
    end
  end

  describe '#integer' do
    # `'abc'.to_i` es 0, y ese cero se leería como un dato válido.
    it 'devuelve nil en vez de 0 cuando el texto no es un número' do
      expect(described_class.new('N' => 'abc').integer('N')).to be_nil
    end

    it 'convierte el texto numérico' do
      expect(described_class.new('N' => '12').integer('N')).to eq(12)
    end
  end

  describe '#decimal' do
    # BigDecimal y no Float: los montos se suman para el desglose de impuestos y
    # Hacienda compara contra sus propios totales. En coma flotante,
    # 0.1 + 0.2 != 0.3 y el comprobante se rechaza por diferencia de centavos.
    it 'devuelve BigDecimal, no Float' do
      expect(described_class.new('M' => '13.50').decimal('M')).to be_a(BigDecimal)
    end

    it 'suma sin el error de la coma flotante' do
      a = described_class.new('M' => '0.1').decimal('M')
      b = described_class.new('M' => '0.2').decimal('M')

      expect(a + b).to eq(BigDecimal('0.3'))
    end

    it 'devuelve nil cuando el valor no es numérico' do
      expect(described_class.new('M' => 'x').decimal('M')).to be_nil
      expect(described_class.new('M' => nil).decimal('M')).to be_nil
    end
  end

  describe 'construcción' do
    it 'acepta nil como fila vacía' do
      expect(described_class.new(nil)).to be_empty
    end

    it 'acepta otra Row sin anidarla' do
      original = described_class.new('A' => 1)

      expect(described_class.new(original).integer('A')).to eq(1)
    end
  end
end

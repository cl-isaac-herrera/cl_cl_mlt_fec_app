# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TaxCondition do
  describe '.apply' do
    it '01 Genera Crédito IVA — acredita el 100% del impuesto, sin usar TaxFactor' do
      result = described_class.apply(condition: '01', tax_amount: 1000)

      expect(result.tax_credit).to eq(1000.to_d)
      expect(result.applicable_expense).to be_nil
    end

    it '02 Genera Crédito parcial del IVA — no calcula nada (laguna real del legacy)' do
      result = described_class.apply(condition: '02', tax_amount: 1000, tax_factor: 50)

      expect(result.tax_credit).to be_nil
      expect(result.applicable_expense).to be_nil
    end

    it '03 Bienes de Capital — acredita tax_amount * (tax_factor / 100)' do
      result = described_class.apply(condition: '03', tax_amount: 1000, tax_factor: 40)

      expect(result.tax_credit).to eq(400.to_d)
      expect(result.applicable_expense).to be_nil
    end

    it '04 Gasto corriente no genera crédito — todo el impuesto es gasto aplicable' do
      result = described_class.apply(condition: '04', tax_amount: 1000)

      expect(result.tax_credit).to be_nil
      expect(result.applicable_expense).to eq(1000.to_d)
    end

    it '05 Proporcionalidad — reparte entre crédito y gasto según TaxFactor' do
      result = described_class.apply(condition: '05', tax_amount: 1000, tax_factor: 40)

      expect(result.tax_credit).to eq(400.to_d)
      expect(result.applicable_expense).to eq(600.to_d)
    end

    it 'trunca a 5 decimales sin redondear (mismo comportamiento que el legacy)' do
      # 100 * (33.333 / 100) = 33.3330 exacto — se prueba con un factor que sí
      # produce cola decimal más allá de 5 lugares.
      result = described_class.apply(condition: '03', tax_amount: 10, tax_factor: 33.333333)

      expect(result.tax_credit).to eq('3.33333'.to_d)
    end

    it 'un valor fuera de catálogo no calcula nada' do
      result = described_class.apply(condition: '99', tax_amount: 1000)

      expect(result.tax_credit).to be_nil
      expect(result.applicable_expense).to be_nil
    end
  end

  describe '.requires_tax_factor?' do
    it { expect(described_class.requires_tax_factor?('03')).to be(true) }
    it { expect(described_class.requires_tax_factor?('05')).to be(true) }
    it { expect(described_class.requires_tax_factor?('01')).to be(false) }
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::CurrencyValidator do
  def errors_for(document) = described_class.new(document).call
  def fields_for(document) = errors_for(document).map(&:field)

  it 'no reporta nada para colones con tipo de cambio 1' do
    expect(errors_for(valid_invoice_document)).to eq([])
  end

  it 'exige el código de moneda' do
    document = valid_invoice_document
    document['ResumenFactura']['CodigoTipoMoneda']['CodigoMoneda'] = nil

    expect(fields_for(document)).to include('CodigoTipoMoneda.CodigoMoneda')
  end

  it 'rechaza un código que no tiene forma ISO 4217' do
    document = valid_invoice_document
    document['ResumenFactura']['CodigoTipoMoneda']['CodigoMoneda'] = 'us'

    expect(fields_for(document)).to include('CodigoTipoMoneda.CodigoMoneda')
  end

  it 'exige que el tipo de cambio sea exactamente 1 para colones' do
    document = valid_invoice_document
    document['ResumenFactura']['CodigoTipoMoneda']['TipoCambio'] = BigDecimal('1.5')

    expect(fields_for(document)).to include('CodigoTipoMoneda.TipoCambio')
  end

  it 'exige un tipo de cambio mayor a cero para moneda extranjera' do
    document = valid_invoice_document
    document['ResumenFactura']['CodigoTipoMoneda'] = { 'CodigoMoneda' => 'USD', 'TipoCambio' => BigDecimal(0) }

    expect(fields_for(document)).to include('CodigoTipoMoneda.TipoCambio')
  end

  it 'un dólar con tipo de cambio positivo no reporta nada' do
    document = valid_invoice_document
    document['ResumenFactura']['CodigoTipoMoneda'] = { 'CodigoMoneda' => 'USD', 'TipoCambio' => BigDecimal(535) }

    expect(errors_for(document)).to eq([])
  end
end

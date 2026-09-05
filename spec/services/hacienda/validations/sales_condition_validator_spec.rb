# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::SalesConditionValidator do
  def errors_for(document) = described_class.new(document).call
  def fields_for(document) = errors_for(document).map(&:field)

  it 'no reporta nada para un documento a crédito consistente' do
    expect(errors_for(valid_invoice_document)).to eq([])
  end

  describe 'crédito' do
    it 'exige el plazo de crédito' do
      document = valid_invoice_document
      document['PlazoCredito'] = 0

      expect(fields_for(document)).to include('PlazoCredito')
    end

    it 'rechaza que el medio de pago cubra el total: no sería una venta a crédito' do
      document = valid_invoice_document
      document['ResumenFactura']['MedioPago'] = [
        { 'TipoMedioPago' => '01', 'MedioPagoOtros' => nil, 'TotalMedioPago' => BigDecimal(226) }
      ]

      expect(fields_for(document)).to include('ResumenFactura.MedioPago')
    end
  end

  describe 'contado' do
    def contado_document
      document = valid_invoice_document
      document['CondicionVenta'] = '01'
      document['PlazoCredito'] = 0
      document['ResumenFactura']['MedioPago'] = [
        { 'TipoMedioPago' => '01', 'MedioPagoOtros' => nil, 'TotalMedioPago' => BigDecimal(226) }
      ]
      document
    end

    it 'un contado bien formado no reporta nada' do
      expect(errors_for(contado_document)).to eq([])
    end

    it 'exige que el plazo sea cero' do
      document = contado_document
      document['PlazoCredito'] = 5

      expect(fields_for(document)).to include('PlazoCredito')
    end

    it 'exige al menos un medio de pago' do
      document = contado_document
      document['ResumenFactura']['MedioPago'] = []

      expect(fields_for(document)).to include('ResumenFactura.MedioPago')
    end

    it 'exige que la suma de los medios de pago cuadre contra el total' do
      document = contado_document
      document['ResumenFactura']['MedioPago'] = [
        { 'TipoMedioPago' => '01', 'MedioPagoOtros' => nil, 'TotalMedioPago' => BigDecimal(100) }
      ]

      expect(fields_for(document)).to include('ResumenFactura.MedioPago')
    end
  end

  describe 'condición de venta 99 (Otros)' do
    it 'exige el detalle de "condición de venta otros"' do
      document = valid_invoice_document
      document['CondicionVenta'] = '99'
      document['CondicionVentaOtros'] = nil

      expect(fields_for(document)).to include('CondicionVentaOtros')
    end
  end
end

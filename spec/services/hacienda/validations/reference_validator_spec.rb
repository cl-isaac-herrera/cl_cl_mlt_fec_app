# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::ReferenceValidator do
  def valid_reference(overrides = {})
    {
      'TipoDocIR' => '01', 'TipoDocRefOTRO' => nil, 'Numero' => '00100001010000000099',
      'FechaEmisionIR' => '2026-08-01', 'Codigo' => '01', 'CodigoReferenciaOTRO' => nil,
      'Razon' => 'Anula la factura anterior'
    }.merge(overrides)
  end

  def errors_for(reference) = described_class.new(reference).call
  def fields_for(reference) = errors_for(reference).map(&:field)

  it 'no reporta nada para una referencia consistente' do
    expect(errors_for(valid_reference)).to eq([])
  end

  it 'rechaza un tipo de documento de referencia fuera del catálogo' do
    expect(fields_for(valid_reference('TipoDocIR' => '77'))).to include('TipoDocIR')
  end

  it 'exige el número del documento referenciado' do
    expect(fields_for(valid_reference('Numero' => nil))).to include('Numero')
  end

  it 'exige la fecha de emisión' do
    expect(fields_for(valid_reference('FechaEmisionIR' => nil))).to include('FechaEmisionIR')
  end

  it 'exige un código de referencia del catálogo' do
    expect(fields_for(valid_reference('Codigo' => '77'))).to include('Codigo')
  end

  it 'exige la razón' do
    expect(fields_for(valid_reference('Razon' => nil))).to include('Razon')
  end

  # Regla #71-72: facturación de mes vencido exime código y razón.
  it 'no exige código ni razón cuando el tipo es 13 (facturación de mes vencido)' do
    reference = valid_reference('TipoDocIR' => '13', 'Codigo' => nil, 'Razon' => nil)

    expect(errors_for(reference)).to eq([])
  end
end

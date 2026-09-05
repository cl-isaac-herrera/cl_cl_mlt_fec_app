# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::OtherChargeValidator do
  def valid_charge(overrides = {})
    {
      'TipoDocumentoOC' => '01', 'TipoDocumentoOTROS' => nil,
      'IdentificacionTercero' => { 'Tipo' => nil, 'Numero' => nil },
      'NombreTercero' => nil, 'Detalle' => 'Timbre', 'PorcentajeOC' => BigDecimal(0),
      'MontoCargo' => BigDecimal(10)
    }.merge(overrides)
  end

  def errors_for(charge) = described_class.new(charge).call
  def fields_for(charge) = errors_for(charge).map(&:field)

  it 'no reporta nada para un cargo consistente' do
    expect(errors_for(valid_charge)).to eq([])
  end

  it 'rechaza un tipo de documento fuera del catálogo' do
    expect(fields_for(valid_charge('TipoDocumentoOC' => '77'))).to include('TipoDocumentoOC')
  end

  describe 'cobro de un tercero (TipoDocumentoOC = 04)' do
    it 'exige la identificación y el nombre del tercero' do
      charge = valid_charge('TipoDocumentoOC' => '04')

      expect(fields_for(charge)).to include('IdentificacionTercero.Numero', 'NombreTercero')
    end

    it 'con los dos datos presentes no reporta nada' do
      charge = valid_charge(
        'TipoDocumentoOC' => '04',
        'IdentificacionTercero' => { 'Tipo' => '01', 'Numero' => '123456789' },
        'NombreTercero' => 'Un tercero'
      )

      expect(errors_for(charge)).to eq([])
    end
  end

  it 'exige el detalle' do
    expect(fields_for(valid_charge('Detalle' => nil))).to include('Detalle')
  end

  it 'rechaza un porcentaje negativo' do
    expect(fields_for(valid_charge('PorcentajeOC' => BigDecimal(-1)))).to include('PorcentajeOC')
  end

  it 'rechaza que porcentaje y monto sean cero los dos a la vez' do
    charge = valid_charge('PorcentajeOC' => BigDecimal(0), 'MontoCargo' => BigDecimal(0))

    expect(fields_for(charge)).to include('PorcentajeOC', 'MontoCargo')
  end

  it 'exige un monto de cargo mayor a cero' do
    expect(fields_for(valid_charge('MontoCargo' => BigDecimal(0), 'PorcentajeOC' => BigDecimal(5))))
      .to include('MontoCargo')
  end
end

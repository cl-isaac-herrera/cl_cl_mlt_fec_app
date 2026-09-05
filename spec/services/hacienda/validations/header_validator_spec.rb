# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::HeaderValidator do
  def errors_for(document) = described_class.new(document).call
  def fields_for(document) = errors_for(document).map(&:field)

  it 'no reporta nada para un documento consistente' do
    expect(errors_for(valid_invoice_document)).to eq([])
  end

  it 'exige el código de actividad del emisor' do
    document = valid_invoice_document
    document['CodigoActividadEmisor'] = nil

    expect(fields_for(document)).to include('CodigoActividadEmisor')
  end

  it 'rechaza una condición de venta fuera del catálogo' do
    document = valid_invoice_document
    document['CondicionVenta'] = '77'

    expect(fields_for(document)).to include('CondicionVenta')
  end

  it 'rechaza un tipo de identificación del emisor fuera del catálogo' do
    document = valid_invoice_document
    document['Emisor']['Identificacion']['Tipo'] = '09'

    expect(fields_for(document)).to include('Emisor.Identificacion.Tipo')
  end

  describe 'identificación del receptor' do
    it 'exige el tipo' do
      document = valid_invoice_document
      document['Receptor']['Identificacion']['Tipo'] = nil

      expect(fields_for(document)).to include('Receptor.Identificacion.Tipo')
    end

    it 'exige el número' do
      document = valid_invoice_document
      document['Receptor']['Identificacion']['Numero'] = nil

      expect(fields_for(document)).to include('Receptor.Identificacion.Numero')
    end

    it 'rechaza una longitud que no corresponde al tipo (cédula física = 9)' do
      document = valid_invoice_document
      document['Receptor']['Identificacion']['Numero'] = '12345' # 5, no 9

      expect(fields_for(document)).to include('Receptor.Identificacion.Numero')
    end

    it 'acepta las dos longitudes válidas de DIMEX (11 o 12)' do
      document = valid_invoice_document
      document['Receptor']['Identificacion'] = { 'Tipo' => '03', 'Numero' => '1' * 12 }

      expect(errors_for(document)).to eq([])
    end
  end
end

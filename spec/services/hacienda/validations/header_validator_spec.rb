# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::HeaderValidator do
  def errors_for(document, doc_type: DocType::FE) = described_class.new(document, doc_type: doc_type).call
  def fields_for(document, doc_type: DocType::FE) = errors_for(document, doc_type: doc_type).map(&:field)

  def sin_receptor(document)
    document['Receptor']['Identificacion'] = { 'Tipo' => nil, 'Numero' => nil }
    document
  end

  it 'no reporta nada para un documento consistente' do
    expect(errors_for(valid_unified_document)).to eq([])
  end

  it 'exige el código de actividad del emisor' do
    document = valid_unified_document
    document['CodigoActividadEmisor'] = nil

    expect(fields_for(document)).to include('CodigoActividadEmisor')
  end

  it 'rechaza una condición de venta fuera del catálogo' do
    document = valid_unified_document
    document['CondicionVenta'] = '77'

    expect(fields_for(document)).to include('CondicionVenta')
  end

  it 'rechaza un tipo de identificación del emisor fuera del catálogo' do
    document = valid_unified_document
    document['Emisor']['Identificacion']['Tipo'] = '09'

    expect(fields_for(document)).to include('Emisor.Identificacion.Tipo')
  end

  describe 'identificación del receptor' do
    it 'exige el tipo' do
      document = valid_unified_document
      document['Receptor']['Identificacion']['Tipo'] = nil

      expect(fields_for(document)).to include('Receptor.Identificacion.Tipo')
    end

    it 'exige el número' do
      document = valid_unified_document
      document['Receptor']['Identificacion']['Numero'] = nil

      expect(fields_for(document)).to include('Receptor.Identificacion.Numero')
    end

    it 'rechaza una longitud que no corresponde al tipo (cédula física = 9)' do
      document = valid_unified_document
      document['Receptor']['Identificacion']['Numero'] = '12345' # 5, no 9

      expect(fields_for(document)).to include('Receptor.Identificacion.Numero')
    end

    it 'acepta las dos longitudes válidas de DIMEX (11 o 12)' do
      document = valid_unified_document
      document['Receptor']['Identificacion'] = { 'Tipo' => '03', 'Numero' => '1' * 12 }

      expect(errors_for(document)).to eq([])
    end

    # La ÚNICA regla de todo `OwnValidations` que distingue factura de tiquete
    # (`Validations.cs` L324, L329). Un tiquete a un cliente que no da su
    # cédula es el caso normal: exigirla rechazaría documentos correctos.
    describe 'en los tipos que el legacy exime (TE, ND, NC)' do
      it 'acepta un tiquete sin identificación del receptor' do
        expect(errors_for(sin_receptor(valid_unified_document), doc_type: DocType::TE)).to eq([])
      end

      it 'sigue exigiéndola en factura electrónica' do
        fields = fields_for(sin_receptor(valid_unified_document), doc_type: DocType::FE)

        expect(fields).to include('Receptor.Identificacion.Tipo', 'Receptor.Identificacion.Numero')
      end

      # Lo que se exime es EXIGIR el receptor, no revisarlo: el legacy valida
      # formato y longitud con un `if` que no excluye a ningún tipo.
      it 'revisa el tipo del tiquete si viene declarado' do
        document = valid_unified_document
        document['Receptor']['Identificacion'] = { 'Tipo' => '09', 'Numero' => '123456789' }

        expect(fields_for(document, doc_type: DocType::TE)).to include('Receptor.Identificacion.Tipo')
      end

      it 'revisa la longitud del tiquete si viene declarada' do
        document = valid_unified_document
        document['Receptor']['Identificacion'] = { 'Tipo' => '01', 'Numero' => '12345' }

        expect(fields_for(document, doc_type: DocType::TE)).to include('Receptor.Identificacion.Numero')
      end

      # Media identificación no identifica a nadie (`Validations.cs` L339).
      it 'exige el número del tiquete cuando se declaró un tipo' do
        document = valid_unified_document
        document['Receptor']['Identificacion'] = { 'Tipo' => '01', 'Numero' => nil }

        expect(fields_for(document, doc_type: DocType::TE)).to include('Receptor.Identificacion.Numero')
      end
    end
  end

  # El resto de la cabecera NO distingue por tipo: el legacy excluye el código
  # de actividad solo para FEC y REP (`Validations.cs` L299).
  it 'exige el código de actividad del emisor también en el tiquete' do
    document = sin_receptor(valid_unified_document)
    document['CodigoActividadEmisor'] = nil

    expect(fields_for(document, doc_type: DocType::TE)).to include('CodigoActividadEmisor')
  end
end

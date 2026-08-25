# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocType do
  # Este bloque existe para que nadie "corrija" los códigos de vuelta a los
  # comentarios cruzados del `DocTypesString` del .NET. Ver la cabecera de
  # `app/models/doc_type.rb`: el fuente original comenta `02` como nota de
  # crédito y `03` como nota de débito, al revés de lo que dicen sus propios
  # nombres de constante y de lo que fija Hacienda.
  describe 'códigos de Hacienda' do
    it 'asigna 02 a la nota de DÉBITO y 03 a la de CRÉDITO' do
      expect(described_class::ND).to eq('02')
      expect(described_class::NC).to eq('03')
      expect(described_class.label('02')).to eq('Nota de débito electrónica')
      expect(described_class.label('03')).to eq('Nota de crédito electrónica')
    end

    it 'conserva el cero adelante' do
      expect(described_class::FE).to eq('01')
    end
  end

  describe '.normalize' do
    it 'completa el cero que se pierde cuando el dato viajó como número' do
      expect(described_class.normalize('1')).to eq('01')
      expect(described_class.normalize(1)).to eq('01')
    end

    it 'recorta los espacios del char(n) de SQL Server' do
      expect(described_class.normalize(' 04 ')).to eq('04')
    end

    it 'devuelve nil para un código que no es de Hacienda' do
      expect(described_class.normalize('99')).to be_nil
      expect(described_class.normalize('')).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe '.label' do
    # Un código desconocido en pantalla es información: esconderlo obliga a ir al
    # log para saber qué llegó.
    it 'devuelve el código crudo cuando no lo conoce' do
      expect(described_class.label('99')).to eq('99')
    end
  end

  describe '.receiver_message?' do
    it 'reconoce los tres mensajes de receptor' do
      expect(described_class.receiver_message?('05')).to be(true)
      expect(described_class.receiver_message?('06')).to be(true)
      expect(described_class.receiver_message?('07')).to be(true)
    end

    it 'no marca un comprobante como mensaje' do
      expect(described_class.receiver_message?(described_class::FE)).to be(false)
    end
  end
end

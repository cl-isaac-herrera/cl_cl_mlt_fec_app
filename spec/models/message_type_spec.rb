# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageType do
  describe '.from_body_tag' do
    it 'reconoce los 6 valores válidos del tag [Status:...], sin importar mayúsculas' do
      expect(described_class.from_body_tag('ACEPTADO')).to eq(described_class::ACCEPTED)
      expect(described_class.from_body_tag('aceptada')).to eq(described_class::ACCEPTED)
      expect(described_class.from_body_tag('PAceptado')).to eq(described_class::PARTIALLY_ACCEPTED)
      expect(described_class.from_body_tag('paceptada')).to eq(described_class::PARTIALLY_ACCEPTED)
      expect(described_class.from_body_tag('Rechazado')).to eq(described_class::REJECTED)
      expect(described_class.from_body_tag('rechazada')).to eq(described_class::REJECTED)
    end

    it 'devuelve nil para un valor que no está en el catálogo' do
      expect(described_class.from_body_tag('QUIENSABE')).to be_nil
      expect(described_class.from_body_tag(nil)).to be_nil
      expect(described_class.from_body_tag('')).to be_nil
    end
  end

  describe '.to_doc_type' do
    it 'traduce el dígito al código Hacienda de 2 dígitos' do
      expect(described_class.to_doc_type(described_class::ACCEPTED)).to eq(DocType::AT)
      expect(described_class.to_doc_type(described_class::PARTIALLY_ACCEPTED)).to eq(DocType::AP)
      expect(described_class.to_doc_type(described_class::REJECTED)).to eq(DocType::RC)
    end

    it 'revienta con un dígito fuera de catálogo' do
      expect { described_class.to_doc_type(9) }.to raise_error(KeyError)
    end
  end

  describe '.valid?' do
    it { expect(described_class.valid?(1)).to be(true) }
    it { expect(described_class.valid?(9)).to be(false) }
  end
end

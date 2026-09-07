# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailConfig do
  def build_config(**attrs)
    described_class.new({ email: 'facturas@acme.test', host: 'smtp.acme.test', port: 587 }.merge(attrs))
  end

  describe 'validaciones' do
    it 'es válido con los campos mínimos' do
      expect(build_config).to be_valid
    end

    it 'exige el correo' do
      config = build_config(email: nil)

      expect(config).not_to be_valid
      expect(config.errors[:email]).to include('no puede estar en blanco')
    end

    it 'exige un correo con formato válido' do
      config = build_config(email: 'no-es-un-correo')

      expect(config).not_to be_valid
    end

    it 'exige el servidor' do
      config = build_config(host: nil)

      expect(config).not_to be_valid
    end

    it 'exige el puerto' do
      config = build_config(port: nil)

      expect(config).not_to be_valid
    end

    it 'rechaza un puerto fuera de rango' do
      config = build_config(port: 70_000)

      expect(config).not_to be_valid
    end

    it 'el nombre del remitente es opcional' do
      expect(build_config(sender_address: nil)).to be_valid
    end
  end

  describe '#from_header' do
    it 'usa solo el correo cuando no hay nombre de remitente' do
      config = build_config(sender_address: nil)

      expect(config.from_header).to eq('facturas@acme.test')
    end

    it 'antepone el nombre de remitente al correo real' do
      config = build_config(sender_address: 'Facturación Electrónica')

      expect(config.from_header).to eq('"Facturación Electrónica" <facturas@acme.test>')
    end
  end

  describe 'cifrado de la contraseña' do
    it 'guarda la contraseña de forma reversible' do
      config = build_config(password: 's3cr3t0')
      config.save!

      expect(described_class.find(config.id).password).to eq('s3cr3t0')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Documents::MailRecipients do
  let(:company) { Company.new(name: 'ACME S.A.') }

  def header(raw)
    Documents::Row.new('RcprCorreoElectronico' => raw)
  end

  describe '.for' do
    it 'usa la posición 0 como destinatario y el resto en copia' do
      to, cc = described_class.for(header: header('cliente@test.com;otro@test.com'), company: company)

      expect(to).to eq('cliente@test.com')
      expect(cc).to eq('otro@test.com')
    end

    it 'agrega los correos en copia de la compañía después de los de SAP' do
      company.email_cc = 'cc1@test.com;cc2@test.com'

      _to, cc = described_class.for(header: header('cliente@test.com;otro@test.com'), company: company)

      expect(cc).to eq('otro@test.com;cc1@test.com;cc2@test.com')
    end

    it 'cc queda en nil sin correos adicionales' do
      _to, cc = described_class.for(header: header('cliente@test.com'), company: company)

      expect(cc).to be_nil
    end

    it 'devuelve [nil, nil] sin destinatario en la cabecera' do
      expect(described_class.for(header: header(nil), company: company)).to eq([nil, nil])
    end
  end

  describe '.split_emails' do
    it 'recorta espacios y descarta vacíos' do
      expect(described_class.split_emails(' a@test.com ; ;b@test.com')).to eq(%w[a@test.com b@test.com])
    end

    it 'devuelve [] sin valor' do
      expect(described_class.split_emails(nil)).to eq([])
    end
  end
end

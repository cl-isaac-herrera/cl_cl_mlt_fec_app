# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReceptionMailbox do
  def build_mailbox(**attrs)
    described_class.new({ mail_server: 'imap.acme.test', email: 'facturas@acme.test',
                          port: 993, password: 's3cr3t0' }.merge(attrs))
  end

  describe 'validaciones — modo usuario/contraseña' do
    it 'es válida con los campos mínimos' do
      expect(build_mailbox).to be_valid
    end

    it 'exige el servidor' do
      expect(build_mailbox(mail_server: nil)).not_to be_valid
    end

    it 'exige el correo' do
      mailbox = build_mailbox(email: nil)

      expect(mailbox).not_to be_valid
      expect(mailbox.errors[:email]).to include('no puede estar en blanco')
    end

    it 'exige un correo con formato válido' do
      expect(build_mailbox(email: 'no-es-un-correo')).not_to be_valid
    end

    it 'exige el puerto' do
      expect(build_mailbox(port: nil)).not_to be_valid
    end

    it 'rechaza un puerto fuera de rango' do
      expect(build_mailbox(port: 70_000)).not_to be_valid
    end

    it 'exige la contraseña al crear, cuando no usa token' do
      mailbox = build_mailbox(password: nil)

      expect(mailbox).not_to be_valid
      expect(mailbox.errors[:password]).to include('no puede estar en blanco')
    end

    it 'no vuelve a exigir la contraseña al editar' do
      mailbox = build_mailbox
      mailbox.save!

      mailbox.password = nil
      mailbox.mail_server = 'imap.otro.test'

      expect(mailbox).to be_valid
    end
  end

  describe 'validaciones — modo OAuth2 (use_token)' do
    def build_oauth_mailbox(**attrs)
      build_mailbox(**{
        use_token: true, password: nil,
        url: 'https://login.microsoftonline.com/72f988bf-86f1-41af-91ab-2d7cd011db47/oauth2/v2.0/token',
        grant_type: 'client_credentials', scope: 'https://outlook.office365.com/.default',
        client_id: 'client-abc', client_secret: 's3cr3t0'
      }.merge(attrs))
    end

    it 'es válida con los campos mínimos de OAuth2' do
      expect(build_oauth_mailbox).to be_valid
    end

    it 'no exige contraseña cuando usa token' do
      expect(build_oauth_mailbox(password: nil)).to be_valid
    end

    it 'exige el client secret al crear' do
      mailbox = build_oauth_mailbox(client_secret: nil)

      expect(mailbox).not_to be_valid
      expect(mailbox.errors[:client_secret]).to include('no puede estar en blanco')
    end

    %i[url grant_type scope client_id].each do |field|
      it "exige #{field}" do
        expect(build_oauth_mailbox(**{ field => nil })).not_to be_valid
      end
    end
  end

  describe 'cifrado' do
    it 'guarda la contraseña de forma reversible' do
      mailbox = build_mailbox(password: 's3cr3t0')
      mailbox.save!

      expect(described_class.find(mailbox.id).password).to eq('s3cr3t0')
      expect(mailbox.read_attribute_before_type_cast(:password)).not_to include('s3cr3t0')
    end

    it 'guarda el client secret de forma reversible' do
      mailbox = build_mailbox(use_token: true, password: nil, url: 'https://x.test',
                              grant_type: 'client_credentials', scope: 's', client_id: 'c',
                              client_secret: 'muy-secreto')
      mailbox.save!

      expect(described_class.find(mailbox.id).client_secret).to eq('muy-secreto')
    end
  end

  describe 'baja lógica' do
    it 'no se puede desactivar mientras una compañía la use' do
      mailbox = build_mailbox
      mailbox.save!
      Company.create!(name: 'Beta S.A.', reception_mailbox: mailbox)

      mailbox.is_active = false

      expect(mailbox).not_to be_valid
      expect(mailbox.errors[:base].first).to include('Beta S.A.')
    end

    it 'se puede desactivar sin compañías asignadas' do
      mailbox = build_mailbox
      mailbox.save!

      mailbox.is_active = false

      expect(mailbox).to be_valid
    end
  end
end

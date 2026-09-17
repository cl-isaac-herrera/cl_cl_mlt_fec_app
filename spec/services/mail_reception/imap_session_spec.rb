# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailReception::ImapSession do
  def build_mailbox(**attrs)
    ReceptionMailbox.new({ mail_server: 'imap.test', email: 'a@test.com', port: 993, password: 'x' }.merge(attrs))
  end

  def build_oauth_mailbox(**attrs)
    build_mailbox(**{
      use_token: true, password: nil, url: 'https://x.test/token', grant_type: 'client_credentials',
      scope: 's', client_id: 'c', client_secret: 'secret'
    }.merge(attrs))
  end

  describe '#open' do
    it 'yields the connected session and closes it afterwards' do
      imap = instance_double(Net::IMAP, login: nil, select: nil, logout: nil, disconnect: nil)
      allow(Net::IMAP).to receive(:new).and_return(imap)

      yielded = nil
      described_class.new(build_mailbox).open { |session| yielded = session }

      expect(yielded).to eq(imap)
      expect(imap).to have_received(:logout)
      expect(imap).to have_received(:disconnect)
    end

    it 'cierra la sesión incluso si el bloque revienta' do
      imap = instance_double(Net::IMAP, login: nil, select: nil, logout: nil, disconnect: nil)
      allow(Net::IMAP).to receive(:new).and_return(imap)

      expect do
        described_class.new(build_mailbox).open { raise 'boom' }
      end.to raise_error('boom')
      expect(imap).to have_received(:logout)
    end

    it 'envuelve cualquier fallo de conexión en ConnectionError' do
      allow(Net::IMAP).to receive(:new).and_raise(SocketError, 'no route to host')

      expect { described_class.new(build_mailbox).open { |session| session } }
        .to raise_error(described_class::ConnectionError, /no route to host/)
    end

    # Ver el comentario de `#enrich`: Exchange Online acepta el token de
    # client credentials pero rechaza el SELECT cuando el buzón no tiene IMAP
    # habilitado o falta la Application Access Policy — un error real y
    # documentado de Microsoft, no un bug de esta app.
    it 'agrega la guía de Exchange Online cuando el modo es OAuth2' do
      imap = instance_double(Net::IMAP, authenticate: nil)
      allow(Net::IMAP).to receive(:new).and_return(imap)
      allow(imap).to receive(:select).and_raise(StandardError, 'a1 NO User is authenticated but not connected.')
      allow(MailReception::OauthToken).to receive(:new)
        .and_return(instance_double(MailReception::OauthToken, fetch: 'access-token'))

      expect { described_class.new(build_oauth_mailbox).open { |session| session } }
        .to raise_error(described_class::ConnectionError, /Application Access Policy/)
    end

    it 'NO agrega la guía de Exchange cuando la bandeja usa usuario/contraseña' do
      imap = instance_double(Net::IMAP, login: nil)
      allow(Net::IMAP).to receive(:new).and_return(imap)
      allow(imap).to receive(:select).and_raise(StandardError, 'a1 NO User is authenticated but not connected.')

      error = nil
      begin
        described_class.new(build_mailbox).open { |session| session }
      rescue described_class::ConnectionError => e
        error = e
      end

      expect(error.message).not_to include('Application Access Policy')
    end
  end
end

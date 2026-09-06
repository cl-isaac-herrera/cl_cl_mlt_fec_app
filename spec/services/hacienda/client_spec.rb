# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Client do
  let(:company) do
    Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME',
                    token_user: 'cpj-3-101-822733@stag.comprobanteselectronicos.go.cr',
                    token_password: 'clave-atv')
  end

  # Las tres URLs, el client_id y el grant_type son del ambiente y viven en
  # `settings`; el usuario y la contraseña del ATV son del contribuyente y viven
  # en la compañía. Ver la cabecera de `Hacienda::Client`.
  SETTINGS = {
    'HACIENDA_FE_URI_TOKEN' => 'https://idp.test/auth/realms/rut-stag/protocol/openid-connect/',
    'HACIENDA_FE_URI_SEND' => 'https://api.test/recepcion/v1/recepcion',
    'HACIENDA_FE_URI_CHECK' => 'https://api.test/recepcion/v1/recepcion',
    'HACIENDA_FE_CLIENT_ID' => 'api-stag',
    'HACIENDA_FE_GRANT_TYPE' => 'password'
  }.freeze

  before do
    SETTINGS.each do |code, value|
      Setting.create!(code: code, group_code: 'HACIENDA_FE', description: code, value: value)
    end
  end

  def stub_token(status: 200, body: { access_token: 'el-token', expires_in: 300 }.to_json)
    stub_request(:post, 'https://idp.test/auth/realms/rut-stag/protocol/openid-connect/token')
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_send(status:, headers: {})
    stub_request(:post, 'https://api.test/recepcion/v1/recepcion')
      .to_return(status: status, headers: headers)
  end

  def send_document
    described_class.new(company).send_document(
      clave: '5' * 50,
      comprobante_xml: 'PEZhY3R1cmE+',
      fecha: '2026-09-06T10:00:00-06:00',
      emisor: { 'numeroIdentificacion' => '3101822733', 'tipoIdentificacion' => '02' },
      receptor: { 'numeroIdentificacion' => '123456789', 'tipoIdentificacion' => '01' }
    )
  end

  describe 'token' do
    it 'lo pide con los cuatro parámetros del formulario que espera Hacienda' do
      stub_token
      stub_send(status: 202)

      send_document

      expect(a_request(:post, %r{openid-connect/token}).with { |req|
        URI.decode_www_form(req.body).to_h == {
          'grant_type' => 'password', 'client_id' => 'api-stag',
          'username' => 'cpj-3-101-822733@stag.comprobanteselectronicos.go.cr',
          'password' => 'clave-atv'
        }
      }).to have_been_made
    end

    # Un ajuste terminado en `token` produciría `…/token/token` y un 404 sin
    # explicación. Se tolera que el operador haya pegado la URL completa.
    it 'no duplica el sufijo si el ajuste ya trae la URL completa' do
      Setting.find_by!(code: 'HACIENDA_FE_URI_TOKEN')
             .update!(value: 'https://idp.test/auth/realms/rut-stag/protocol/openid-connect/token')
      stub_token
      stub_send(status: 202)

      send_document

      expect(a_request(:post, %r{token/token})).not_to have_been_made
    end

    it 'un token vacío es transitorio y nombra qué revisar' do
      stub_token(body: { access_token: '' }.to_json)

      expect { send_document }.to raise_error(described_class::TransientError, /token vacío/)
    end

    # Un 401 al pedir el token es Hacienda diciendo que el usuario, la
    # contraseña o el Client ID están mal — no algo que se arregle solo
    # reintentando la misma credencial (a diferencia de un 401 en el ENVÍO,
    # donde el token pudo vencer entre que se pidió y que se usó).
    it 'un 401 al pedir el token no es transitorio: son credenciales inválidas' do
      stub_token(status: 401, body: '')
      stub_send(status: 202)

      expect { send_document }.to raise_error(described_class::InvalidCredentials, /usuario y la contraseña/)
      expect(a_request(:post, 'https://api.test/recepcion/v1/recepcion')).not_to have_been_made
    end

    it 'un 5xx al pedir el token sí es transitorio' do
      stub_token(status: 503, body: '')

      expect { send_document }.to raise_error(described_class::TransientError, /usuario y la contraseña/)
    end

    # Un token por instancia y no uno por documento: el job crea un cliente por
    # compañía y por corrida.
    it 'lo reutiliza entre envíos del mismo cliente' do
      stub_token
      stub_send(status: 202)
      client = described_class.new(company)
      args = { clave: '5' * 50, comprobante_xml: 'eA==', fecha: '2026-09-06T10:00:00-06:00',
               emisor: {}, receptor: {} }

      2.times { client.send_document(**args) }

      expect(a_request(:post, %r{openid-connect/token})).to have_been_made.once
    end
  end

  describe 'envío aceptado' do
    it 'devuelve el Location donde Hacienda va a publicar la resolución' do
      stub_token
      stub_send(status: 202, headers: { 'Location' => 'https://api.test/recepcion/v1/recepcion/555' })

      receipt = send_document

      expect(receipt.location).to eq('https://api.test/recepcion/v1/recepcion/555')
      expect(receipt).not_to be_duplicate
    end

    it 'manda la clave, la fecha, las identificaciones y el XML en el cuerpo' do
      stub_token
      stub_send(status: 202)

      send_document

      expect(a_request(:post, 'https://api.test/recepcion/v1/recepcion').with { |req|
        JSON.parse(req.body) == {
          'clave' => '5' * 50,
          'fecha' => '2026-09-06T10:00:00-06:00',
          'emisor' => { 'numeroIdentificacion' => '3101822733', 'tipoIdentificacion' => '02' },
          'receptor' => { 'numeroIdentificacion' => '123456789', 'tipoIdentificacion' => '01' },
          'comprobanteXml' => 'PEZhY3R1cmE+'
        } && req.headers['Authorization'] == 'Bearer el-token'
      }).to have_been_made
    end
  end

  # El comprobante ya está en poder de Hacienda: la resolución se consulta
  # igual, así que no es un error.
  describe 'comprobante ya recibido' do
    it 'lo trata como enviado y arma el Location con la clave' do
      stub_token
      stub_send(status: 400,
                headers: { 'X-Error-Cause' => 'El comprobante 5555 fue recibido anteriormente' })

      receipt = send_document

      expect(receipt).to be_duplicate
      expect(receipt.location).to eq("https://api.test/recepcion/v1/recepcion/#{'5' * 50}")
    end
  end

  # La diferencia decide si el documento se puede reintentar tal cual: lo
  # transitorio se reintenta, el rechazo hay que corregirlo en SAP.
  describe 'clasificación de las fallas' do
    it 'un rechazo por el documento lleva el motivo que dio Hacienda' do
      stub_token
      stub_send(status: 400, headers: { 'X-Error-Cause' => 'La clave no cumple el formato' })

      expect { send_document }
        .to raise_error(described_class::RejectedError, /La clave no cumple el formato/)
    end

    it 'un 5xx de Hacienda es transitorio' do
      stub_token
      stub_send(status: 503)

      expect { send_document }.to raise_error(described_class::TransientError, /no pudo recibir/)
    end

    it 'un 403 es transitorio y apunta a la autenticación' do
      stub_token
      stub_send(status: 403)

      expect { send_document }.to raise_error(described_class::TransientError, /autenticación/)
    end

    it 'un timeout es transitorio' do
      stub_token
      stub_request(:post, 'https://api.test/recepcion/v1/recepcion').to_timeout

      expect { send_document }.to raise_error(described_class::TransientError, /No se pudo contactar/)
    end
  end

  describe '#check_status' do
    def check_status(clave: '5' * 50)
      described_class.new(company).check_status(clave)
    end

    def stub_check(clave: '5' * 50, status:, body: nil, headers: {})
      stub_request(:get, "https://api.test/recepcion/v1/recepcion/#{clave}")
        .to_return(status: status, body: body, headers: headers)
    end

    it 'consulta la URL de verificación con la clave y el Bearer' do
      stub_token
      stub_check(status: 200, body: { fecha: '2026-09-06T10:00:00-06:00', 'ind-estado': 'procesando' }.to_json)

      check_status

      expect(a_request(:get, "https://api.test/recepcion/v1/recepcion/#{'5' * 50}")
        .with(headers: { 'Authorization' => 'Bearer el-token' })).to have_been_made
    end

    # `recibido`/`procesando` (o cualquier otro valor) no son un desenlace: el
    # llamador (`CheckSentDocumentsJob`) los trata igual, como "sigue en proceso".
    it 'no está resuelto cuando Hacienda todavía no contesta un desenlace final' do
      stub_token
      stub_check(status: 200, body: { 'ind-estado': 'procesando' }.to_json)

      result = check_status

      expect(result).not_to be_resolved
      expect(result.xml_base64).to be_nil
    end

    it 'está resuelto y aceptado, con el XML de respuesta, cuando Hacienda acepta' do
      stub_token
      stub_check(status: 200, body: { 'ind-estado': 'aceptado', 'respuesta-xml': 'PE1lbnNhamU+' }.to_json)

      result = check_status

      expect(result).to be_resolved
      expect(result).to be_accepted
      expect(result.xml_base64).to eq('PE1lbnNhamU+')
    end

    it 'está resuelto y NO aceptado, con el XML de respuesta, cuando Hacienda rechaza' do
      stub_token
      stub_check(status: 200, body: { 'ind-estado': 'rechazado', 'respuesta-xml': 'PE1lbnNhamU+' }.to_json)

      result = check_status

      expect(result).to be_resolved
      expect(result).not_to be_accepted
    end

    it 'un HTTP que no es 2xx es transitorio, no un rechazo del documento' do
      stub_token
      stub_check(status: 404, headers: { 'X-Error-Cause' => 'No existe el recurso' })

      expect { check_status }.to raise_error(described_class::TransientError, /No existe el recurso/)
    end

    it 'un timeout es transitorio' do
      stub_token
      stub_request(:get, "https://api.test/recepcion/v1/recepcion/#{'5' * 50}").to_timeout

      expect { check_status }.to raise_error(described_class::TransientError, /No se pudo contactar/)
    end

    it 'una respuesta que no es JSON es transitoria' do
      stub_token
      stub_check(status: 200, body: 'no-es-json')

      expect { check_status }.to raise_error(described_class::TransientError, /no es JSON/)
    end
  end

  describe 'instalación a medio configurar' do
    it 'nombra el ajuste que falta' do
      Setting.find_by!(code: 'HACIENDA_FE_URI_SEND').update!(value: nil)
      stub_token

      expect { send_document }
        .to raise_error(described_class::MissingConfiguration, /HACIENDA_FE_URI_SEND/)
    end

    it 'nombra la compañía sin credenciales del ATV' do
      company.update!(token_password: nil)

      expect { send_document }
        .to raise_error(described_class::MissingConfiguration, /ACME S.A.*contraseña del ATV/)
    end

    it 'avisa si una URL configurada no es una dirección http' do
      Setting.find_by!(code: 'HACIENDA_FE_URI_TOKEN').update!(value: 'no-es-una-url')

      expect { send_document }
        .to raise_error(described_class::MissingConfiguration, /no es una dirección http/)
    end
  end
end

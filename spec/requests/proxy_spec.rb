# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ProxyController', type: :request do
  let(:app_url)   { Rails.application.config.api_fe_app_url }
  let(:sync_url)  { Rails.application.config.api_fe_sync_url }
  let(:cabys_url) { ENV.fetch('API_CABYS_URL', 'https://api.hacienda.go.cr/fe/cabys/') }

  # /api/* exige sesión de servidor salvo los endpoints públicos declarados en
  # ProxyController::PUBLIC_API_PATHS (ver el describe del gate más abajo).
  before { sign_in }

  describe 'enrutamiento por header API' do
    it 'sin header API enruta al app server (default)' do
      stub_request(:get, "#{app_url}/api/Menu").to_return(status: 200, body: '{"ok":true}',
                                                          headers: { 'Content-Type' => 'application/json' })

      get '/api/Menu'

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('{"ok":true}')
    end

    it 'con header API: ApiFEUrl enruta al sync server' do
      stub_request(:get, "#{sync_url}/api/Documents").to_return(status: 200, body: '{}',
                                                                headers: { 'Content-Type' => 'application/json' })

      get '/api/Documents', headers: { 'API' => 'ApiFEUrl' }

      expect(response).to have_http_status(:ok)
    end

    it 'con header API: ApiFEUrl y path /api/token, lo reescribe a /token (sin prefijo /api)' do
      stub_request(:post, "#{sync_url}/token").to_return(status: 200, body: '{"access_token":"x"}',
                                                         headers: { 'Content-Type' => 'application/json' })

      post '/api/token', headers: { 'API' => 'ApiFEUrl' }

      expect(response).to have_http_status(:ok)
    end

    it 'con header API: ApiFEUrl pero otro path, NO reescribe el prefijo /api' do
      stub_request(:get, "#{sync_url}/api/Menu").to_return(status: 200, body: '{}')

      get '/api/Menu', headers: { 'API' => 'ApiFEUrl' }

      expect(response).to have_http_status(:ok)
    end

    it 'con header API: ApiCabysURL, deja solo la query en la raíz del base_url' do
      stub_request(:get, "#{cabys_url}?codigo=123").to_return(status: 200, body: '[]')

      get '/api/Cabys', params: { codigo: '123' }, headers: { 'API' => 'ApiCabysURL' }

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'reenvío de headers al cliente' do
    it 'reenvía cl-message, cl-sl-pagination-* y content-disposition, pero no headers arbitrarios' do
      stub_request(:get, "#{app_url}/api/Users").to_return(
        status: 200,
        body: '{}',
        headers: {
          'Content-Type' => 'application/json',
          'cl-message' => 'todo%20bien',
          'cl-sl-pagination-page' => '2',
          'x-arbitrary-header' => 'no-deberia-pasar'
        }
      )

      get '/api/Users'

      expect(response.headers['cl-message']).to eq('todo%20bien')
      expect(response.headers['cl-sl-pagination-page']).to eq('2')
      expect(response.headers['x-arbitrary-header']).to be_nil
    end
  end

  describe 'headers que nunca deben llegar al backend' do
    # Se usa un endpoint público: mandar un header Cookie explícito reemplaza la
    # cookie de sesión del request spec, y acá lo que se prueba es el stripping de
    it 'no reenvía Cookie, Referer ni Origin del browser' do
      seen_headers = nil
      stub_request(:get, "#{app_url}/api/Users").to_return do |request|
        seen_headers = request.headers
        { status: 200, body: '{}' }
      end

      # Se agrega una cookie extra al jar en vez de mandar un header Cookie crudo:
      # eso último reemplazaría la cookie de sesión y el request quedaría sin sesión.
      cookies['galleta_del_browser'] = 'valor'

      get '/api/Users', headers: { 'Referer' => 'http://evil.example', 'Origin' => 'http://evil.example' }

      expect(response).to have_http_status(:ok)
      expect(seen_headers).not_to have_key('Cookie')
      expect(seen_headers).not_to have_key('Referer')
      expect(seen_headers).not_to have_key('Origin')
    end
  end

  describe 'manejo de errores' do
    it 'responde 504 gateway_timeout si el backend no responde a tiempo' do
      stub_request(:get, "#{app_url}/api/Slow").to_timeout

      get '/api/Slow'

      expect(response).to have_http_status(:gateway_timeout)
      expect(JSON.parse(response.body)).to eq('error' => 'API request timed out')
    end

    it 'responde 502 bad_gateway con el mensaje de error si la conexión falla' do
      stub_request(:get, "#{app_url}/api/Down").to_raise(Errno::ECONNREFUSED.new('Connection refused'))

      get '/api/Down'

      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)['error']).to include('API request failed')
    end
  end

  # El token vive en la session cookie httpOnly, nunca en el browser (§2.3).
  describe 'autenticación desde la session cookie' do
    it 'adjunta el Bearer de la sesión al llamar al backend' do
      stub_request(:get, "#{app_url}/api/Menu")
        .with(headers: { 'Authorization' => 'Bearer token-de-sesion' })
        .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

      sign_in(access_token: 'token-de-sesion')

      get '/api/Menu'

      expect(response).to have_http_status(:ok)
    end

    it 'descarta el Authorization que manda el cliente y usa el de la sesión' do
      stub_request(:get, "#{app_url}/api/Menu")
        .with(headers: { 'Authorization' => 'Bearer token-de-sesion' })
        .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

      sign_in(access_token: 'token-de-sesion')

      get '/api/Menu', headers: { 'Authorization' => 'Bearer token-falsificado' }

      expect(response).to have_http_status(:ok)
      expect(
        a_request(:get, "#{app_url}/api/Menu")
          .with(headers: { 'Authorization' => 'Bearer token-falsificado' })
      ).not_to have_been_made
    end

    it 'no manda Authorization cuando la sesión no tiene token' do
      stub_request(:get, "#{app_url}/api/Public").to_return(status: 200, body: '{}')

      get '/api/Public', headers: { 'Authorization' => 'Bearer token-del-browser' }

      expect(
        a_request(:get, "#{app_url}/api/Public")
          .with { |req| req.headers.key?('Authorization') }
      ).not_to have_been_made
    end
  end

  # El gate que faltaba: antes /api/* se reenviaba al backend sin validar nada del
  # lado de Rails. Ahora aplica require_session como en cualquier otro controller,
  # sin excepciones.
  describe 'gate de sesión sobre /api/*' do
    it 'sin sesión NO reenvía la solicitud al backend' do
      stub_request(:get, "#{app_url}/api/Menu").to_return(status: 200, body: '{}')

      reset_session_cookie
      get '/api/Menu'

      expect(a_request(:get, "#{app_url}/api/Menu")).not_to have_been_made
    end

    it 'responde 401 a una llamada de JS sin sesión' do
      stub_request(:get, "#{app_url}/api/Menu").to_return(status: 200, body: '{}')

      reset_session_cookie
      get '/api/Menu', headers: { 'Accept' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end

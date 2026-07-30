# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ProxyController', type: :request do
  let(:app_url)   { Rails.application.config.api_fe_app_url }
  let(:sync_url)  { Rails.application.config.api_fe_sync_url }
  let(:cabys_url) { ENV.fetch('API_CABYS_URL', 'https://api.hacienda.go.cr/fe/cabys/') }

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
    it 'no reenvía Cookie, Referer ni Origin del browser' do
      seen_headers = nil
      stub_request(:get, "#{app_url}/api/Users").to_return do |request|
        seen_headers = request.headers
        { status: 200, body: '{}' }
      end

      get '/api/Users', headers: { 'Cookie' => 'session=abc', 'Referer' => 'http://evil.example', 'Origin' => 'http://evil.example' }

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
end

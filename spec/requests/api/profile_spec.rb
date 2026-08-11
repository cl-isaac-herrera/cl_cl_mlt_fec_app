# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Profiles', type: :request do
  let(:user) do
    User.create!(email: 'perfil@example.com', name: 'Ana Pérez', sap_user: 'manager',
                 sap_password: 'secreto', doc_number_preference: '1')
  end

  def body = JSON.parse(response.body)

  describe 'GET /api/profile' do
    it 'devuelve el perfil del usuario de la sesión' do
      sign_in(user)
      get '/api/profile'

      expect(response).to have_http_status(:ok)
      expect(body['Data']).to include(
        'Id' => user.id, 'Name' => 'Ana Pérez', 'Email' => 'perfil@example.com',
        'SapUser' => 'manager', 'DocNumberPreference' => '1'
      )
    end

    it 'nunca expone la contraseña de SAP, solo si existe' do
      sign_in(user)
      get '/api/profile'

      expect(body['Data']).to include('HasSapPassword' => true)
      expect(response.body).not_to include('secreto')
    end

    it 'respeta el contrato ApiResponse' do
      sign_in(user)
      get '/api/profile'

      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body['Code']).to eq(200)
    end

    it 'responde 401 sin sesión' do
      get '/api/profile'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'PATCH /api/profile' do
    # Tal como lo manda la pantalla: cuerpo JSON, no form-encoded.
    it 'actualiza usuario, contraseña y tipo de OC del usuario en sesión' do
      sign_in(user)
      patch '/api/profile',
            params: { SapUser: 'nuevo', SapPass: 'otra-clave', DocNumberPreference: '2' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(
        sap_user: 'nuevo', sap_password: 'otra-clave', doc_number_preference: '2'
      )
    end

    it 'deja la contraseña intacta cuando llega vacía' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: '', DocNumberPreference: '2' }

      expect(user.reload.sap_password).to eq('secreto')
    end

    it 'guarda la contraseña de SAP cifrada en la base' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'nuevo', SapPass: 'otra-clave' }

      raw = User.connection.select_value("SELECT sap_password FROM users WHERE id = #{user.id}")
      expect(raw).not_to include('otra-clave')
      expect(user.reload.sap_password).to eq('otra-clave')
    end

    it 'ignora cualquier intento de tocar otro usuario: siempre escribe el de la sesión' do
      otro = User.create!(email: 'otro@example.com', sap_user: 'intacto')

      sign_in(user)
      patch '/api/profile', params: { Id: otro.id, SapUser: 'hackeado' }

      expect(otro.reload.sap_user).to eq('intacto')
      expect(user.reload.sap_user).to eq('hackeado')
    end

    it 'rechaza un valor que excede el largo del contrato' do
      sign_in(user)
      patch '/api/profile', params: { SapUser: 'x' * 76 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to be_present
      expect(user.reload.sap_user).to eq('manager')
    end

    it 'responde 401 sin sesión' do
      patch '/api/profile', params: { SapUser: 'nuevo' }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end

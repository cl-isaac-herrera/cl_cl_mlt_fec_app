# frozen_string_literal: true

require 'rails_helper'

# Reemplaza al viejo sessions_spec (la app ya no tiene formulario de login propio).
# Especifica el gate de sesión de servidor que sustituyó al guard de localStorage.
RSpec.describe 'Gate de sesión de servidor', type: :request do
  describe 'páginas protegidas sin sesión' do
    it 'redirige a /login en vez de renderizar la shell protegida' do
      get '/home'

      expect(response).to redirect_to(login_path)
    end

    it 'no filtra nada del contenido protegido en la respuesta' do
      get '/home'

      expect(response.body).not_to include('data-controller="menu"')
    end

    it 'aplica también a la raíz' do
      get '/'

      expect(response).to redirect_to(login_path)
    end

    it 'responde 401 JSON en vez de redirigir cuando el request no es HTML' do
      get '/home', headers: { 'Accept' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'páginas protegidas con sesión' do
    it 'renderiza el dashboard con el layout protected' do
      sign_in

      get '/home'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="menu"')
    end

    it 'ya no inyecta el guard de localStorage en el head' do
      sign_in

      get '/home'

      expect(response.body).not_to include("localStorage.getItem('Session')")
    end
  end

  describe 'páginas públicas' do
    it 'la verificación de cuenta por OTP sigue accesible sin sesión' do
      get '/account-verification/abc123'

      expect(response).to have_http_status(:ok)
    end
  end
end

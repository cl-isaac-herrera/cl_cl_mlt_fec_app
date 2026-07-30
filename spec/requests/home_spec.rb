# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'HomeController', type: :request do
  describe 'GET /home' do
    it 'renderiza el dashboard con el layout protected' do
      get '/home'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="menu"')
    end
  end
end

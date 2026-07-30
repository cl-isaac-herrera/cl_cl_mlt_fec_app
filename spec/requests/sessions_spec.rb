# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SessionsController', type: :request do
  describe 'GET /login' do
    it 'renderiza la vista de login' do
      get '/login'

      expect(response).to have_http_status(:ok)
    end
  end
end

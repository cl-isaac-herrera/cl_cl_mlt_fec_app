# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Configurations::SlResources', type: :request do
  describe 'GET /configurations/sl-resources' do
    # El gate de permisos de la pantalla vive en el menú y en el JS; el
    # controller solo sirve la shell. Lo que este spec protege es que la vista
    # compile, que el controller de Stimulus esté enganchado y que la página use
    # el layout `protected` (CLAUDE.md §14) — sin él la pantalla queda sin menú.
    it 'renderiza la shell con el layout protected' do
      sign_in

      get '/configurations/sl-resources'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="sl-resources"')
      expect(response.body).to include('data-controller="menu"')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# La shell HTML de /configurations/companies/new y /:id/edit. El gate de
# permisos vive en el menú y en el JS (`auth_guard_controller.js`); lo que
# este spec protege es que la vista COMPILE en los dos modos y que cada uno
# renderice el wrapper que le toca — tarjeta plana en el alta, `<details>`
# colapsable en edición (CLAUDE.md, ver `_form.html.erb`).
RSpec.describe 'Configurations::Companies', type: :request do
  let(:acme) { Company.create!(name: 'ACME S.A.') }

  describe 'GET /configurations/companies/new' do
    it 'renderiza la shell con el layout protected' do
      sign_in

      get '/configurations/companies/new'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="company-form"')
      expect(response.body).to include('data-company-form-company-id-value="0"')
      expect(response.body).to include('data-controller="menu"')
    end

    # "Datos Generales", "Adicional", "Hacienda (ATV)" y "Adjuntos" son
    # tarjetas planas y siempre visibles en el alta — nunca un `<details>`
    # colapsable como en edición.
    it 'renderiza las cuatro secciones del alta como tarjetas, no como acordeón' do
      sign_in

      get '/configurations/companies/new'

      %w[section-general section-additional section-atv section-attachments].each do |testid|
        expect(response.body).not_to match(%r{<details[^>]*data-testid="#{testid}"})
      end
      expect(response.body).to include('Datos Generales de la Compañía')
      expect(response.body).to include('Adjuntos de la compañía')
    end
  end

  describe 'GET /configurations/companies/:id/edit' do
    it 'renderiza la shell con el layout protected' do
      sign_in

      get "/configurations/companies/#{acme.id}/edit"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="company-form"')
      expect(response.body).to include("data-company-form-company-id-value=\"#{acme.id}\"")
      expect(response.body).to include('data-controller="menu"')
    end

    # En edición las cuatro siguen siendo un acordeón: cada una se guarda por
    # su cuenta con su propio botón "Actualizar".
    it 'renderiza las cuatro secciones como acordeón (<details>)' do
      sign_in

      get "/configurations/companies/#{acme.id}/edit"

      %w[section-general section-additional section-atv section-attachments].each do |testid|
        expect(response.body).to match(%r{<details[^>]*data-testid="#{testid}"})
      end
    end
  end
end

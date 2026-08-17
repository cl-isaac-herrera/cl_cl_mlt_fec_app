# frozen_string_literal: true

require 'rails_helper'

# Las compañías del usuario de la sesión: alimentan el selector del toolbar, el
# select del panel de perfil y el del alta de usuarios. No confundir con
# `GET /api/companies`, que es el listado de administración de la instalación.
RSpec.describe 'GET /api/profile/companies', type: :request do
  let(:user) { User.create!(email: 'selector@example.com') }
  let(:sap)  { Connection.create!(name: 'SAP Producción', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME') }
  let(:otra) { Company.create!(name: 'Otra S.A.', sap_connection: sap, sap_db: 'SBO_OTRA') }

  def body_data
    JSON.parse(response.body)['Data']
  end

  it 'devuelve solo las compañías asignadas al usuario, no todas las del sistema' do
    UsersByCompany.create!(user: user, company: acme)
    otra # existe pero no está asignada

    sign_in(user)
    get '/api/profile/companies'

    expect(response).to have_http_status(:ok)
    expect(body_data.map { |c| c['Id'] }).to contain_exactly(acme.id)
  end

  # No lleva permiso: sin poder elegir compañía no puede usar ninguna pantalla.
  it 'no exige ningún permiso' do
    UsersByCompany.create!(user: user, company: acme)

    sign_in(user)
    get '/api/profile/companies'

    expect(response).to have_http_status(:ok)
  end

  it 'respeta el contrato ApiResponse' do
    UsersByCompany.create!(user: user, company: acme)

    sign_in(user)
    get '/api/profile/companies'

    expect(JSON.parse(response.body).keys).to include('Data', 'Code', 'Message')
    expect(JSON.parse(response.body)['Code']).to eq(200)
  end

  it 'expone el mapeo a SAP y ambos identificadores' do
    UsersByCompany.create!(user: user, company: acme)

    sign_in(user)
    get '/api/profile/companies'

    expect(body_data.first).to include(
      'Id' => acme.id, 'Uuid' => acme.uuid, 'Name' => 'ACME S.A.',
      'ConnectionId' => sap.id, 'SapDbCode' => 'SBO_ACME'
    )
  end

  it 'excluye las asignaciones desactivadas (soft delete)' do
    UsersByCompany.create!(user: user, company: acme).soft_delete!

    sign_in(user)
    get '/api/profile/companies'

    expect(body_data).to be_empty
  end

  it 'responde 401 sin sesión' do
    get '/api/profile/companies'

    expect(response).to have_http_status(:unauthorized)
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PUT /api/session/company', type: :request do
  let(:user) { User.create!(email: 'switch@example.com') }
  let(:acme) { Company.create!(name: 'ACME', sap_db_code: 'SBO_ACME') }
  let(:ajena) { Company.create!(name: 'Ajena') }

  it 'guarda la compañía en la sesión de servidor cuando está asignada' do
    UsersByCompany.create!(user: user, company: acme)
    sign_in(user)

    put '/api/session/company', params: { company_id: acme.id }

    expect(response).to have_http_status(:ok)
    expect(session[:company_id]).to eq(acme.id)
  end

  it 'rechaza con 403 una compañía que no está asignada al usuario' do
    sign_in(user)

    put '/api/session/company', params: { company_id: ajena.id }

    expect(response).to have_http_status(:forbidden)
    expect(session[:company_id]).to be_nil
  end

  it 'rechaza una asignación desactivada' do
    UsersByCompany.create!(user: user, company: acme).soft_delete!
    sign_in(user)

    put '/api/session/company', params: { company_id: acme.id }

    expect(response).to have_http_status(:forbidden)
  end

  it 'deja la compañía anterior intacta si la nueva es inválida' do
    UsersByCompany.create!(user: user, company: acme)
    sign_in(user, company: acme)

    put '/api/session/company', params: { company_id: ajena.id }

    expect(session[:company_id]).to eq(acme.id)
  end

  it 'responde 401 sin sesión' do
    put '/api/session/company', params: { company_id: acme.id }

    expect(response).to have_http_status(:unauthorized)
  end

  # La compañía en sesión es lo que hace que require_permission! pueda conceder algo.
  it 'habilita los permisos de esa compañía en la siguiente consulta' do
    role    = Role.create!(name: 'Admin')
    permiso = Permission.create!(name: 'Maintenance_Users_Access')
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user)
    put '/api/session/company', params: { company_id: acme.id }
    get '/api/permissions'

    expect(JSON.parse(response.body)['Data'].map { |p| p['Name'] })
      .to contain_exactly('Maintenance_Users_Access')
  end
end

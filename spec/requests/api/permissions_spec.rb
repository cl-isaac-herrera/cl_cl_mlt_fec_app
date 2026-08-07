# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/permissions', type: :request do
  let(:user)    { User.create!(email: 'perms@example.com') }
  let(:acme)    { Company.create!(name: 'ACME') }
  let(:otra)    { Company.create!(name: 'Otra') }
  let(:role)    { Role.create!(name: 'Vendedor') }
  let(:permiso) { Permission.create!(name: 'Sales_Documents_Create') }

  def names
    JSON.parse(response.body)['Data'].map { |p| p['Name'] }
  end

  it 'devuelve los permisos efectivos del usuario en la compañía de la sesión' do
    UserRole.create!(user: user, role: role, company: acme)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user, company: acme)
    get '/api/permissions'

    expect(response).to have_http_status(:ok)
    expect(names).to contain_exactly('Sales_Documents_Create')
  end

  it 'no filtra permisos de otra compañía' do
    UserRole.create!(user: user, role: role, company: otra)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user, company: acme)
    get '/api/permissions'

    expect(names).to be_empty
  end

  it 'devuelve vacío cuando todavía no hay compañía seleccionada' do
    UserRole.create!(user: user, role: role, company: acme)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user)
    get '/api/permissions'

    expect(response).to have_http_status(:ok)
    expect(names).to be_empty
  end

  it 'responde 401 sin sesión' do
    get '/api/permissions'

    expect(response).to have_http_status(:unauthorized)
  end
end

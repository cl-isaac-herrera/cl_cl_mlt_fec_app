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
    UsersByCompany.create!(user: user, company: acme, role: role)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user, company: acme)
    get '/api/permissions'

    expect(response).to have_http_status(:ok)
    expect(names).to contain_exactly('Sales_Documents_Create')
  end

  it 'no filtra permisos de otra compañía' do
    UsersByCompany.create!(user: user, company: otra, role: role)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user, company: acme)
    get '/api/permissions'

    expect(names).to be_empty
  end

  it 'devuelve vacío cuando todavía no hay compañía seleccionada y el permiso es de compañía' do
    UsersByCompany.create!(user: user, company: acme, role: role)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user)
    get '/api/permissions'

    expect(response).to have_http_status(:ok)
    expect(names).to be_empty
  end

  # Roles por alcance (docs/PLAN-ROLES-POR-ALCANCE.md): los permisos de
  # instalación no dependen de la compañía activa — siguen viéndose aunque no
  # haya ninguna seleccionada, a diferencia de los de compañía.
  it 'devuelve los permisos de instalación aunque no haya compañía seleccionada' do
    instalacion_role = Role.create!(name: 'Soporte técnico', scope: 'installation')
    instalacion_permiso = Permission.create!(name: 'Configurations_General_Access', scope: 'installation')
    RolePermission.create!(role: instalacion_role, permission: instalacion_permiso)
    user.update!(installation_role: instalacion_role)

    sign_in(user)
    get '/api/permissions'

    expect(names).to contain_exactly('Configurations_General_Access')
  end

  it 'combina el rol de instalación con el de la compañía activa' do
    instalacion_role = Role.create!(name: 'Soporte técnico', scope: 'installation')
    instalacion_permiso = Permission.create!(name: 'Configurations_General_Access', scope: 'installation')
    RolePermission.create!(role: instalacion_role, permission: instalacion_permiso)
    user.update!(installation_role: instalacion_role)

    UsersByCompany.create!(user: user, company: acme, role: role)
    RolePermission.create!(role: role, permission: permiso)

    sign_in(user, company: acme)
    get '/api/permissions'

    expect(names).to contain_exactly('Configurations_General_Access', 'Sales_Documents_Create')
  end

  it 'responde 401 sin sesión' do
    get '/api/permissions'

    expect(response).to have_http_status(:unauthorized)
  end
end

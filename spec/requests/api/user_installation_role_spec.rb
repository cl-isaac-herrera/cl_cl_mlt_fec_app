# frozen_string_literal: true

require 'rails_helper'

# Rol de INSTALACIÓN de un usuario (docs/PLAN-ROLES-POR-ALCANCE.md): vive en
# `users.installation_role_id`, no depende de ninguna compañía activa, y
# reemplaza tanto al viejo `GET|PUT /api/users/:id/role` (rol por compañía
# activa) como al panel de "permisos globales" directos — los permisos de
# instalación ahora se conceden con un rol, igual que los de compañía.
RSpec.describe 'Api::Users::InstallationRole', type: :request do
  let(:admin)  { User.create!(email: 'admin@example.com', name: 'Administradora') }
  let(:target) { User.create!(email: 'objetivo@example.com', name: 'Objetivo') }
  let(:acme)   { Company.create!(name: 'ACME S.A.') }

  def sign_in_with(*permission_names)
    grant_permissions(admin, *permission_names)
    sign_in(admin)
  end

  def json_headers = { 'CONTENT_TYPE' => 'application/json' }
  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  describe 'GET /api/users/:user_id/installation_role' do
    it 'devuelve el rol de instalación del usuario' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      target.update!(installation_role: rol)

      sign_in_with('Configurations_Users_ManageAccess')
      get "/api/users/#{target.id}/installation_role"

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq('RoleId' => rol.id, 'RoleName' => 'Soporte')
    end

    it 'devuelve null cuando el usuario no tiene rol de instalación' do
      sign_in_with('Configurations_Users_ManageAccess')
      get "/api/users/#{target.id}/installation_role"

      expect(body_data).to be_nil
    end

    it 'no depende de ninguna compañía activa' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      target.update!(installation_role: rol)
      grant_permissions(admin, 'Configurations_Users_ManageAccess')
      sign_in(admin) # sin compañía activa

      get "/api/users/#{target.id}/installation_role"

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq('RoleId' => rol.id, 'RoleName' => 'Soporte')
    end

    it 'responde 404 cuando el usuario no existe' do
      sign_in_with('Configurations_Users_ManageAccess')
      get '/api/users/999999/installation_role'

      expect(response).to have_http_status(:not_found)
    end

    it 'rechaza con 403 a quien no puede gestionar accesos' do
      sign_in_with('Configurations_Users_ListAccess')
      get "/api/users/#{target.id}/installation_role"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PUT /api/users/:user_id/installation_role' do
    it 'asigna el rol de instalación' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      sign_in_with('Configurations_Users_ManageAccess')

      put "/api/users/#{target.id}/installation_role", params: { RoleId: rol.id }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.reload.installation_role_id).to eq(rol.id)
    end

    it 'reemplaza el rol anterior' do
      anterior = Role.create!(name: 'Anterior', scope: 'installation')
      nuevo    = Role.create!(name: 'Nuevo', scope: 'installation')
      target.update!(installation_role: anterior)

      sign_in_with('Configurations_Users_ManageAccess')
      put "/api/users/#{target.id}/installation_role", params: { RoleId: nuevo.id }.to_json, headers: json_headers

      expect(target.reload.installation_role_id).to eq(nuevo.id)
    end

    it 'lo remueve con RoleId null' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      target.update!(installation_role: rol)

      sign_in_with('Configurations_Users_ManageAccess')
      put "/api/users/#{target.id}/installation_role", params: { RoleId: nil }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.reload.installation_role_id).to be_nil
    end

    it 'rechaza un rol que no existe' do
      sign_in_with('Configurations_Users_ManageAccess')

      put "/api/users/#{target.id}/installation_role", params: { RoleId: 999_999 }.to_json, headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El rol no existe.')
    end

    it 'rechaza un rol que no es de instalación' do
      compania = Role.create!(name: 'De compañía', scope: 'company')
      sign_in_with('Configurations_Users_ManageAccess')

      put "/api/users/#{target.id}/installation_role", params: { RoleId: compania.id }.to_json,
                                                       headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(target.reload.installation_role_id).to be_nil
    end

    it 'no depende de ninguna compañía activa' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      grant_permissions(admin, 'Configurations_Users_ManageAccess')
      sign_in(admin) # sin compañía activa

      put "/api/users/#{target.id}/installation_role", params: { RoleId: rol.id }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.reload.installation_role_id).to eq(rol.id)
    end

    it 'rechaza con 403 a quien no puede gestionar accesos' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      sign_in_with('Configurations_Users_ListAccess')

      put "/api/users/#{target.id}/installation_role", params: { RoleId: rol.id }.to_json, headers: json_headers

      expect(response).to have_http_status(:forbidden)
      expect(target.reload.installation_role_id).to be_nil
    end
  end

  # Lo que hace que la asignación signifique algo: sin esto, el rol se guarda
  # pero no concede nada.
  describe 'efecto sobre la autorización' do
    it 'concede los permisos del rol de instalación, sin depender de ninguna compañía' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      permiso = Permission.create!(name: 'Configurations_General_Access', scope: 'installation')
      RolePermission.create!(role: rol, permission: permiso)
      target.update!(installation_role: rol)

      sign_in(target) # sin compañía activa
      get '/api/permissions'

      expect(JSON.parse(response.body)['Data'].map { |p| p['Name'] }).to include('Configurations_General_Access')
    end

    it 'deja de concederlos cuando se le quita el rol' do
      rol = Role.create!(name: 'Soporte', scope: 'installation')
      permiso = Permission.create!(name: 'Configurations_General_Access', scope: 'installation')
      RolePermission.create!(role: rol, permission: permiso)
      target.update!(installation_role: rol)

      sign_in_with('Configurations_Users_ManageAccess')
      put "/api/users/#{target.id}/installation_role", params: { RoleId: nil }.to_json, headers: json_headers

      sign_in(target)
      get '/api/permissions'

      expect(JSON.parse(response.body)['Data'].map { |p| p['Name'] }).not_to include('Configurations_General_Access')
    end
  end
end

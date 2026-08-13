# frozen_string_literal: true

require 'rails_helper'

# Permisos globales concedidos DIRECTAMENTE a un usuario, sin rol ni compañía.
# Es la segunda vía de concesión del producto, así que los specs cubren tanto el
# endpoint como su efecto real sobre la autorización: una asignación que se guarda
# pero no concede nada sería peor que no tenerla.
RSpec.describe 'Api::Users::Permissions', type: :request do
  let(:admin)   { User.create!(email: 'admin@example.com', name: 'Administradora') }
  let(:target)  { User.create!(email: 'objetivo@example.com', name: 'Objetivo') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  let(:global)      { Permission.create!(name: 'Reports_Financial_View',  type: 'global') }
  let(:otro_global) { Permission.create!(name: 'Reports_Financial_Export', type: 'global') }
  let(:normal)      { Permission.create!(name: 'Sales_Documents_Create',   type: 'normal') }

  def sign_in_with(*permission_names, as: nil)
    actor = as || admin
    UserRole.create!(user: actor, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(actor, company: company)
  end

  def json_headers = { 'CONTENT_TYPE' => 'application/json' }
  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  describe 'GET /api/users/:user_id/permissions' do
    it 'devuelve los permisos globales asignados al usuario' do
      UserPermission.create!(user: target, permission: global)

      sign_in_with('Configurations_Permissions_GlobalAccess')
      get "/api/users/#{target.id}/permissions"

      expect(response).to have_http_status(:ok)
      expect(body_data.map { |p| p['Name'] }).to eq(['Reports_Financial_View'])
    end

    it 'devuelve la lista vacía cuando no tiene ninguno' do
      sign_in_with('Configurations_Permissions_GlobalAccess')
      get "/api/users/#{target.id}/permissions"

      expect(body_data).to eq([])
    end

    it 'responde 404 cuando el usuario no existe' do
      sign_in_with('Configurations_Permissions_GlobalAccess')
      get '/api/users/999999/permissions'

      expect(response).to have_http_status(:not_found)
    end

    it 'rechaza con 403 a quien no tiene Configurations_Permissions_GlobalAccess' do
      sign_in_with('Configurations_Permissions_Access')
      get "/api/users/#{target.id}/permissions"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PUT /api/users/:user_id/permissions' do
    it 'asigna el conjunto completo' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id, otro_global.id] }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.global_permissions.pluck(:id)).to contain_exactly(global.id, otro_global.id)
    end

    # PUT lleva el estado final: lo que no venga queda revocado.
    it 'revoca lo que no viene en el cuerpo' do
      UserPermission.create!(user: target, permission: global)
      UserPermission.create!(user: target, permission: otro_global)

      sign_in_with('Configurations_Permissions_GlobalAccess')
      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id] }.to_json, headers: json_headers

      expect(target.global_permissions.pluck(:id)).to eq([global.id])
    end

    it 'revoca todo con una lista vacía' do
      UserPermission.create!(user: target, permission: global)

      sign_in_with('Configurations_Permissions_GlobalAccess')
      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [] }.to_json, headers: json_headers

      expect(target.global_permissions).to be_empty
    end

    # El índice único no excluye a las filas inactivas: sin `unscoped` al
    # reasignar, volver a conceder un permiso revocado chocaría contra el índice.
    it 'reactiva la concesión revocada en vez de insertar otra fila' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id] }.to_json, headers: json_headers
      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [] }.to_json, headers: json_headers
      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id] }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(UserPermission.unscoped.where(user_id: target.id).count).to eq(1)
      expect(target.global_permissions.pluck(:id)).to eq([global.id])
    end

    # Esta es la restricción que mantiene acotada la vía directa: un permiso por
    # compañía se concede con un rol, nunca acá.
    it 'rechaza un permiso que no es global' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id, normal.id] }.to_json, headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include(normal.id.to_s)
      # Nada se guardó: el rechazo es de toda la petición, no parcial.
      expect(target.global_permissions).to be_empty
    end

    it 'rechaza un permiso inexistente' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [999_999] }.to_json, headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'escribe las columnas de auditoría aunque la inserción sea en lote' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id] }.to_json, headers: json_headers

      fila = UserPermission.find_by(user_id: target.id, permission_id: global.id)
      expect(fila.created_by).to eq('admin@example.com')
      expect(fila.updated_by).to eq('admin@example.com')
    end

    it 'rechaza con 403 a quien no tiene Configurations_Permissions_GlobalAccess' do
      sign_in_with('Configurations_Permissions_Access')

      put "/api/users/#{target.id}/permissions",
          params: { PermissionIds: [global.id] }.to_json, headers: json_headers

      expect(response).to have_http_status(:forbidden)
      expect(target.global_permissions).to be_empty
    end
  end

  # Lo que hace que la asignación signifique algo. Sin esto el endpoint guardaría
  # filas que nadie mira.
  describe 'efecto sobre la autorización' do
    it 'concede el permiso sin necesidad de un rol' do
      # `Configurations_Users_ViewAllApplicationUsers` amplía el alcance del
      # listado y se evalúa con `permission?`.
      alcance = Permission.create!(name: 'Configurations_Users_ViewAllApplicationUsers',
                                   type: 'global')
      otra    = Company.create!(name: 'Otra S.A.')
      ajeno   = User.create!(email: 'ajeno@example.com', name: 'Ajeno')
      UsersByCompany.create!(user: ajeno, company: otra)

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users'
      expect(body_data['Items'].map { |u| u['Email'] }).not_to include('ajeno@example.com')

      UserPermission.create!(user: admin, permission: alcance)

      get '/api/users'
      expect(body_data['Items'].map { |u| u['Email'] }).to include('ajeno@example.com')
    end

    it 'lo concede en cualquier compañía, no solo en la activa' do
      otra = Company.create!(name: 'Otra S.A.')
      UserPermission.create!(user: admin, permission: global)
      sign_in_with('Configurations_Permissions_GlobalAccess')

      # Se cambia la compañía de la sesión a una donde el usuario no tiene rol.
      post '/__test/session', params: { user_id: admin.id, company_id: otra.id }

      get '/api/permissions'
      expect(body_data.map { |p| p['Name'] }).to include('Reports_Financial_View')
    end

    it 'aparece en los permisos efectivos junto a los que vienen por rol' do
      UserPermission.create!(user: admin, permission: global)
      sign_in_with('Configurations_Permissions_GlobalAccess')

      get '/api/permissions'

      nombres = body_data.map { |p| p['Name'] }
      expect(nombres).to include('Reports_Financial_View', 'Configurations_Permissions_GlobalAccess')
      expect(nombres.uniq).to eq(nombres)
    end

    it 'deja de concederlo cuando se revoca' do
      concesion = UserPermission.create!(user: admin, permission: global)
      sign_in_with('Configurations_Permissions_GlobalAccess')

      concesion.soft_delete!

      get '/api/permissions'
      expect(body_data.map { |p| p['Name'] }).not_to include('Reports_Financial_View')
    end
  end

  describe 'GET /api/permissions/catalog?type=global' do
    it 'devuelve solo los permisos globales' do
      global
      normal
      sign_in_with('Configurations_Permissions_GlobalAccess')

      get '/api/permissions/catalog', params: { type: 'global' }

      expect(response).to have_http_status(:ok)
      nombres = body_data.map { |p| p['Name'] }
      expect(nombres).to include('Reports_Financial_View')
      expect(nombres).not_to include('Sales_Documents_Create')
    end

    # El catálogo global lo pide el panel de accesos por usuario, gateado con
    # GlobalAccess. Exigir el permiso de la pantalla de roles lo dejaría sin datos.
    it 'no exige Configurations_Permissions_Access para el catálogo global' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      get '/api/permissions/catalog', params: { type: 'global' }

      expect(response).to have_http_status(:ok)
    end

    it 'el catálogo completo sí lo exige' do
      sign_in_with('Configurations_Permissions_GlobalAccess')

      get '/api/permissions/catalog'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'modelo UserPermission' do
    it 'no acepta un permiso que no es global' do
      concesion = UserPermission.new(user: target, permission: normal)

      expect(concesion).not_to be_valid
      expect(concesion.errors.full_messages.first)
        .to eq('El permiso no es global: los permisos por compañía se conceden con un rol')
    end

    it 'no permite conceder dos veces el mismo permiso, ni con la concesión revocada' do
      UserPermission.create!(user: target, permission: global).soft_delete!

      repetida = UserPermission.new(user: target, permission: global)

      expect(repetida).not_to be_valid
      expect(repetida.errors.full_messages).to eq(['El permiso ya está en uso'])
    end
  end
end

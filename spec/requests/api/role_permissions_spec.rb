# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Roles::Permissions', type: :request do
  let(:user)    { User.create!(email: 'permisos@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:target)  { Role.create!(name: 'Ventas') }

  let(:leer)    { Permission.create!(name: 'Documents_Issued_Access',  description: 'Ver emitidos')   }
  let(:emitir)  { Permission.create!(name: 'Documents_Issued_Create',  description: 'Emitir')         }
  let(:anular)  { Permission.create!(name: 'Documents_Issued_Cancel',  description: 'Anular')         }

  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def assigned_ids = target.role_permissions.reload.pluck(:permission_id)

  describe 'GET /api/roles/:role_id/permissions' do
    it 'devuelve los permisos vigentes del rol' do
      RolePermission.create!(role: target, permission: leer)
      emitir # existe pero no está asignado

      sign_in_with('Configurations_Permissions_Access')
      get "/api/roles/#{target.id}/permissions"

      expect(response).to have_http_status(:ok)
      expect(body_data.map { |p| p['Id'] }).to eq([leer.id])
      expect(body_data.first).to include('Name' => 'Documents_Issued_Access', 'Description' => 'Ver emitidos')
    end

    it 'excluye las asignaciones revocadas (soft delete)' do
      RolePermission.create!(role: target, permission: leer).soft_delete!

      sign_in_with('Configurations_Permissions_Access')
      get "/api/roles/#{target.id}/permissions"

      expect(body_data).to be_empty
    end

    it 'responde 404 si el rol no existe' do
      sign_in_with('Configurations_Permissions_Access')
      get '/api/roles/999999/permissions'

      expect(response).to have_http_status(:not_found)
    end

    it 'responde 403 sin el permiso de asignación' do
      sign_in_with

      get "/api/roles/#{target.id}/permissions"

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 401 sin sesión' do
      get "/api/roles/#{target.id}/permissions"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'PUT /api/roles/:role_id/permissions' do
    it 'reemplaza el conjunto completo: agrega lo que entra y revoca lo que sale' do
      RolePermission.create!(role: target, permission: leer)
      sign_in_with('Configurations_Permissions_Access')

      put "/api/roles/#{target.id}/permissions",
          params: { PermissionIds: [emitir.id, anular.id] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(assigned_ids).to contain_exactly(emitir.id, anular.id)
    end

    it 'revoca todo cuando la lista viene vacía' do
      RolePermission.create!(role: target, permission: leer)
      sign_in_with('Configurations_Permissions_Access')

      put "/api/roles/#{target.id}/permissions", params: { PermissionIds: [] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(assigned_ids).to be_empty
    end

    # Revocar es soft delete: volver a conceder tiene que REACTIVAR la fila, no
    # insertar otra al lado dejando la vieja inactiva acumulándose.
    it 'reactiva la asignación revocada en vez de duplicar la fila' do
      revocada = RolePermission.create!(role: target, permission: leer)
      revocada.soft_delete!

      sign_in_with('Configurations_Permissions_Access')
      put "/api/roles/#{target.id}/permissions", params: { PermissionIds: [leer.id] }, as: :json

      expect(assigned_ids).to eq([leer.id])
      expect(RolePermission.unscoped.where(role_id: target.id, permission_id: leer.id).count).to eq(1)
      expect(revocada.reload).to be_is_active
    end

    it 'es idempotente: mandar dos veces la misma lista deja el rol igual' do
      sign_in_with('Configurations_Permissions_Access')

      2.times do
        put "/api/roles/#{target.id}/permissions", params: { PermissionIds: [leer.id] }, as: :json
      end

      expect(assigned_ids).to eq([leer.id])
      expect(RolePermission.unscoped.where(role_id: target.id).count).to eq(1)
    end

    it 'ignora ids repetidos en la petición' do
      sign_in_with('Configurations_Permissions_Access')

      put "/api/roles/#{target.id}/permissions",
          params: { PermissionIds: [leer.id, leer.id] }, as: :json

      expect(RolePermission.unscoped.where(role_id: target.id).count).to eq(1)
    end

    it 'rechaza ids de permisos inexistentes sin tocar nada' do
      RolePermission.create!(role: target, permission: leer)
      sign_in_with('Configurations_Permissions_Access')

      put "/api/roles/#{target.id}/permissions",
          params: { PermissionIds: [emitir.id, 999_999] }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('999999')
      expect(assigned_ids).to eq([leer.id])
    end

    it 'no toca los permisos de otro rol' do
      otro = Role.create!(name: 'Otro')
      RolePermission.create!(role: otro, permission: anular)

      sign_in_with('Configurations_Permissions_Access')
      put "/api/roles/#{target.id}/permissions", params: { PermissionIds: [leer.id] }, as: :json

      expect(otro.role_permissions.reload.pluck(:permission_id)).to eq([anular.id])
    end

    # La UI ya bloquea OWNER; el servidor lo bloquea de nuevo (§26).
    it 'se niega a reasignar los permisos del rol OWNER' do
      owner = Role.create!(name: 'OWNER')
      RolePermission.create!(role: owner, permission: leer)

      sign_in_with('Configurations_Permissions_Access')
      put "/api/roles/#{owner.id}/permissions", params: { PermissionIds: [] }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(owner.role_permissions.reload.pluck(:permission_id)).to eq([leer.id])
    end

    # §1.6 del estándar: reasignar N permisos no puede costar N escrituras. Se
    # cuentan las sentencias reales para que un refactor no reintroduzca el loop.
    it 'escribe en lote: el costo no crece con la cantidad de permisos' do
      catalogo = 15.times.map { |i| Permission.create!(name: "Bulk_Perm_#{i}") }
      sign_in_with('Configurations_Permissions_Access')
      target # `let` perezoso: se materializa acá para que su INSERT no cuente

      escrituras = []
      sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        escrituras << payload[:sql] if payload[:sql] =~ /\A\s*(INSERT|UPDATE)/i
      end

      put "/api/roles/#{target.id}/permissions",
          params: { PermissionIds: catalogo.map(&:id) }, as: :json

      ActiveSupport::Notifications.unsubscribe(sub)

      expect(response).to have_http_status(:ok)
      expect(assigned_ids.size).to eq(15)
      # Un solo INSERT en lote, sin UPDATE (no había nada que revocar ni reactivar).
      expect(escrituras.size).to eq(1)
      expect(escrituras.first).to match(/\AINSERT/i)
    end

    it 'devuelve el resultado ya aplicado' do
      sign_in_with('Configurations_Permissions_Access')

      put "/api/roles/#{target.id}/permissions",
          params: { PermissionIds: [emitir.id, leer.id] }, as: :json

      expect(body_data.map { |p| p['Id'] }).to contain_exactly(leer.id, emitir.id)
      expect(body['Message']).to be_present
    end

    it 'responde 403 sin el permiso de asignación' do
      RolePermission.create!(role: target, permission: leer)
      sign_in_with('Configurations_Security_Access') # el de roles no alcanza acá

      put "/api/roles/#{target.id}/permissions", params: { PermissionIds: [] }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(assigned_ids).to eq([leer.id])
    end
  end

  describe 'GET /api/permissions/catalog' do
    it 'devuelve el catálogo completo ordenado por nombre' do
      leer
      emitir

      sign_in_with('Configurations_Permissions_Access')
      get '/api/permissions/catalog'

      expect(response).to have_http_status(:ok)
      # Incluye también el permiso que sign_in_with creó para la sesión.
      expect(body_data.map { |p| p['Name'] }).to include('Documents_Issued_Access', 'Documents_Issued_Create')
      expect(body_data.map { |p| p['Name'] }).to eq(body_data.map { |p| p['Name'] }.sort)
    end

    it 'expone descripción y tipo, que es lo que pinta el panel' do
      leer

      sign_in_with('Configurations_Permissions_Access')
      get '/api/permissions/catalog'

      expect(body_data.find { |p| p['Id'] == leer.id })
        .to eq('Id' => leer.id, 'Name' => 'Documents_Issued_Access',
               'Description' => 'Ver emitidos', 'Type' => 'normal')
    end

    it 'responde 403 sin el permiso de asignación' do
      sign_in_with

      get '/api/permissions/catalog'

      expect(response).to have_http_status(:forbidden)
    end

    # No confundir con GET /api/permissions, que son los permisos EFECTIVOS del
    # usuario de la sesión: solo trae los concedidos, y solo el nombre.
    it 'no es lo mismo que GET /api/permissions' do
      leer

      sign_in_with('Configurations_Permissions_Access')

      get '/api/permissions'
      efectivos = body_data

      get '/api/permissions/catalog'
      catalogo = body_data

      # Efectivos: únicamente el permiso que tiene el usuario, y sin Id.
      expect(efectivos.map { |p| p['Name'] }).to eq(['Configurations_Permissions_Access'])
      expect(efectivos.first.keys).to contain_exactly('Name')

      # Catálogo: todos los que existen, con el registro completo.
      expect(catalogo.map { |p| p['Name'] }).to include('Documents_Issued_Access')
      expect(catalogo.first.keys).to contain_exactly('Id', 'Name', 'Description', 'Type')
    end
  end
end

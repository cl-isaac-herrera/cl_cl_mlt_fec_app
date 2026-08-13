# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Users', type: :request do
  let(:admin)   { User.create!(email: 'admin@example.com', name: 'Administradora') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  # Deja al usuario con los permisos indicados sobre `company` y abre la sesión
  # con esa compañía activa: require_permission! resuelve contra la de la sesión.
  def sign_in_with(*permission_names, as: nil, company: nil)
    actor = as || admin
    scope = company || self.company
    UserRole.create!(user: actor, role: role, company: scope)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(actor, company: scope)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  # Usuario visible desde `company`: la lista se limita a quienes están asignados
  # a la compañía activa.
  def create_member(email:, name: nil, company: nil, **attrs)
    user = User.create!(email: email, name: name, **attrs)
    UsersByCompany.create!(user: user, company: company || self.company)
    user
  end

  describe 'GET /api/users' do
    it 'lista los usuarios de la compañía activa con el total real, no el de la página' do
      3.times { |i| create_member(email: "u#{i}@example.com", name: "Usuario #{i}") }

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users', params: { page: 1, per_page: 2 }

      expect(response).to have_http_status(:ok)
      expect(body_data['Items'].size).to eq(2)
      # El total es de la consulta completa: es lo que el contador de Tabulator
      # necesita para no sobreestimar (CLAUDE.md §17).
      expect(body_data['Total']).to eq(3)
    end

    it 'devuelve la segunda página, no la primera otra vez' do
      %w[Ana Bruno Carla].each_with_index do |n, i|
        create_member(email: "#{n.downcase}@example.com", name: n)
      end

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users', params: { page: 2, per_page: 2 }

      expect(body_data['Items'].map { |u| u['FullName'] }).to eq(['Carla'])
    end

    it 'no deja ver a los usuarios de otra compañía' do
      otra = Company.create!(name: 'Otra S.A.')
      create_member(email: 'propio@example.com',  name: 'Propio')
      create_member(email: 'ajeno@example.com',   name: 'Ajeno', company: otra)

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users'

      expect(body_data['Items'].map { |u| u['Email'] }).to eq(['propio@example.com'])
    end

    it 'abarca todo el producto con Configurations_Users_ViewAllApplicationUsers' do
      otra = Company.create!(name: 'Otra S.A.')
      create_member(email: 'propio@example.com', name: 'Propio')
      create_member(email: 'ajeno@example.com',  name: 'Ajeno', company: otra)

      sign_in_with('Configurations_Users_ListAccess',
                   'Configurations_Users_ViewAllApplicationUsers')
      get '/api/users'

      expect(body_data['Items'].map { |u| u['Email'] }).to include('ajeno@example.com')
    end

    # El .NET lo pedía con `activeOnly=false`. Sin `unscoped`, el default_scope de
    # SoftDeletable los esconde y no habría forma de volver a activarlos.
    it 'incluye a los usuarios inactivos' do
      baja = create_member(email: 'baja@example.com', name: 'De baja')
      baja.update!(is_active: false)

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users'

      inactivo = body_data['Items'].find { |u| u['Email'] == 'baja@example.com' }
      expect(inactivo).to be_present
      expect(inactivo['Active']).to be(false)
    end

    # Mayúsculas ASCII a propósito: el LIKE de SQLite solo ignora la caja en ASCII,
    # así que `SOLÍ` NO encontraría a `Solís` (ver la nota del scope `search`).
    it 'filtra por nombre y por correo, sin distinguir mayúsculas' do
      create_member(email: 'ana.solis@example.com',  name: 'Ana Solis')
      create_member(email: 'bruno.mora@example.com', name: 'Bruno Mora')

      sign_in_with('Configurations_Users_ListAccess')

      get '/api/users', params: { name: 'SOLIS' }
      expect(body_data['Items'].map { |u| u['Email'] }).to eq(['ana.solis@example.com'])

      get '/api/users', params: { email: 'BRUNO' }
      expect(body_data['Items'].map { |u| u['Email'] }).to eq(['bruno.mora@example.com'])
    end

    it 'nunca expone la contraseña de SAP' do
      create_member(email: 'consap@example.com', name: 'Con SAP',
                    sap_user: 'manager', sap_password: 'secreta')

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users'

      expect(response.body).not_to include('secreta')
      expect(body_data['Items'].first.keys).not_to include('SapPass', 'SapPassword')
    end

    it 'rechaza con 403 a quien no tiene el permiso' do
      sign_in_with('Configurations_Users_Update') # otro permiso del mismo módulo
      get '/api/users'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /api/users/:id' do
    it 'devuelve el detalle del usuario' do
      target = create_member(email: 'detalle@example.com', name: 'Detalle', sap_user: 'manager')

      sign_in_with('Configurations_Users_ListAccess')
      get "/api/users/#{target.id}"

      expect(response).to have_http_status(:ok)
      expect(body_data).to include('FullName' => 'Detalle', 'SapUser' => 'manager')
    end

    it 'responde 404 cuando el usuario no existe' do
      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users/999999'

      expect(response).to have_http_status(:not_found)
    end

    # El permiso se resuelve antes de buscar: si no, un 404 le confirmaría a quien
    # no tiene permiso qué ids existen.
    it 'responde 403 y no 404 cuando falta el permiso, aunque el id no exista' do
      sign_in_with('Configurations_Users_Update')
      get '/api/users/999999'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /api/users' do
    before { UsersByCompany.create!(user: admin, company: company) }

    it 'crea el usuario activo y asignado a la compañía indicada' do
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'Nueva Persona', Email: 'nueva@example.com',
                                   CompanyId: company.id }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:created)
      created = User.find_by(email: 'nueva@example.com')
      # Activo a propósito: inactivo quedaría escondido por el default_scope y
      # desaparecería del listado apenas se guarda.
      expect(created.is_active).to be(true)
      expect(created.companies).to include(company)
    end

    it 'rechaza una compañía que no está asignada al administrador' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'X', Email: 'x@example.com',
                                   CompanyId: ajena.id }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(User.unscoped.find_by(email: 'x@example.com')).to be_nil
    end

    it 'rechaza un correo repetido con el mensaje traducido' do
      create_member(email: 'repetido@example.com')
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'Otra', Email: 'repetido@example.com',
                                   CompanyId: company.id }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El correo ya está en uso')
    end

    it 'rechaza un correo con formato inválido' do
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'Otra', Email: 'no-es-correo',
                                   CompanyId: company.id }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El correo no tiene un formato válido')
    end

    it 'rechaza con 403 a quien solo puede listar' do
      sign_in_with('Configurations_Users_ListAccess')

      post '/api/users', params: { FullName: 'X', Email: 'x@example.com',
                                   CompanyId: company.id }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/users/:id' do
    it 'actualiza el nombre y el usuario de SAP' do
      target = create_member(email: 'edit@example.com', name: 'Antes', sap_user: 'viejo')
      sign_in_with('Configurations_Users_Update')

      patch "/api/users/#{target.id}", params: { FullName: 'Después', SapUser: 'nuevo' }.to_json,
                                       headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(target.reload).to have_attributes(name: 'Después', sap_user: 'nuevo')
    end

    # El panel manda `SapPass: ''` cada vez que se guarda sin tocar la contraseña.
    # Si eso la borrara, editar el nombre dejaría al usuario sin poder entrar a SAP.
    it 'no borra la contraseña de SAP cuando llega en blanco' do
      target = create_member(email: 'pass@example.com', sap_password: 'secreta')
      sign_in_with('Configurations_Users_Update')

      patch "/api/users/#{target.id}", params: { FullName: 'Nombre', SapPass: '' }.to_json,
                                       headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(target.reload.sap_password).to eq('secreta')
    end

    it 'la reemplaza cuando llega con valor' do
      target = create_member(email: 'pass2@example.com', sap_password: 'vieja')
      sign_in_with('Configurations_Users_Update')

      patch "/api/users/#{target.id}", params: { SapPass: 'nueva' }.to_json,
                                       headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(target.reload.sap_password).to eq('nueva')
    end

    it 'desactiva y vuelve a activar al usuario' do
      target = create_member(email: 'toggle@example.com')
      sign_in_with('Configurations_Users_Update')

      patch "/api/users/#{target.id}", params: { Active: false }.to_json,
                                       headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(User.unscoped.find(target.id).is_active).to be(false)

      patch "/api/users/#{target.id}", params: { Active: true }.to_json,
                                       headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(User.unscoped.find(target.id).is_active).to be(true)
    end

    # `Identification`, `EmailConfirmed` y `Owner` no existen como columna: mandarlos
    # no puede tener efecto ni reventar la petición.
    it 'ignora los campos del .NET que ya no existen' do
      target = create_member(email: 'legacy@example.com', name: 'Legado')
      sign_in_with('Configurations_Users_Update')

      patch "/api/users/#{target.id}",
            params: { FullName: 'Legado', Identification: '1-2345-6789',
                      EmailConfirmed: true, Owner: true }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
    end

    it 'rechaza con 403 a quien solo puede listar' do
      target = create_member(email: 'nope@example.com')
      sign_in_with('Configurations_Users_ListAccess')

      patch "/api/users/#{target.id}", params: { FullName: 'X' }.to_json,
                                       headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /api/users/:user_id/companies' do
    it 'devuelve las compañías del usuario editado, no las del administrador' do
      otra   = Company.create!(name: 'Sucursal S.A.')
      target = create_member(email: 'multi@example.com')
      UsersByCompany.create!(user: target, company: otra)

      sign_in_with('Configurations_Users_Update')
      get "/api/users/#{target.id}/companies"

      expect(response).to have_http_status(:ok)
      expect(body_data.map { |c| c['Name'] }).to contain_exactly('ACME S.A.', 'Sucursal S.A.')
    end

    it 'rechaza con 403 a quien no puede editar usuarios' do
      target = create_member(email: 'x@example.com')
      sign_in_with('Configurations_Users_ListAccess')

      get "/api/users/#{target.id}/companies"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /api/users/:user_id/role' do
    it 'devuelve el rol del usuario en la compañía activa' do
      target = create_member(email: 'conrol@example.com')
      otro   = Role.create!(name: 'Operador')
      UserRole.create!(user: target, role: otro, company: company)

      sign_in_with('Configurations_Users_ManageAccess')
      get "/api/users/#{target.id}/role"

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq('RoleId' => otro.id, 'RoleName' => 'Operador')
    end

    it 'devuelve null cuando el usuario no tiene rol en esa compañía' do
      target = create_member(email: 'sinrol@example.com')

      sign_in_with('Configurations_Users_ManageAccess')
      get "/api/users/#{target.id}/role"

      expect(body_data).to be_nil
    end

    # La compañía sale de la sesión: el rol que tenga en otra no se ve ni se pisa.
    it 'no devuelve el rol que el usuario tiene en otra compañía' do
      otra   = Company.create!(name: 'Otra S.A.')
      target = create_member(email: 'otracia@example.com')
      UserRole.create!(user: target, role: Role.create!(name: 'Ajeno'), company: otra)

      sign_in_with('Configurations_Users_ManageAccess')
      get "/api/users/#{target.id}/role"

      expect(body_data).to be_nil
    end
  end

  describe 'PUT /api/users/:user_id/role' do
    let(:operador) { Role.create!(name: 'Operador') }

    it 'asigna el rol en la compañía activa' do
      target = create_member(email: 'asignar@example.com')
      sign_in_with('Configurations_Users_ManageAccess')

      put "/api/users/#{target.id}/role", params: { RoleId: operador.id }.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(UserRole.find_by(user_id: target.id, company_id: company.id).role_id).to eq(operador.id)
    end

    it 'reemplaza el rol anterior en vez de acumular asignaciones' do
      target  = create_member(email: 'reemplazo@example.com')
      anterior = Role.create!(name: 'Anterior')
      UserRole.create!(user: target, role: anterior, company: company)

      sign_in_with('Configurations_Users_ManageAccess')
      put "/api/users/#{target.id}/role", params: { RoleId: operador.id }.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json' }

      vigentes = UserRole.where(user_id: target.id, company_id: company.id)
      expect(vigentes.pluck(:role_id)).to eq([operador.id])
    end

    # Sin `unscoped` al reasignar, volver a un rol ya revocado insertaría una fila
    # nueva al lado de la vieja y `user_roles` acumularía basura.
    it 'reactiva la asignación revocada en vez de insertar otra' do
      target = create_member(email: 'idayvuelta@example.com')
      sign_in_with('Configurations_Users_ManageAccess')

      headers = { 'CONTENT_TYPE' => 'application/json' }
      put "/api/users/#{target.id}/role", params: { RoleId: operador.id }.to_json, headers: headers
      put "/api/users/#{target.id}/role", params: { RoleId: role.id }.to_json,     headers: headers
      put "/api/users/#{target.id}/role", params: { RoleId: operador.id }.to_json, headers: headers

      filas = UserRole.unscoped.where(user_id: target.id, company_id: company.id)
      expect(filas.count).to eq(2)
      expect(filas.where(is_active: true).pluck(:role_id)).to eq([operador.id])
    end

    it 'no toca el rol que el usuario tiene en otra compañía' do
      otra   = Company.create!(name: 'Otra S.A.')
      target = create_member(email: 'aislada@example.com')
      ajeno  = Role.create!(name: 'Ajeno')
      UserRole.create!(user: target, role: ajeno, company: otra)

      sign_in_with('Configurations_Users_ManageAccess')
      put "/api/users/#{target.id}/role", params: { RoleId: operador.id }.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(UserRole.find_by(user_id: target.id, company_id: otra.id).role_id).to eq(ajeno.id)
    end

    it 'rechaza un rol inexistente' do
      target = create_member(email: 'rolfantasma@example.com')
      sign_in_with('Configurations_Users_ManageAccess')

      put "/api/users/#{target.id}/role", params: { RoleId: 999_999 }.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El rol no existe.')
    end

    it 'rechaza con 403 a quien no puede gestionar accesos' do
      target = create_member(email: 'sinpermiso@example.com')
      sign_in_with('Configurations_Users_ListAccess')

      put "/api/users/#{target.id}/role", params: { RoleId: operador.id }.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:forbidden)
    end
  end
end

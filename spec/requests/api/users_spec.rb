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
    grant_permissions(actor, *permission_names, company: scope)
    sign_in(actor, company: scope)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  # Da de alta un usuario con acceso a una compañía. Administrar usuarios es un
  # permiso de INSTALACIÓN (docs/PLAN-ROLES-POR-ALCANCE.md): la lista siempre
  # muestra a todos, sin importar a qué compañía esté asignado cada uno.
  def create_member(email:, name: nil, company: nil, **attrs)
    user = User.create!(email: email, name: name, **attrs)
    UsersByCompany.create!(user: user, company: company || self.company, role: role)
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
      # necesita para no sobreestimar (CLAUDE.md §17). Incluye también a `admin`
      # (la lista es de TODA la instalación, sin importar la compañía activa).
      expect(body_data['Total']).to eq(4)
    end

    it 'devuelve la segunda página, no la primera otra vez' do
      %w[Ana Bruno Carla].each_with_index do |n, i|
        create_member(email: "#{n.downcase}@example.com", name: n)
      end

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users', params: { page: 2, per_page: 2 }

      # Orden alfabético por nombre: Administradora, Ana, Bruno, Carla — la
      # página 2 (de a 2) trae Bruno y Carla.
      expect(body_data['Items'].map { |u| u['FullName'] }).to eq(%w[Bruno Carla])
    end

    # Administrar usuarios es un permiso de INSTALACIÓN, no de compañía
    # (docs/PLAN-ROLES-POR-ALCANCE.md): quien entra a esta pantalla ve a TODOS
    # los usuarios del producto, sin importar cuál sea la compañía activa ni a
    # qué compañía esté asignado cada uno.
    it 'muestra usuarios de cualquier compañía, no solo la activa' do
      otra = Company.create!(name: 'Otra S.A.')
      create_member(email: 'propio@example.com', name: 'Propio')
      create_member(email: 'ajeno@example.com',  name: 'Ajeno', company: otra)

      sign_in_with('Configurations_Users_ListAccess')
      get '/api/users'

      expect(body_data['Items'].map { |u| u['Email'] }).to include('propio@example.com', 'ajeno@example.com')
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
    # Ya no exige `CompanyId` (docs/PLAN-ROLES-POR-ALCANCE.md): el usuario nace
    # sin ninguna compañía asignada, y el acceso se reparte después desde el
    # panel "Gestionar accesos" (`PUT /api/users/:id/companies`).
    it 'crea el usuario activo y sin ninguna compañía asignada todavía' do
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'Nueva Persona', Email: 'nueva@example.com' }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:created)
      created = User.find_by(email: 'nueva@example.com')
      # Activo a propósito: inactivo quedaría escondido por el default_scope y
      # desaparecería del listado apenas se guarda.
      expect(created.is_active).to be(true)
      expect(created.companies).to be_empty
    end

    it 'rechaza un correo repetido con el mensaje traducido' do
      create_member(email: 'repetido@example.com')
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'Otra', Email: 'repetido@example.com' }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El correo ya está en uso')
    end

    it 'rechaza un correo con formato inválido' do
      sign_in_with('Configurations_Users_Create')

      post '/api/users', params: { FullName: 'Otra', Email: 'no-es-correo' }.to_json,
                         headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El correo no tiene un formato válido')
    end

    it 'rechaza con 403 a quien solo puede listar' do
      sign_in_with('Configurations_Users_ListAccess')

      post '/api/users', params: { FullName: 'X', Email: 'x@example.com' }.to_json,
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
      UsersByCompany.create!(user: target, company: otra, role: role)

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

  # El rol de COMPAÑÍA por usuario se prueba en user_companies_spec.rb (vive en
  # `users_by_companies.role_id`). El de INSTALACIÓN tiene su propio spec,
  # spec/requests/api/user_installation_role_spec.rb.
end

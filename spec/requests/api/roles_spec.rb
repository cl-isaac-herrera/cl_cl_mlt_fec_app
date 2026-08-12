# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Roles', type: :request do
  let(:user)    { User.create!(email: 'seguridad@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  # Deja al usuario con los permisos indicados sobre `company` y abre la sesión
  # con esa compañía activa: require_permission! resuelve contra la de la sesión.
  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  describe 'GET /api/roles' do
    it 'lista los roles ordenados por nombre' do
      Role.create!(name: 'Ventas')
      Role.create!(name: 'Auditoría')

      sign_in_with('Configurations_Security_Access')
      get '/api/roles'

      expect(response).to have_http_status(:ok)
      expect(body_data.map { |r| r['Name'] }).to eq(%w[Auditoría Configurador Ventas])
    end

    # En el esquema propio `roles` no tiene company_id (§4.1): un rol existe para
    # todo el producto y la compañía vive en `user_roles`. El .NET filtraba por
    # compañía; esta es la diferencia de comportamiento más visible de la migración.
    it 'devuelve todos los roles, no solo los de la compañía activa' do
      otra = Company.create!(name: 'Otra S.A.')
      solo_otra = Role.create!(name: 'Solo en otra')
      UserRole.create!(user: user, role: solo_otra, company: otra)

      sign_in_with('Configurations_Security_Access')
      get '/api/roles'

      expect(body_data.map { |r| r['Name'] }).to include('Solo en otra')
    end

    it 'omite los roles desactivados (soft delete)' do
      Role.create!(name: 'Dado de baja').soft_delete!

      sign_in_with('Configurations_Security_Access')
      get '/api/roles'

      expect(body_data.map { |r| r['Name'] }).not_to include('Dado de baja')
    end

    it 'expone el contrato ApiResponse con Active mapeando is_active' do
      sign_in_with('Configurations_Security_Access')
      get '/api/roles'

      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body_data.first).to include('Id' => role.id, 'Name' => 'Configurador', 'Active' => true)
    end

    it 'responde 403 sin el permiso de seguridad' do
      sign_in_with

      get '/api/roles'

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 401 sin sesión' do
      get '/api/roles'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/roles' do
    it 'crea el rol activo' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Supervisor' }, as: :json

      expect(response).to have_http_status(:created)
      expect(Role.find_by(name: 'Supervisor')).to have_attributes(is_active: true)
    end

    # El .NET mandaba { role: { Name: ... }, companyId: N }. Se acepta esa forma
    # para no romper si algo viejo la manda, pero companyId se ignora.
    it 'acepta el nombre anidado como lo mandaba el .NET' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { role: { Name: 'Anidado' }, companyId: 99 }, as: :json

      expect(response).to have_http_status(:created)
      expect(Role.find_by(name: 'Anidado')).to be_present
    end

    # El mensaje se compara literal a propósito: `default_locale = :es` sin
    # config/locales devolvía el bloque "Translation missing..." al usuario, y un
    # `be_present` pelado no lo detecta.
    it 'rechaza un nombre vacío con un mensaje en español' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: '   ' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre no puede estar en blanco')
    end

    it 'rechaza un nombre repetido' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Configurador' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre ya está en uso')
    end

    it 'registra quién lo creó' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Auditado' }, as: :json

      expect(Role.find_by(name: 'Auditado').created_by).to eq(user.email)
    end

    it 'responde 403 sin permiso' do
      sign_in_with

      post '/api/roles', params: { Name: 'Supervisor' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Role.find_by(name: 'Supervisor')).to be_nil
    end
  end

  describe 'PATCH /api/roles/:id' do
    it 'renombra el rol del path' do
      objetivo = Role.create!(name: 'Viejo')
      sign_in_with('Configurations_Security_Access')

      patch "/api/roles/#{objetivo.id}", params: { Name: 'Nuevo' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(objetivo.reload.name).to eq('Nuevo')
    end

    # El .NET mandaba el id dentro del cuerpo; acá manda el del path.
    it 'ignora el Id que venga en el cuerpo' do
      objetivo = Role.create!(name: 'Objetivo')
      ajeno    = Role.create!(name: 'Ajeno')

      sign_in_with('Configurations_Security_Access')
      patch "/api/roles/#{objetivo.id}", params: { Id: ajeno.id, Name: 'Modificado' }, as: :json

      expect(objetivo.reload.name).to eq('Modificado')
      expect(ajeno.reload.name).to eq('Ajeno')
    end

    # La UI ya bloquea OWNER; el servidor lo bloquea de nuevo porque la UI se
    # puede manipular (§26 — defensa en profundidad).
    it 'se niega a renombrar el rol OWNER aunque la UI lo permitiera' do
      owner = Role.create!(name: 'OWNER')
      sign_in_with('Configurations_Security_Access')

      patch "/api/roles/#{owner.id}", params: { Name: 'Secuestrado' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(owner.reload.name).to eq('OWNER')
    end

    it 'responde 404 si no existe' do
      sign_in_with('Configurations_Security_Access')
      patch '/api/roles/999999', params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    # El 403 tiene que ganarle al 404: si no, la respuesta le confirma a quien no
    # tiene permiso qué ids existen.
    it 'responde 403 —y no 404— sin permiso, aunque el id no exista' do
      sign_in_with

      patch '/api/roles/999999', params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end

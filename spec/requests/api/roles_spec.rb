# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Roles', type: :request do
  let(:user)    { User.create!(email: 'seguridad@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  # `Configurations_Security_Access` es de alcance `installation`
  # (docs/PLAN-ROLES-POR-ALCANCE.md): no depende de ninguna compañía activa, así
  # que `grant_permissions` no necesita `company:` para concederlo.
  def sign_in_with(*permission_names)
    grant_permissions(user, *permission_names)
    sign_in(user)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  describe 'GET /api/roles' do
    it 'lista los roles de compañía ordenados por nombre, filtrados por scope' do
      role # el rol de compañía "Configurador" del `let`, además de los dos de acá
      Role.create!(name: 'Ventas')
      Role.create!(name: 'Auditoría')

      sign_in_with('Configurations_Security_Access')
      get '/api/roles', params: { scope: 'company' }

      expect(response).to have_http_status(:ok)
      expect(body_data.map { |r| r['Name'] }).to eq(%w[Auditoría Configurador Ventas])
    end

    it 'sin scope devuelve los de los dos alcances' do
      role # el rol de compañía "Configurador" del `let`
      instalacion = Role.create!(name: 'Soporte', scope: 'installation')

      sign_in_with('Configurations_Security_Access')
      get '/api/roles'

      expect(body_data.map { |r| r['Name'] }).to include('Configurador', 'Soporte')
      expect(body_data.find { |r| r['Name'] == 'Soporte' }['Scope']).to eq('installation')
      expect(body_data.find { |r| r['Name'] == instalacion.name }).to be_present
    end

    it 'con scope=installation devuelve solo los de instalación' do
      role # el rol de compañía "Configurador" del `let` — no debe aparecer acá
      Role.create!(name: 'Soporte', scope: 'installation')

      sign_in_with('Configurations_Security_Access')
      get '/api/roles', params: { scope: 'installation' }

      expect(body_data.map { |r| r['Name'] }).to include('Soporte')
      expect(body_data.map { |r| r['Name'] }).not_to include('Configurador')
    end

    # En el esquema propio `roles` no tiene company_id (§4.1): un rol existe para
    # todo el producto y la compañía vive en la asignación (`users_by_companies`).
    # El .NET filtraba por compañía; esta es la diferencia de comportamiento más
    # visible de la migración.
    it 'devuelve todos los roles de compañía, no solo los de la compañía activa' do
      otra = Company.create!(name: 'Otra S.A.')
      solo_otra = Role.create!(name: 'Solo en otra')
      UsersByCompany.create!(user: user, company: otra, role: solo_otra)

      sign_in_with('Configurations_Security_Access')
      get '/api/roles', params: { scope: 'company' }

      expect(body_data.map { |r| r['Name'] }).to include('Solo en otra')
    end

    it 'omite los roles desactivados (soft delete)' do
      Role.create!(name: 'Dado de baja').soft_delete!

      sign_in_with('Configurations_Security_Access')
      get '/api/roles', params: { scope: 'company' }

      expect(body_data.map { |r| r['Name'] }).not_to include('Dado de baja')
    end

    it 'expone el contrato ApiResponse con Active y Scope' do
      role # el rol de compañía "Configurador" del `let`
      sign_in_with('Configurations_Security_Access')
      get '/api/roles', params: { scope: 'company' }

      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body_data.first).to include('Id' => role.id, 'Name' => 'Configurador', 'Active' => true,
                                         'Scope' => 'company')
    end

    it 'responde 403 sin el permiso de seguridad' do
      sign_in(user)

      get '/api/roles'

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 401 sin sesión' do
      get '/api/roles'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/roles' do
    it 'crea el rol de compañía activo' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Supervisor', Scope: 'company' }, as: :json

      expect(response).to have_http_status(:created)
      expect(Role.find_by(name: 'Supervisor', scope: 'company')).to have_attributes(is_active: true)
    end

    it 'crea el rol de instalación activo' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Soporte', Scope: 'installation' }, as: :json

      expect(response).to have_http_status(:created)
      expect(Role.find_by(name: 'Soporte', scope: 'installation')).to have_attributes(is_active: true)
    end

    it 'rechaza un Scope inválido' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Sin scope' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(Role.find_by(name: 'Sin scope')).to be_nil
    end

    # El .NET mandaba { role: { Name: ... }, companyId: N }. Se acepta esa forma
    # para no romper si algo viejo la manda, pero companyId se ignora.
    it 'acepta el nombre anidado como lo mandaba el .NET' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { role: { Name: 'Anidado' }, companyId: 99, Scope: 'company' }, as: :json

      expect(response).to have_http_status(:created)
      expect(Role.find_by(name: 'Anidado')).to be_present
    end

    # El mensaje se compara literal a propósito: `default_locale = :es` sin
    # config/locales devolvía el bloque "Translation missing..." al usuario, y un
    # `be_present` pelado no lo detecta.
    it 'rechaza un nombre vacío con un mensaje en español' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: '   ', Scope: 'company' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre no puede estar en blanco')
    end

    it 'rechaza un nombre repetido en el mismo alcance' do
      role # el rol de compañía "Configurador" del `let`, ya existente
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Configurador', Scope: 'company' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El nombre ya está en uso')
    end

    it 'permite el mismo nombre en el otro alcance' do
      role # el de compañía "Configurador" ya existe
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Configurador', Scope: 'installation' }, as: :json

      expect(response).to have_http_status(:created)
    end

    it 'registra quién lo creó' do
      sign_in_with('Configurations_Security_Access')

      post '/api/roles', params: { Name: 'Auditado', Scope: 'company' }, as: :json

      expect(Role.find_by(name: 'Auditado').created_by).to eq(user.email)
    end

    it 'responde 403 sin permiso' do
      sign_in(user)

      post '/api/roles', params: { Name: 'Supervisor', Scope: 'company' }, as: :json

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
      sign_in(user)

      patch '/api/roles/999999', params: { Name: 'X' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end

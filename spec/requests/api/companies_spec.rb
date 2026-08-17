# frozen_string_literal: true

require 'rails_helper'

# Listado de administración de compañías (/configurations/companies). No confundir
# con `GET /api/profile/companies`, que son las del usuario de la sesión.
RSpec.describe 'GET /api/companies', type: :request do
  let(:user)  { User.create!(email: 'admin@example.com') }
  let(:role)  { Role.create!(name: 'Configurador') }
  let(:sap)   { Connection.create!(name: 'SAP Producción', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme)  { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME') }

  # Deja al usuario con los permisos indicados sobre `acme` y abre la sesión con
  # esa compañía activa: require_permission! resuelve contra la de la sesión.
  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  it 'exige Configurations_Companies_ListAccess' do
    sign_in_with

    get '/api/companies'

    expect(response).to have_http_status(:forbidden)
  end

  it 'responde 401 sin sesión' do
    get '/api/companies'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'respeta el contrato ApiResponse' do
    sign_in_with('Configurations_Companies_ListAccess')

    get '/api/companies'

    expect(response).to have_http_status(:ok)
    expect(body.keys).to include('Data', 'Code', 'Message')
    expect(body['Code']).to eq(200)
  end

  # Solo lo que pinta la tabla: nombre, estado y el id para las acciones. El
  # nombre legal, el comercial y la identificación viven en SAP, no acá.
  it 'expone únicamente el id, el nombre y el estado' do
    sign_in_with('Configurations_Companies_ListAccess')

    get '/api/companies'

    expect(body_data['Items'].first).to eq(
      'Id' => acme.id, 'Name' => 'ACME S.A.', 'Active' => true
    )
  end

  describe 'alcance' do
    it 'devuelve solo las compañías asignadas al usuario' do
      Company.create!(name: 'Ajena S.A.')   # existe pero no está asignada
      sign_in_with('Configurations_Companies_ListAccess')

      get '/api/companies'

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.'])
    end

    it 'devuelve todas con Configurations_Companies_ViewAllApplicationCompanies' do
      Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_ListAccess',
                   'Configurations_Companies_ViewAllApplicationCompanies')

      get '/api/companies'

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.', 'Ajena S.A.'])
    end

    # Es una pantalla de administración: tiene que poder ver las dadas de baja
    # para reactivarlas (CLAUDE.md §28).
    it 'incluye las compañías inactivas' do
      inactiva = Company.create!(name: 'Cerrada S.A.')
      UsersByCompany.create!(user: user, company: inactiva)
      inactiva.soft_delete!
      sign_in_with('Configurations_Companies_ListAccess')

      get '/api/companies'

      expect(body_data['Items'].map { |c| c.values_at('Name', 'Active') })
        .to contain_exactly(['ACME S.A.', true], ['Cerrada S.A.', false])
    end
  end

  describe 'paginación' do
    before do
      %w[Alfa Beta Gamma].each do |n|
        UsersByCompany.create!(user: user, company: Company.create!(name: n))
      end
      sign_in_with('Configurations_Companies_ListAccess')
    end

    it 'devuelve el total real de la consulta, no el de la página' do
      get '/api/companies', params: { page: 1, per_page: 2 }

      expect(body_data['Items'].size).to eq(2)
      # Lo que el contador de Tabulator necesita para no sobreestimar (§17).
      expect(body_data['Total']).to eq(4)
    end

    it 'devuelve la segunda página, no la primera otra vez' do
      get '/api/companies', params: { page: 2, per_page: 2 }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['Beta', 'Gamma'])
    end

    it 'cae a la primera página con un número inválido' do
      get '/api/companies', params: { page: 0, per_page: 2 }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['ACME S.A.', 'Alfa'])
    end

    it 'topa el tamaño de página para que nadie pida la tabla entera' do
      get '/api/companies', params: { per_page: 10_000 }

      expect(body_data['Items'].size).to eq(4)
    end
  end

  describe 'filtro por nombre' do
    before do
      UsersByCompany.create!(user: user, company: Company.create!(name: 'Beta Industrial'))
      sign_in_with('Configurations_Companies_ListAccess')
    end

    it 'filtra como "contiene", sin distinguir mayúsculas' do
      get '/api/companies', params: { name: 'beta' }

      expect(body_data['Items'].map { |c| c['Name'] }).to eq(['Beta Industrial'])
      expect(body_data['Total']).to eq(1)
    end

    it 'en blanco no filtra nada' do
      get '/api/companies', params: { name: '  ' }

      expect(body_data['Total']).to eq(2)
    end
  end
end

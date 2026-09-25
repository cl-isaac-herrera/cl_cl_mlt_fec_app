# frozen_string_literal: true

require 'rails_helper'

# Asignación de compañías a un usuario, CON el rol de compañía en cada una
# (tab "Compañías" del panel "Gestionar accesos" de /configurations/users —
# docs/PLAN-ROLES-POR-ALCANCE.md: `UsersByCompany` da el acceso y el rol a la
# vez). Un error acá le abre o le cierra el acceso a datos de una compañía
# entera, o le deja el permiso equivocado dentro de ella.
RSpec.describe 'Api::Users::Companies', type: :request do
  let(:admin)      { User.create!(email: 'admin@example.com', name: 'Administradora') }
  let(:target)     { User.create!(email: 'objetivo@example.com', name: 'Objetivo') }
  let(:acme)       { Company.create!(name: 'ACME S.A.') }
  let(:beta)       { Company.create!(name: 'Beta S.A.') }
  let(:role)       { Role.create!(name: 'Configurador') }
  let(:otro_role)  { Role.create!(name: 'Operador') }

  def sign_in_with(*permission_names)
    grant_permissions(admin, *permission_names, company: acme)
    sign_in(admin, company: acme)
  end

  # El alcance por defecto son las compañías del propio administrador: nadie
  # reparte accesos donde él mismo no llega.
  def admin_reaches(*companies)
    companies.each { |c| UsersByCompany.create!(user: admin, company: c, role: role) }
  end

  def assignments(*companies)
    companies.map { |c| { CompanyId: c.id, RoleId: role.id } }
  end

  def json_headers = { 'CONTENT_TYPE' => 'application/json' }
  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  describe 'GET /api/users/:user_id/companies' do
    it 'devuelve las compañías asignadas al usuario, con su rol en cada una' do
      UsersByCompany.create!(user: target, company: acme, role: role)

      sign_in_with('Configurations_Users_CompanyAssignment')
      get "/api/users/#{target.id}/companies"

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq(
        [{ 'Id' => acme.id, 'Name' => 'ACME S.A.', 'RoleId' => role.id, 'RoleName' => role.name }]
      )
    end

    # El mismo endpoint sirve al panel de edición (selector para probar
    # credenciales) y al tab de asignación: cualquiera de los dos permisos alcanza.
    it 'lo puede leer quien edita usuarios, sin el permiso de asignación' do
      UsersByCompany.create!(user: target, company: acme, role: role)

      sign_in_with('Configurations_Users_Update')
      get "/api/users/#{target.id}/companies"

      expect(response).to have_http_status(:ok)
    end

    it 'rechaza con 403 a quien no tiene ninguno de los dos' do
      sign_in_with('Configurations_Users_ListAccess')
      get "/api/users/#{target.id}/companies"

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 404 cuando el usuario no existe' do
      sign_in_with('Configurations_Users_CompanyAssignment')
      get '/api/users/999999/companies'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PUT /api/users/:user_id/companies' do
    it 'asigna el conjunto completo, con el rol de cada fila' do
      admin_reaches(acme, beta)
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme, beta) }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.companies.pluck(:id)).to contain_exactly(acme.id, beta.id)
      expect(UsersByCompany.where(user_id: target.id).pluck(:role_id).uniq).to eq([role.id])
    end

    # PUT lleva el estado final: lo que no venga queda desasignado. Es lo que
    # reemplaza al par bulk-assign / bulk-unassign del .NET.
    it 'desasigna lo que no viene en el cuerpo' do
      admin_reaches(acme, beta)
      UsersByCompany.create!(user: target, company: acme, role: role)
      UsersByCompany.create!(user: target, company: beta, role: role)

      sign_in_with('Configurations_Users_CompanyAssignment')
      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(beta) }.to_json, headers: json_headers

      expect(target.companies.pluck(:id)).to eq([beta.id])
    end

    it 'desasigna todo con una lista vacía' do
      admin_reaches(acme)
      UsersByCompany.create!(user: target, company: acme, role: role)

      sign_in_with('Configurations_Users_CompanyAssignment')
      put "/api/users/#{target.id}/companies",
          params: { Assignments: [] }.to_json, headers: json_headers

      expect(target.companies).to be_empty
    end

    it 'cambia el rol de una compañía que ya tenía, sin desasignarla' do
      admin_reaches(acme)
      UsersByCompany.create!(user: target, company: acme, role: role)

      sign_in_with('Configurations_Users_CompanyAssignment')
      put "/api/users/#{target.id}/companies",
          params: { Assignments: [{ CompanyId: acme.id, RoleId: otro_role.id }] }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(UsersByCompany.find_by(user_id: target.id, company_id: acme.id).role_id).to eq(otro_role.id)
    end

    it 'rechaza una asignación sin RoleId' do
      admin_reaches(acme)
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: [{ CompanyId: acme.id }] }.to_json, headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(target.companies).to be_empty
    end

    it 'rechaza un RoleId que no es un rol de compañía' do
      admin_reaches(acme)
      instalacion = Role.create!(name: 'Instalación', scope: 'installation')
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: [{ CompanyId: acme.id, RoleId: instalacion.id }] }.to_json, headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(target.companies).to be_empty
    end

    # ── Alcance ────────────────────────────────────────────────────────────────
    #
    # El administrador solo reparte accesos a compañías que él alcanza, igual que
    # ya validaba POST /api/users. Sin esto, crear un usuario en una compañía
    # ajena estaba prohibido pero asignárselo dos clics después, permitido.
    it 'rechaza asignar una compañía fuera del alcance del administrador' do
      admin_reaches(acme)
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme, beta) }.to_json, headers: json_headers

      expect(response).to have_http_status(:forbidden)
      expect(body['Message']).to include(beta.id.to_s)
      # Rechazo total, no parcial: `acme` tampoco se aplicó.
      expect(target.companies).to be_empty
    end

    # ⚠️ El caso que hace peligroso el reemplazo completo. La compañía que el
    # administrador no administra nunca aparece en el panel, así que no viaja en
    # `Assignments` — si el reemplazo la revocara, le sacaría al usuario el acceso
    # a otra sociedad sin que nadie se entere.
    it 'NO revoca las compañías que el administrador no administra' do
      admin_reaches(acme)
      UsersByCompany.create!(user: target, company: acme, role: role)
      UsersByCompany.create!(user: target, company: beta, role: role) # fuera del alcance

      sign_in_with('Configurations_Users_CompanyAssignment')
      put "/api/users/#{target.id}/companies",
          params: { Assignments: [] }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.companies.reload.pluck(:id)).to eq([beta.id])
    end

    it 'con Configurations_Companies_ViewAllApplicationCompanies alcanza a todas' do
      sign_in_with('Configurations_Users_CompanyAssignment', 'Configurations_Companies_ViewAllApplicationCompanies')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme, beta) }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(target.companies.pluck(:id)).to contain_exactly(acme.id, beta.id)
    end

    it 'y entonces sí puede revocar cualquiera' do
      UsersByCompany.create!(user: target, company: beta, role: role)
      sign_in_with('Configurations_Users_CompanyAssignment', 'Configurations_Companies_ViewAllApplicationCompanies')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: [] }.to_json, headers: json_headers

      expect(target.companies.reload).to be_empty
    end

    # El índice único de `users_by_companies` NO excluye a las filas inactivas:
    # sin `unscoped` al reasignar, volver a asignar una compañía desasignada
    # chocaría contra el índice en vez de reactivar la fila que ya está.
    it 'reactiva la asignación revocada en vez de insertar otra fila' do
      admin_reaches(acme)
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme) }.to_json, headers: json_headers
      put "/api/users/#{target.id}/companies",
          params: { Assignments: [] }.to_json, headers: json_headers
      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme) }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(UsersByCompany.unscoped.where(user_id: target.id).count).to eq(1)
      expect(target.companies.pluck(:id)).to eq([acme.id])
    end

    it 'rechaza una compañía inexistente sin aplicar nada' do
      admin_reaches(acme)
      UsersByCompany.create!(user: target, company: acme, role: role)
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme) + [{ CompanyId: 999_999, RoleId: role.id }] }.to_json,
          headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(target.companies.reload.pluck(:id)).to eq([acme.id])
    end

    it 'escribe las columnas de auditoría aunque la inserción sea en lote' do
      admin_reaches(acme)
      sign_in_with('Configurations_Users_CompanyAssignment')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme) }.to_json, headers: json_headers

      fila = UsersByCompany.find_by(user_id: target.id, company_id: acme.id)
      expect(fila.created_by).to eq('admin@example.com')
      expect(fila.updated_by).to eq('admin@example.com')
    end

    it 'rechaza con 403 a quien solo puede editar usuarios' do
      admin_reaches(acme)
      sign_in_with('Configurations_Users_Update')

      put "/api/users/#{target.id}/companies",
          params: { Assignments: assignments(acme) }.to_json, headers: json_headers

      expect(response).to have_http_status(:forbidden)
      expect(target.companies).to be_empty
    end
  end

  describe 'GET /api/companies/assignable' do
    # El catálogo tiene que resolver EXACTAMENTE el mismo conjunto que valida el
    # PUT: si mostrara de más, el panel ofrecería una compañía que el guardado
    # después rechaza con 403.
    it 'devuelve solo las compañías del solicitante' do
      admin_reaches(acme)
      beta
      sign_in_with('Configurations_Users_CompanyAssignment')

      get '/api/companies/assignable'

      expect(response).to have_http_status(:ok)
      expect(body_data.map { |c| c['Name'] }).to eq(['ACME S.A.'])
    end

    it 'devuelve todas con Configurations_Companies_ViewAllApplicationCompanies' do
      beta
      sign_in_with('Configurations_Users_CompanyAssignment', 'Configurations_Companies_ViewAllApplicationCompanies')

      get '/api/companies/assignable'

      expect(body_data.map { |c| c['Name'] }).to contain_exactly('ACME S.A.', 'Beta S.A.')
    end

    it 'rechaza con 403 a quien no puede asignar' do
      sign_in_with('Configurations_Users_ListAccess')
      get '/api/companies/assignable'

      expect(response).to have_http_status(:forbidden)
    end

    # Las compañías del propio usuario son otro conjunto y viven en otra ruta:
    # el permiso de asignación no las amplía ni las restringe.
    it 'no afecta a GET /api/profile/companies, que no lleva permiso' do
      beta
      admin_reaches(acme)
      sign_in_with('Configurations_Users_CompanyAssignment')

      get '/api/profile/companies'

      expect(body_data.map { |c| c['Name'] }).to eq(['ACME S.A.'])
    end
  end
end

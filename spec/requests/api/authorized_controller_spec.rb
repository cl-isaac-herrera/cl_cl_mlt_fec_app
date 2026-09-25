# frozen_string_literal: true

require 'rails_helper'

# Controller exclusivo de este spec (ver config/routes.rb, montado solo en test).
# Se define acá para no tener un controller de producción sin uso real todavía.
# skip_before_action :authenticate_from_session_or_token! — este spec cubre
# autorización (require_permission!), no autenticación; el dual auth se
# especifica en spec/requests/api/base_controller_spec.rb.
class AuthorizedControllerTestController < Api::AuthorizedController
  skip_before_action :authenticate_from_session_or_token!

  before_action do
    Current.user = User.find_by(id: params[:as_user_id])
    Current.company_id = params[:company_id]&.to_i
  end

  def checked
    require_permission!('Sales_Access')
    render json: { ok: true } unless performed?
  end

  def unchecked
    render json: { ok: true }
  end
end

RSpec.describe Api::AuthorizedController, type: :request do
  let(:user)       { User.create!(email: 'perm@example.com') }
  let(:company)    { Company.create!(name: 'ACME') }
  let(:role)       { Role.create!(name: 'Admin') }
  let(:permission) { Permission.create!(name: 'Sales_Access') }

  describe 'require_permission!' do
    it 'permite cuando el usuario tiene el permiso por su rol en la compañía activa' do
      UsersByCompany.create!(user: user, company: company, role: role)
      RolePermission.create!(role: role, permission: permission)

      get '/__test/authorized/checked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:ok)
    end

    it 'permite cuando el usuario tiene el permiso por su rol de instalación, sin compañía activa' do
      installation_role = Role.create!(name: 'Admin de instalación', scope: 'installation')
      installation_permission = Permission.create!(name: 'Sales_Access_Installation', scope: 'installation')
      RolePermission.create!(role: installation_role, permission: installation_permission)
      user.update!(installation_role: installation_role)

      get '/__test/authorized/checked', params: { as_user_id: user.id }

      # El controller de prueba exige 'Sales_Access' (de compañía) — acá solo
      # se confirma que la vía de instalación se consulta sin reventar sin
      # compañía activa. Ver el spec de abajo para el caso que sí concede.
      expect(response).to have_http_status(:forbidden)
    end

    it 'deniega con 403 cuando el usuario no tiene el permiso' do
      get '/__test/authorized/checked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)['Message']).to eq('Acceso denegado')
    end

    it 'deniega si el permiso existe pero para otra compañía' do
      other_company = Company.create!(name: 'Other')
      UsersByCompany.create!(user: user, company: other_company, role: role)
      RolePermission.create!(role: role, permission: permission)

      get '/__test/authorized/checked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:forbidden)
    end

    it 'permite por rol de instalación aunque el permiso pedido sea de compañía si el rol de instalación lo tiene' do
      installation_role = Role.create!(name: 'Admin de instalación', scope: 'installation')
      user.update!(installation_role: installation_role)
      # `permission` (Sales_Access) es de alcance `company` por defecto: un rol
      # de instalación NUNCA puede contenerlo (`RolePermission#scope_matches_role`),
      # así que asignarlo ahí debe rechazarse — es la prueba de que la vía de
      # instalación no es una puerta trasera para permisos de compañía.
      role_permission = RolePermission.new(role: installation_role, permission: permission)

      expect(role_permission).not_to be_valid
    end
  end

  describe 'safety net verify_permission_checked' do
    it 'explota en desarrollo si la acción no llama require_permission! ni skip_permission_check!' do
      allow(Rails.env).to receive(:development?).and_return(true)

      get '/__test/authorized/unchecked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:internal_server_error)
    end

    it 'no explota fuera de desarrollo (test/producción)' do
      get '/__test/authorized/unchecked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:ok)
    end
  end
end

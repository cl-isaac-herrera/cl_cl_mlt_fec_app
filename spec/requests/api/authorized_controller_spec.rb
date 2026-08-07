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
    it 'permite cuando el usuario tiene el permiso para esa compañía' do
      UserRole.create!(user: user, role: role, company: company)
      RolePermission.create!(role: role, permission: permission)

      get '/__test/authorized/checked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:ok)
    end

    it 'deniega con 403 cuando el usuario no tiene el permiso' do
      get '/__test/authorized/checked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)['Message']).to eq('Acceso denegado')
    end

    it 'deniega si el permiso existe pero para otra compañía' do
      other_company = Company.create!(name: 'Other')
      UserRole.create!(user: user, role: role, company: other_company)
      RolePermission.create!(role: role, permission: permission)

      get '/__test/authorized/checked', params: { as_user_id: user.id, company_id: company.id }

      expect(response).to have_http_status(:forbidden)
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

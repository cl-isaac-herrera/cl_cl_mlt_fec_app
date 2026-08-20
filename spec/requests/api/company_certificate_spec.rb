# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/companies/:company_id/certificate', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }

  let!(:files_root) { use_temporary_files_root }

  let(:p12_bytes) { build_p12(pin: 'clave', expires_at: Time.zone.parse('2029-03-15 10:00:00')) }
  let(:cert_path) { File.join(files_root, '3101822733', 'cert.p12') }

  let(:acme) do
    Company.create!(name: 'ACME S.A.', issuer_id_number: '3101822733', cert_path: cert_path)
  end

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def write_certificate!
    FileUtils.mkdir_p(File.dirname(cert_path))
    File.binwrite(cert_path, p12_bytes)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get "/api/companies/#{acme.id}/certificate"

      expect(response).to have_http_status(:unauthorized)
    end

    # El .p12 con su PIN es la identidad de la compañía ante Hacienda: bajarlo no
    # es una lectura más, así que pide el mismo permiso que cambiarlo.
    it 'exige Configurations_Companies_Update' do
      write_certificate!
      sign_in_with('Configurations_Companies_ListAccess')

      get "/api/companies/#{acme.id}/certificate"

      expect(response).to have_http_status(:forbidden)
    end

    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{ajena.id}/certificate"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'descarga' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'devuelve el archivo con su nombre' do
      write_certificate!

      get "/api/companies/#{acme.id}/certificate"

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(p12_bytes)
      expect(response.headers['Content-Disposition']).to include('cert.p12')
    end

    it 'responde 404 cuando la compañía no tiene certificado' do
      acme.update!(cert_path: nil)

      get "/api/companies/#{acme.id}/certificate"

      expect(response).to have_http_status(:not_found)
    end

    # Pasa con una compañía importada: su `cert_path` apunta al disco del
    # servidor .NET, que este no tiene.
    it 'responde 404 cuando la ruta guardada no existe en este servidor' do
      acme.update!(cert_path: File.join(files_root, 'no-existe', 'cert.p12'))

      get "/api/companies/#{acme.id}/certificate"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)['Message']).to include('no está disponible')
    end
  end
end

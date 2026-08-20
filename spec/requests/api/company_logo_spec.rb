# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/companies/:company_id/logo', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }

  let!(:files_root) { use_temporary_files_root }

  let(:logo_bytes) { "\x89PNG\r\n\x1a\nlogo-de-acme".b }
  let(:logo_path)  { File.join(files_root, '3101822733', 'logo-acme.png') }

  let(:acme) do
    Company.create!(name: 'ACME S.A.', issuer_id_number: '3101822733', logo_path: logo_path)
  end

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def write_logo!(path = logo_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, logo_bytes)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rechaza a quien no tiene ninguno de los dos permisos de descarga' do
      write_logo!
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:forbidden)
    end

    it 'acepta el permiso por compañía' do
      write_logo!
      sign_in_with('Configurations_Companies_DownloadLogo')

      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:ok)
    end

    # El global habilita bajar el logo de cualquier compañía; el ALCANCE de cuáles
    # son "cualquiera" lo sigue resolviendo `VisibleCompanies` con su propio
    # permiso, así que acá alcanza para las propias.
    it 'acepta el permiso global' do
      write_logo!
      sign_in_with('Configurations_Companies_DownloadLogoInAllCompanies')

      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:ok)
    end

    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_DownloadLogo')

      get "/api/companies/#{ajena.id}/logo"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'descarga' do
    before { sign_in_with('Configurations_Companies_DownloadLogo') }

    it 'devuelve el archivo con su nombre y su tipo' do
      write_logo!

      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(logo_bytes)
      expect(response.headers['Content-Disposition']).to include('logo-acme.png')
      expect(response.media_type).to eq('image/png')
    end

    it 'usa image/jpeg para un .jpg' do
      jpg = File.join(files_root, '3101822733', 'logo-acme.jpg')
      acme.update!(logo_path: jpg)
      write_logo!(jpg)

      get "/api/companies/#{acme.id}/logo"

      expect(response.media_type).to eq('image/jpeg')
    end

    it 'responde 404 cuando la compañía no tiene logo' do
      acme.update!(logo_path: nil)

      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:not_found)
    end

    # Pasa con una compañía importada: su `logo_path` apunta al disco del servidor
    # .NET, que este no tiene.
    it 'responde 404 cuando la ruta guardada no existe en este servidor' do
      acme.update!(logo_path: File.join(files_root, 'no-existe', 'logo.png'))

      get "/api/companies/#{acme.id}/logo"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)['Message']).to include('no está disponible')
    end
  end
end

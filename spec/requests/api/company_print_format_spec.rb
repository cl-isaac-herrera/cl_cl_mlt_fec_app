# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/companies/:company_id/print_format', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }

  let!(:files_root) { use_temporary_files_root }

  let(:format_bytes) { "CRYSTAL\x1areporte-de-acme".b }
  let(:format_path)  { File.join(files_root, '3101822733', 'formato-acme.rpt') }

  let(:acme) do
    Company.create!(name: 'ACME S.A.', issuer_id_number: '3101822733',
                    print_format_path: format_path)
  end

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def write_format!(path = format_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, format_bytes)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rechaza a quien no tiene ninguno de los dos permisos de descarga' do
      write_format!
      sign_in_with('Configurations_Companies_Update')

      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:forbidden)
    end

    it 'acepta el permiso por compañía' do
      write_format!
      sign_in_with('Configurations_Companies_DownloadFEPrintFormat')

      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:ok)
    end

    it 'acepta el permiso global' do
      write_format!
      sign_in_with('Configurations_Companies_DownloadFEPrintFormatInAllCompanies')

      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:ok)
    end

    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.')
      sign_in_with('Configurations_Companies_DownloadFEPrintFormat')

      get "/api/companies/#{ajena.id}/print_format"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'descarga' do
    before { sign_in_with('Configurations_Companies_DownloadFEPrintFormat') }

    it 'devuelve el archivo con su nombre' do
      write_format!

      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(format_bytes)
      expect(response.headers['Content-Disposition']).to include('formato-acme.rpt')
    end

    it 'responde 404 cuando la compañía no tiene formato de impresión' do
      acme.update!(print_format_path: nil)

      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:not_found)
    end

    # Pasa con una compañía importada: su `print_format_path` apunta al disco del
    # servidor .NET, que este no tiene.
    it 'responde 404 cuando la ruta guardada no existe en este servidor' do
      acme.update!(print_format_path: File.join(files_root, 'no-existe', 'formato.rpt'))

      get "/api/companies/#{acme.id}/print_format"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)['Message']).to include('no está disponible')
    end
  end

  # El botón "Restablecer formato" de la pantalla sigue yendo al .NET: en el
  # legado no vaciaba la columna, copiaba el formato por defecto del grupo. Sin
  # grupos y sin tabla de configuraciones generales no hay de dónde copiar, y
  # vaciarla dejaría a la compañía sin poder emitir (`TODOS.md` → Compañías).
  describe 'restablecer el formato' do
    it 'el DELETE no está migrado: sigue cayendo al proxy' do
      route = Rails.application.routes.recognize_path('/api/companies/1/print_format', method: :delete)

      expect(route).to include(controller: 'proxy', action: 'forward')
    end
  end
end

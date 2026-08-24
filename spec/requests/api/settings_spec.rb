# frozen_string_literal: true

require 'rails_helper'

# Ajustes de la instalación (pantalla Configuraciones → Generales). Reemplazan
# `GET /api/settings` y `PATCH /api/settings` del .NET, que mandaba el `Code` en
# el cuerpo.
RSpec.describe 'Api::Settings', type: :request do
  let(:user)    { User.create!(email: 'ajustes@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def create_setting(code:, group_code: 'DOCS_DB_ODBC', value: nil, is_visible: true)
    Setting.create!(code: code, group_code: group_code, description: "Ajuste #{code}",
                    value: value, is_visible: is_visible)
  end

  describe 'GET /api/settings' do
    it 'responde 401 sin sesión' do
      get '/api/settings'

      expect(response).to have_http_status(:unauthorized)
    end

    it 'responde 403 sin el permiso del módulo' do
      sign_in_with

      get '/api/settings'

      expect(response).to have_http_status(:forbidden)
    end

    it 'devuelve el catálogo con el contrato ApiResponse' do
      create_setting(code: 'DOCS_DB_ODBC_SERVER', value: 'CLSQL01')
      sign_in_with('Configurations_General_Access')

      get '/api/settings'

      expect(response).to have_http_status(:ok)
      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body_data.first).to include(
        'Code' => 'DOCS_DB_ODBC_SERVER', 'GroupCode' => 'DOCS_DB_ODBC',
        'Value' => 'CLSQL01', 'HasValue' => true, 'IsVisible' => true
      )
    end

    it 'filtra por grupo' do
      create_setting(code: 'DOCS_DB_ODBC_SERVER')
      create_setting(code: 'CRYSTAL_USER', group_code: 'CRYSTAL')
      sign_in_with('Configurations_General_Access')

      get '/api/settings', params: { group: 'CRYSTAL' }

      expect(body_data.map { |s| s['Code'] }).to eq(['CRYSTAL_USER'])
    end

    # La razón de ser de `is_visible`: el .NET mandaba `CrystalPassword` en claro
    # al browser y la UI la enmascaraba con un input que tenía botón para
    # revelarla.
    it 'NUNCA devuelve el valor de un ajuste oculto, pero sí dice que lo hay' do
      create_setting(code: 'DOCS_DB_ODBC_PASSWORD', value: 's3cr3t', is_visible: false)
      sign_in_with('Configurations_General_Access')

      get '/api/settings'

      expect(response.body).not_to include('s3cr3t')
      expect(body_data.first).to include('Value' => nil, 'HasValue' => true, 'IsVisible' => false)
    end

    it 'distingue el ajuste oculto sin configurar del que ya tiene valor' do
      create_setting(code: 'DOCS_DB_ODBC_PASSWORD', value: nil, is_visible: false)
      sign_in_with('Configurations_General_Access')

      get '/api/settings'

      expect(body_data.first).to include('Value' => nil, 'HasValue' => false)
    end
  end

  describe 'PATCH /api/settings/:code' do
    it 'responde 403 sin el permiso del módulo' do
      create_setting(code: 'DOCS_DB_ODBC_SERVER')
      sign_in_with

      patch '/api/settings/DOCS_DB_ODBC_SERVER', params: { Value: 'CLSQL02' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'guarda el valor y lo devuelve serializado' do
      setting = create_setting(code: 'DOCS_DB_ODBC_SERVER', value: 'CLSQL01')
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/DOCS_DB_ODBC_SERVER', params: { Value: 'CLSQL02' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(body_data['Value']).to eq('CLSQL02')
      expect(setting.reload.value).to eq('CLSQL02')
    end

    it 'guarda el valor de un ajuste oculto sin devolverlo' do
      setting = create_setting(code: 'DOCS_DB_ODBC_PASSWORD', is_visible: false)
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/DOCS_DB_ODBC_PASSWORD', params: { Value: 's3cr3t' }, as: :json

      expect(setting.reload.value).to eq('s3cr3t')
      expect(response.body).not_to include('s3cr3t')
      expect(body_data).to include('Value' => nil, 'HasValue' => true)
    end

    # El cuerpo lleva SOLO el valor: los metadatos son del catálogo y los declara
    # `db/seeds.rb`. Un `Code` o un `IsVisible` que llegue se ignora.
    it 'ignora los metadatos que vengan en el cuerpo' do
      setting = create_setting(code: 'CRYSTAL_USER', group_code: 'CRYSTAL')
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/CRYSTAL_USER',
            params: { Value: 'reportes', Code: 'OTRO_CODE', GroupCode: 'HACKED',
                      IsVisible: false, Description: 'otra cosa' },
            as: :json

      setting.reload
      expect(setting.code).to eq('CRYSTAL_USER')
      expect(setting.group_code).to eq('CRYSTAL')
      expect(setting.is_visible).to be(true)
      expect(setting.description).to eq('Ajuste CRYSTAL_USER')
    end

    # Sin la llave `Value` la petición no dice qué hacer. Tomarla como cadena
    # vacía borraría en silencio lo que había.
    it 'rechaza el cuerpo sin `Value` en vez de vaciar el ajuste' do
      setting = create_setting(code: 'DOCS_DB_ODBC_SERVER', value: 'CLSQL01')
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/DOCS_DB_ODBC_SERVER', params: {}, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(setting.reload.value).to eq('CLSQL01')
    end

    it 'deja el ajuste sin configurar cuando el valor viene vacío' do
      setting = create_setting(code: 'DOCS_DB_ODBC_SERVER', value: 'CLSQL01')
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/DOCS_DB_ODBC_SERVER', params: { Value: '' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(setting.reload.value).to be_nil
      expect(body_data['HasValue']).to be(false)
    end

    it 'devuelve el mensaje de validación traducido cuando el valor es muy largo' do
      create_setting(code: 'DOCS_DB_ODBC_SERVER')
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/DOCS_DB_ODBC_SERVER',
            params: { Value: 'x' * (Setting::MAX_VALUE_LENGTH + 1) }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      # Compara el mensaje completo: `to be_present` pasaría igual con
      # "Translation missing…" (CLAUDE.md §30).
      expect(body['Message']).to eq('El valor es demasiado largo (máximo 500 caracteres)')
    end

    it 'responde 404 cuando el ajuste no está en el catálogo' do
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/NO_EXISTE_ESTE', params: { Value: 'x' }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    # La pantalla administra el catálogo, así que también reconfigura lo dado de
    # baja (CLAUDE.md §28).
    it 'encuentra un ajuste dado de baja' do
      setting = create_setting(code: 'DOCS_DB_ODBC_SERVER')
      setting.update_column(:is_active, false)
      sign_in_with('Configurations_General_Access')

      patch '/api/settings/DOCS_DB_ODBC_SERVER', params: { Value: 'CLSQL02' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(setting.reload.value).to eq('CLSQL02')
    end
  end
end

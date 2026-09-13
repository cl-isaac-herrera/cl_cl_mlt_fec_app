# frozen_string_literal: true

require 'rails_helper'

# Los archivos XSD con los que se valida un comprobante contra el esquema de
# Hacienda. Reemplazan los nueve `appSettings` del .NET (`FEXSDPath`, …
# `ACCEPTXSDMailParser`), que eran rutas del disco de aquel servidor.
RSpec.describe 'Api::HaciendaSchemas', type: :request do
  let(:user)    { User.create!(email: 'xsd@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  let(:account)   { 'clviscofe' }
  let(:key)       { Base64.strict_encode64('una-clave-de-prueba-cualquiera') }
  let(:container) { 'clvsfe' }
  let(:code)      { 'HACIENDA_XSD_01' }

  let(:legacy_xsd) do
    Rails.root.join('legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Docs/FacturaElectronica_V4.4.xsd').read
  end

  before do
    Hacienda::SchemaStore.clear_cache!

    azure_setting('AZURE_STORAGE_ACCOUNT_NAME', account)
    azure_setting('AZURE_STORAGE_ACCOUNT_KEY', key, is_visible: false)
    azure_setting('AZURE_STORAGE_CONTAINER', container)

    setting.update_value!(nil)
  end

  after { Hacienda::SchemaStore.clear_cache! }

  let(:setting) do
    Setting.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.group_code  = Hacienda::SchemaStore::GROUP_CODE
      record.description = code
      record.is_visible  = true
      record.save!
    end
  end

  def azure_setting(code, value, is_visible: true)
    Setting.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.group_code  = 'AZURE_STORAGE'
      record.description = code
      record.is_visible  = is_visible
      record.value       = value
      record.save!
    end
  end

  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body = JSON.parse(response.body)

  def blob_url(path) = "https://#{account}.blob.core.windows.net/#{container}/#{path}"

  def expected_path(content: legacy_xsd, file_name: 'FacturaElectronica_V4.4.xsd')
    Hacienda::SchemaStore.blob_path(code: code, file_name: file_name, content: content)
  end

  def xsd_upload(bytes = legacy_xsd, filename: 'FacturaElectronica_V4.4.xsd')
    uploaded_file(bytes, filename: filename, type: 'application/xml')
  end

  describe 'PUT /api/hacienda_schemas/:code' do
    it 'responde 401 sin sesión' do
      put "/api/hacienda_schemas/#{code}", params: { File: xsd_upload }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'responde 403 sin el permiso del módulo' do
      sign_in_with

      put "/api/hacienda_schemas/#{code}", params: { File: xsd_upload }

      expect(response).to have_http_status(:forbidden)
    end

    it 'sube el archivo y deja el ajuste apuntando al blob' do
      sign_in_with('Configurations_General_Access')
      path = expected_path
      request = stub_request(:put, blob_url(path)).to_return(status: 201)

      put "/api/hacienda_schemas/#{code}", params: { File: xsd_upload }

      expect(response).to have_http_status(:ok)
      expect(body.keys).to include('Data', 'Code', 'Message')
      expect(body['Data']).to include('Code' => code,
                                      'Label' => 'Factura electrónica',
                                      'FileName' => 'FacturaElectronica_V4.4.xsd',
                                      'Value' => path)
      expect(request).to have_been_made.once
      expect(setting.reload.value).to eq(path)
    end

    it 'responde 422 con el motivo cuando el archivo no compila como esquema' do
      sign_in_with('Configurations_General_Access')

      put "/api/hacienda_schemas/#{code}", params: { File: xsd_upload('no soy un esquema') }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('No se pudo leer el esquema XSD de Factura electrónica')
      expect(setting.reload.value).to be_nil
    end

    it 'responde 422 cuando la extensión no es .xsd' do
      sign_in_with('Configurations_General_Access')

      put "/api/hacienda_schemas/#{code}", params: { File: xsd_upload(legacy_xsd, filename: 'x.xml') }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Seleccione un archivo con extensión .xsd.')
    end

    it 'responde 422 sin archivo en el cuerpo' do
      sign_in_with('Configurations_General_Access')

      put "/api/hacienda_schemas/#{code}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Seleccione un archivo XSD para continuar.')
    end

    # Azure sin configurar o caído no es un error del archivo que eligió el
    # operador: es la instalación, y el mensaje tiene que decirlo.
    it 'responde 502 cuando Azure rechaza la subida' do
      sign_in_with('Configurations_General_Access')
      stub_request(:put, blob_url(expected_path)).to_return(status: 500)

      put "/api/hacienda_schemas/#{code}", params: { File: xsd_upload }

      expect(response).to have_http_status(:bad_gateway)
      expect(setting.reload.value).to be_nil
    end

    # El guard que impide dejar una ruta de blob en un ajuste de otro grupo: sin
    # él, un `PUT` a `CRYSTAL_PASSWORD` le escribiría una ruta encima.
    it 'responde 404 con un `code` que no es del catálogo de esquemas' do
      sign_in_with('Configurations_General_Access')

      put '/api/hacienda_schemas/HACIENDA_XSD_99', params: { File: xsd_upload }

      expect(response).to have_http_status(:not_found)
    end

    # La restricción de la ruta acota el `code` al grupo `HACIENDA_XSD`, así que
    # uno de otro grupo ni siquiera llega al controller. No se verifica con un
    # `put` real porque el catch-all del proxy (`match '/api/*path'`) lo levanta
    # igual y la respuesta no diría quién lo atendió.
    it 'no rutea a este controller un `code` de otro grupo' do
      recognized = Rails.application.routes.recognize_path(
        '/api/hacienda_schemas/CRYSTAL_PASSWORD', method: :put
      )

      expect(recognized[:controller]).not_to eq('api/hacienda_schemas')
    end
  end

  describe 'GET /api/hacienda_schemas/:code' do
    it 'responde 401 sin sesión' do
      get "/api/hacienda_schemas/#{code}"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'devuelve el archivo con su nombre original' do
      sign_in_with('Configurations_General_Access')
      path = expected_path
      setting.update_value!(path)
      stub_request(:get, blob_url(path)).to_return(status: 200, body: legacy_xsd)

      get "/api/hacienda_schemas/#{code}"

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to include('FacturaElectronica_V4.4.xsd')
      expect(response.body).to eq(legacy_xsd)
    end

    it 'responde 404 cuando no hay archivo cargado' do
      sign_in_with('Configurations_General_Access')

      get "/api/hacienda_schemas/#{code}"

      expect(response).to have_http_status(:not_found)
      expect(body['Message']).to include('Factura electrónica')
    end

    it 'responde 502 cuando Azure no devuelve el blob' do
      sign_in_with('Configurations_General_Access')
      path = expected_path
      setting.update_value!(path)
      stub_request(:get, blob_url(path)).to_return(status: 500)

      get "/api/hacienda_schemas/#{code}"

      expect(response).to have_http_status(:bad_gateway)
    end
  end

  # El catálogo tiene que estar completo en una base migrada: es lo que pinta la
  # pantalla, que itera `Hacienda::SchemaStore::SCHEMAS` y busca cada `code` en
  # lo que devuelve `GET /api/settings`. Un `code` de la constante sin fila en la
  # base deja el campo mudo — se ve, pero no carga ni guarda nada.
  describe 'el catálogo sembrado' do
    it 'tiene una fila por cada esquema declarado' do
      codes = Setting.unscoped.in_group(Hacienda::SchemaStore::GROUP_CODE).pluck(:code)

      expect(codes).to match_array(Hacienda::SchemaStore::CODES)
    end

    it 'los expone por GET /api/settings, que es de donde los lee la pantalla' do
      sign_in_with('Configurations_General_Access')

      get '/api/settings', params: { group: Hacienda::SchemaStore::GROUP_CODE }

      expect(body['Data'].map { |s| s['Code'] }).to match_array(Hacienda::SchemaStore::CODES)
      expect(body['Data']).to all(include('IsVisible' => true))
    end
  end
end

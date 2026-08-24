# frozen_string_literal: true

require 'rails_helper'

# Botón "Probar conexión" de Configuraciones → Generales. No existe en el .NET:
# es lo único que le dice al operador si los ajustes que llenó sirven.
RSpec.describe 'POST /api/external_db_health_checks', type: :request do
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

  def stub_health(ok:, message:, engine: nil, version: nil, latency_ms: 12)
    result = ExternalDb::HealthCheck::Result.new(
      ok: ok, engine: engine, version: version, latency_ms: latency_ms, message: message
    )
    allow(ExternalDb::HealthCheck).to receive(:call).and_return(result)
  end

  it 'responde 401 sin sesión' do
    post '/api/external_db_health_checks'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'responde 403 sin el permiso del módulo' do
    sign_in_with

    post '/api/external_db_health_checks'

    expect(response).to have_http_status(:forbidden)
  end

  it 'sondea el grupo de la base de documentos y devuelve motor, versión y latencia' do
    stub_health(ok: true, message: 'La conexión a la base de documentos responde.',
                engine: 'HANA', version: '2.00.075', latency_ms: 42)
    sign_in_with('Configurations_General_Access')

    post '/api/external_db_health_checks'

    expect(response).to have_http_status(:ok)
    expect(ExternalDb::HealthCheck).to have_received(:call).with('DOCS_DB_ODBC')
    expect(body_data).to include('Ok' => true, 'Engine' => 'HANA',
                                 'Version' => '2.00.075', 'LatencyMs' => 42)
    expect(body['Message']).to eq('La conexión a la base de documentos responde.')
  end

  # Que la conexión falle no es un error de la petición: la verificación se hizo
  # y su resultado ES la respuesta. Mismo criterio que
  # POST /api/sap_credential_validations.
  it 'responde 200 con Ok: false cuando la conexión no responde' do
    stub_health(ok: false, message: 'Faltan ajustes de la conexión a la base de documentos: ' \
                                    'DOCS_DB_ODBC_USER.')
    sign_in_with('Configurations_General_Access')

    post '/api/external_db_health_checks'

    expect(response).to have_http_status(:ok)
    expect(body_data['Ok']).to be(false)
    expect(body['Message']).to include('Faltan ajustes')
  end

  # El `group_code` termina en una conexión ODBC: sin la lista blanca, cualquier
  # grupo de ajustes se podría usar como destino.
  it 'rechaza un grupo que no está en la lista blanca, sin sondear nada' do
    allow(ExternalDb::HealthCheck).to receive(:call)
    sign_in_with('Configurations_General_Access')

    post '/api/external_db_health_checks', params: { GroupCode: 'CRYSTAL' }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(ExternalDb::HealthCheck).not_to have_received(:call)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# CLAVISCO-PLATFORM-STANDARDS §2.4 + §1.5.
#
# El middleware `ErrorHandler` de `cl-common` tiene que convertir cualquier
# excepción no manejada de /api/* en el contrato `ApiResponse`, sin filtrar el
# mensaje de la excepción. Estos specs existen porque el middleware es fácil de
# registrar en la posición equivocada: por fuera de `ActionDispatch::ShowExceptions`
# queda mudo y el cliente recibe HTML vacío, sin que nada falle a la vista.
RSpec.describe 'Api ErrorHandler', type: :request do
  let(:user)    { User.create!(email: 'errores@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  def body = JSON.parse(response.body)

  before do
    UserRole.create!(user: user, role: role, company: company)
    RolePermission.create!(role: role,
                           permission: Permission.create!(name: 'Configurations_Security_Access'))
    sign_in(user, company: company)
  end

  it 'responde JSON con el contrato ApiResponse ante una excepción no manejada' do
    allow(Role).to receive(:order).and_raise(StandardError, 'boom')

    get '/api/roles'

    expect(response).to have_http_status(:internal_server_error)
    expect(response.content_type).to include('application/json')
    expect(body.keys).to include('Data', 'Code', 'Message')
    expect(body['Code']).to eq(500)
  end

  # §1.5: "un error no controlado nunca expone el mensaje de excepción o
  # stacktrace al usuario — se devuelve un mensaje genérico y el detalle completo
  # va solo al log del servidor".
  it 'no filtra el mensaje de la excepción ni el stacktrace' do
    allow(Role).to receive(:order)
      .and_raise(StandardError, 'PGCONN password=s3cr3t host=10.0.0.1')

    get '/api/roles'

    expect(response.body).not_to include('s3cr3t')
    expect(response.body).not_to include('10.0.0.1')
    expect(response.body).not_to match(/\.rb:\d+/) # sin stacktrace
    expect(body['Message']).to eq('Error interno del servidor')
  end

  it 'traduce RecordNotFound a 404 con el contrato' do
    allow(Role).to receive(:order).and_raise(ActiveRecord::RecordNotFound)

    get '/api/roles'

    expect(response).to have_http_status(:not_found)
    expect(body['Code']).to eq(404)
  end

  # Fuera de /api/* el middleware re-lanza: las páginas HTML conservan su propio
  # manejo de errores y no empiezan a devolver JSON.
  it 'no toca las respuestas de error fuera de /api' do
    allow_any_instance_of(Configurations::RolesController)
      .to receive(:index).and_raise(StandardError, 'boom')

    get '/configurations/security'

    expect(response.content_type).not_to include('application/json')
  end
end

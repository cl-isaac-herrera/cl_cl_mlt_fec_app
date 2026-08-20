# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/certificate_inspections', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }
  let(:acme) { Company.create!(name: 'ACME S.A.') }

  let(:pin)        { 'clave-del-p12' }
  let(:expires_at) { Time.zone.parse('2029-03-15 10:00:00') }

  # Un PKCS#12 de verdad, armado en el momento: es la única forma de probar que
  # la fecha sale de abrir el archivo y no de algo que mandó el cliente. Evita
  # además meter un binario como fixture en el repo. Ver `CertificateHelpers`.
  let(:p12_bytes) { build_p12(pin: pin, expires_at: expires_at) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def inspect_certificate(file: uploaded_file(p12_bytes), cert_pin: pin)
    post '/api/certificate_inspections', params: { file: file, CertPin: cert_pin }
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      inspect_certificate

      expect(response).to have_http_status(:unauthorized)
    end

    it 'responde 403 sin permiso de crear ni de actualizar compañías' do
      sign_in_with('Configurations_Companies_ListAccess')

      inspect_certificate

      expect(response).to have_http_status(:forbidden)
    end

    # Lo usan las dos pantallas que cargan un certificado, y cada permiso por
    # separado ya autoriza esta lectura.
    it 'alcanza con Configurations_Companies_Create (pantalla de alta)' do
      sign_in_with('Configurations_Companies_Create')

      inspect_certificate

      expect(response).to have_http_status(:ok)
    end

    it 'alcanza con Configurations_Companies_Update (pantalla de edición)' do
      sign_in_with('Configurations_Companies_Update')

      inspect_certificate

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'lectura del certificado' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'devuelve la fecha que trae el certificado' do
      inspect_certificate

      expect(response).to have_http_status(:ok)
      expect(Time.zone.parse(body_data['CertExpireDate'])).to eq(expires_at)
    end

    it 'acepta la extensión .pfx' do
      inspect_certificate(file: uploaded_file(p12_bytes, filename: 'cert.pfx'))

      expect(response).to have_http_status(:ok)
    end
  end

  # El PIN equivocado y el archivo que no es un PKCS#12 son la misma comprobación
  # para OpenSSL: si el MAC no verifica, no puede distinguirlos. Por eso los dos
  # dan el mismo mensaje, que nombra las dos causas en vez de afirmar una.
  describe 'cuando no se puede abrir' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'rechaza un PIN equivocado con 422' do
      inspect_certificate(cert_pin: 'otra-clave')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('Verifique que el PIN sea el correcto')
    end

    it 'rechaza un archivo que no es un certificado' do
      inspect_certificate(file: uploaded_file('esto no es un p12', filename: 'notas.p12'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('Verifique que el PIN sea el correcto')
    end

    it 'pide el archivo cuando no viene' do
      post '/api/certificate_inspections', params: { CertPin: pin }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Seleccione el archivo del certificado.')
    end

    it 'pide el PIN cuando viene en blanco' do
      inspect_certificate(cert_pin: '   ')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Ingrese el PIN del certificado.')
    end

    # El tope no es una regla de negocio: existe para no leer a memoria lo que
    # alguien mande por este campo.
    it 'rechaza un archivo más grande que el tope, sin intentar abrirlo' do
      grande = 'x' * (Certificates::ExpirationReader::MAX_BYTES + 1)

      inspect_certificate(file: uploaded_file(grande))

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('supera el tamaño máximo')
    end
  end

  # El PIN dejó de viajar en la query string justamente para que no quede en el
  # historial del navegador ni en el log de accesos del servidor web.
  it 'recibe el PIN por el cuerpo, no por la URL' do
    sign_in_with('Configurations_Companies_Update')

    inspect_certificate

    expect(request.query_string).to be_empty
    expect(response).to have_http_status(:ok)
  end
end

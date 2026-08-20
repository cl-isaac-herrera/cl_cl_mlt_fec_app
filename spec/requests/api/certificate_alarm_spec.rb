# frozen_string_literal: true

require 'rails_helper'

# Alarma de vencimiento del certificado digital de la compañía activa: el toast
# que el home muestra al cargar. Reemplaza
# `GET /api/Companies/GetCertExpireDateAlarm?companyId=N` del .NET.
RSpec.describe 'GET /api/certificate_alarm', type: :request do
  let(:user) { User.create!(email: 'emisor@example.com') }
  let(:sap)  { Connection.create!(name: 'SAP Producción', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) { Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME') }

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  # Deja la compañía asignada al usuario y activa en la sesión: el endpoint la
  # resuelve de ahí, no de un parámetro.
  def sign_in_with_active(company)
    UsersByCompany.create!(user: user, company: company)
    sign_in(user, company: company)
  end

  it 'responde 401 sin sesión' do
    get '/api/certificate_alarm'

    expect(response).to have_http_status(:unauthorized)
  end

  # Es el certificado de la compañía que el usuario ya tiene activa: el filtro de
  # acceso es la asignación, no un permiso aparte.
  it 'no exige ningún permiso' do
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(response).to have_http_status(:ok)
  end

  it 'respeta el contrato ApiResponse' do
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body.keys).to include('Data', 'Code', 'Message')
    expect(body['Code']).to eq(200)
  end

  # `Data` es un objeto y no el arreglo de un elemento que devolvía el SP: por eso
  # el Angular leía `Data.ShowAlarm` sobre un arreglo y siempre obtenía undefined.
  it 'devuelve la alarma como objeto, no como arreglo' do
    acme.update!(cert_expires_at: 3.days.from_now)
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body_data).to be_a(Hash)
    expect(body_data.keys).to contain_exactly('ShowAlarm', 'SmsAlert')
  end

  it 'avisa cuando el certificado vence dentro del umbral' do
    acme.update!(cert_expires_at: 3.days.from_now)
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body_data['ShowAlarm']).to be(true)
    expect(body_data['SmsAlert']).to eq(
      'El certificado digital de ACME S.A. vence en 3 días ' \
      "(#{3.days.from_now.to_date.strftime('%d/%m/%Y')}). Debe cargar uno vigente antes de esa fecha."
    )
  end

  it 'avisa cuando el certificado ya venció' do
    acme.update!(cert_expires_at: 2.days.ago)
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body_data['ShowAlarm']).to be(true)
    expect(body_data['SmsAlert']).to start_with(
      "El certificado digital de ACME S.A. venció el #{2.days.ago.to_date.strftime('%d/%m/%Y')}."
    )
  end

  it 'avisa cuando el certificado vence hoy' do
    acme.update!(cert_expires_at: Time.current.end_of_day)
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body_data['ShowAlarm']).to be(true)
    expect(body_data['SmsAlert']).to include('vence hoy')
  end

  it 'no avisa cuando el vencimiento está más allá del umbral' do
    acme.update!(cert_expires_at: (Company::CERT_EXPIRATION_ALARM_DAYS + 1).days.from_now)
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body_data).to eq('ShowAlarm' => false, 'SmsAlert' => nil)
  end

  # Sin fecha registrada no se sabe si vence. Avisar que falta el certificado es
  # trabajo del formulario de la compañía, no de un toast en cada carga del home.
  it 'no avisa cuando la compañía no tiene fecha de expiración' do
    sign_in_with_active(acme)

    get '/api/certificate_alarm'

    expect(body_data).to eq('ShowAlarm' => false, 'SmsAlert' => nil)
  end

  # El companyId no viaja: si la compañía de la sesión no es del usuario, no hay
  # nada que responder — y no hay forma de preguntar por una ajena.
  it 'responde 404 cuando la compañía activa no está asignada al usuario' do
    otra = Company.create!(name: 'Otra S.A.', sap_connection: sap, sap_db: 'SBO_OTRA')
    otra.update!(cert_expires_at: 1.day.from_now)
    sign_in(user, company: otra)

    get '/api/certificate_alarm'

    expect(response).to have_http_status(:not_found)
    expect(body['Message']).to eq('La compañía activa no está asignada a este usuario.')
  end

  it 'responde 404 cuando la sesión no tiene compañía activa' do
    UsersByCompany.create!(user: user, company: acme)
    sign_in(user)

    get '/api/certificate_alarm'

    expect(response).to have_http_status(:not_found)
  end

  it 'ignora el companyId que llegue por query string' do
    otra = Company.create!(name: 'Otra S.A.', sap_connection: sap, sap_db: 'SBO_OTRA',
                           cert_expires_at: 1.day.from_now)
    sign_in_with_active(acme)

    get '/api/certificate_alarm', params: { companyId: otra.id }

    expect(body_data).to eq('ShowAlarm' => false, 'SmsAlert' => nil)
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/email_credential_validations', type: :request do
  let(:user)    { User.create!(email: 'bandejas@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  let(:valid_params) do
    { Email: 'ventas@test.com', Password: 's3cr3t', Host: 'smtp.test', Port: 587,
      Ssl: true, SenderAddress: 'Facturación', RecipientEmail: 'destino@test.com' }
  end

  def body = JSON.parse(response.body)

  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  # El envío real lo hace `Mail::Message#deliver!` contra un SMTP. Se intercepta
  # ahí y no más abajo (Net::SMTP) para poder mirar el mensaje que se armó: el
  # remitente y el destinatario son parte de lo que esta prueba comprueba.
  def stub_delivery(&block)
    allow_any_instance_of(Mail::Message).to receive(:deliver!) do |message|
      block&.call(message)
      message
    end
  end

  describe 'prueba exitosa' do
    it 'envía el correo de prueba y responde Data: true' do
      delivered = nil
      stub_delivery { |message| delivered = message }

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(response).to have_http_status(:ok)
      expect(body['Data']).to be(true)
      expect(body['Message']).to eq('Se envió un correo de prueba a destino@test.com.')

      expect(delivered.to).to eq(['destino@test.com'])
      # El `From` sale de `EmailConfig#from_header`: la regla de cómo se compone
      # el remitente vive UNA vez, en el modelo.
      expect(delivered[:from].value).to eq('"Facturación" <ventas@test.com>')
    end

    it 'usa los valores del FORMULARIO, no los guardados' do
      stored = EmailConfig.create!(email: 'vieja@test.com', host: 'smtp.viejo',
                                   port: 25, password: 'vieja')
      settings = nil
      allow_any_instance_of(Mail::Message).to receive(:delivery_method) do |_m, _sym, opts|
        settings = opts
      end
      stub_delivery

      sign_in_with('Configurations_EmailInbox_Update')
      post '/api/email_credential_validations',
           params: valid_params.merge(EmailConfigId: stored.id), as: :json

      expect(settings).to include(address: 'smtp.test', port: 587,
                                  user_name: 'ventas@test.com', password: 's3cr3t')
    end

    # El servidor nunca devuelve la contraseña, así que el campo carga en blanco:
    # exigirla obligaría a reescribirla solo para probar un cambio de host.
    it 'cae a la contraseña guardada cuando el formulario la manda vacía' do
      stored = EmailConfig.create!(email: 'ventas@test.com', host: 'smtp.test',
                                   port: 587, password: 'guardada')
      settings = nil
      allow_any_instance_of(Mail::Message).to receive(:delivery_method) do |_m, _sym, opts|
        settings = opts
      end
      stub_delivery

      sign_in_with('Configurations_EmailInbox_Update')
      post '/api/email_credential_validations',
           params: valid_params.merge(EmailConfigId: stored.id, Password: ''), as: :json

      expect(body['Data']).to be(true)
      expect(settings[:password]).to eq('guardada')
    end
  end

  describe 'prueba fallida' do
    # Credenciales inválidas no son un error de la petición: 200 con Data: false
    # y el motivo en Message, igual que los validadores de SAP.
    it 'responde 200 con Data: false cuando el SMTP rechaza las credenciales' do
      allow_any_instance_of(Mail::Message).to receive(:deliver!)
        .and_raise(Net::SMTPAuthenticationError.new('535 5.7.3 Authentication unsuccessful'))

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(response).to have_http_status(:ok)
      expect(body['Data']).to be(false)
      expect(body['Message']).to include('rechazó las credenciales')
      expect(body['Message']).to include('535 5.7.3 Authentication unsuccessful')
    end

    # El caso que solo aparece enviando: autenticó bien pero el relay no deja
    # salir el mensaje. Es la razón por la que la prueba manda un correo real.
    it 'distingue el rechazo del ENVÍO del rechazo de las credenciales' do
      allow_any_instance_of(Mail::Message).to receive(:deliver!)
        .and_raise(Net::SMTPFatalError.new('550 5.7.1 Unable to relay'))

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to include('aceptó las credenciales pero rechazó el envío')
    end

    it 'informa cuando no se puede contactar al servidor' do
      allow_any_instance_of(Mail::Message).to receive(:deliver!)
        .and_raise(SocketError.new('getaddrinfo: No such host is known'))

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to include('smtp.test:587')
    end
  end

  describe 'validación previa — no se abre la conexión' do
    it 'corta sin destinatario' do
      expect_any_instance_of(Mail::Message).not_to receive(:deliver!)

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations',
           params: valid_params.merge(RecipientEmail: ''), as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to eq('Indique el correo destinatario al que se enviará la prueba.')
    end

    it 'corta con un destinatario mal formado' do
      expect_any_instance_of(Mail::Message).not_to receive(:deliver!)

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations',
           params: valid_params.merge(RecipientEmail: 'no-es-correo'), as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to include('no tiene un formato válido')
    end

    it 'corta al crear sin contraseña, porque no hay ninguna guardada de dónde sacarla' do
      expect_any_instance_of(Mail::Message).not_to receive(:deliver!)

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations',
           params: valid_params.merge(Password: ''), as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to eq('Ingrese la contraseña de la bandeja para poder probarla.')
    end

    it 'corta sin host' do
      expect_any_instance_of(Mail::Message).not_to receive(:deliver!)

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations', params: valid_params.merge(Host: ''), as: :json

      expect(body['Data']).to be(false)
      expect(body['Message']).to include('el host y el puerto')
    end
  end

  describe 'autorización' do
    # El botón está en el panel de creación y en el de edición: cada permiso
    # autoriza por separado (`require_any_permission!`).
    it 'lo habilita el permiso de creación' do
      stub_delivery
      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'lo habilita el permiso de edición' do
      stub_delivery
      sign_in_with('Configurations_EmailInbox_Update')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'responde 403 con el permiso de solo acceso' do
      expect_any_instance_of(Mail::Message).not_to receive(:deliver!)

      sign_in_with('Configurations_EmailInbox_Access')
      post '/api/email_credential_validations', params: valid_params, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::ReceptionMailboxes', type: :request do
  let(:user)    { User.create!(email: 'bandejas@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def create_mailbox(email:, mail_server: 'imap.test', port: 993, **attrs)
    ReceptionMailbox.create!(email: email, mail_server: mail_server, port: port, password: 'secreta', **attrs)
  end

  describe 'GET /api/reception_mailboxes' do
    it 'lista las bandejas con el total real, no el de la página' do
      3.times { |i| create_mailbox(email: "b#{i}@test.com") }

      sign_in_with('Configurations_MailParser_ViewConfigurations')
      get '/api/reception_mailboxes', params: { page: 1, per_page: 2 }

      expect(response).to have_http_status(:ok)
      expect(body_data['Items'].size).to eq(2)
      expect(body_data['Total']).to eq(3)
    end

    it 'filtra por correo sin distinguir mayúsculas' do
      create_mailbox(email: 'Ventas@Test.com')
      create_mailbox(email: 'compras@test.com')

      sign_in_with('Configurations_MailParser_ViewConfigurations')
      get '/api/reception_mailboxes', params: { email: 'VENTAS' }

      expect(body_data['Items'].map { |c| c['Email'] }).to eq(['Ventas@Test.com'])
    end

    it 'incluye las bandejas dadas de baja' do
      create_mailbox(email: 'activa@test.com')
      create_mailbox(email: 'baja@test.com', is_active: false)

      sign_in_with('Configurations_MailParser_ViewConfigurations')
      get '/api/reception_mailboxes'

      expect(body_data['Items'].map { |c| c['Email'] }).to contain_exactly('activa@test.com', 'baja@test.com')
    end

    it 'nunca devuelve la contraseña ni el client secret, solo si hay uno guardado' do
      create_mailbox(email: 'a@test.com')

      sign_in_with('Configurations_MailParser_ViewConfigurations')
      get '/api/reception_mailboxes'

      item = body_data['Items'].first
      expect(item).not_to have_key('Password')
      expect(item).not_to have_key('ClientSecret')
      expect(item['HasPassword']).to be(true)
      expect(item['HasClientSecret']).to be(false)
    end

    it 'responde 403 sin el permiso de acceso' do
      sign_in_with('Otro_Permiso')
      get '/api/reception_mailboxes'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /api/reception_mailboxes/assignable' do
    it 'devuelve solo las activas, con el id y el correo' do
      activa = create_mailbox(email: 'activa@test.com')
      create_mailbox(email: 'baja@test.com', is_active: false)

      sign_in_with('Configurations_Companies_Update')
      get '/api/reception_mailboxes/assignable'

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq([{ 'Id' => activa.id, 'Email' => 'activa@test.com' }])
    end

    it 'lo autoriza el permiso de compañías, no el de bandejas' do
      create_mailbox(email: 'a@test.com')

      sign_in_with('Configurations_Companies_Create')
      get '/api/reception_mailboxes/assignable'

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /api/reception_mailboxes' do
    let(:valid_params) do
      { MailServer: 'imap.nueva.com', Email: 'nueva@test.com', Password: 's3cr3t', Port: 993 }
    end

    it 'crea la bandeja activa y guarda la contraseña cifrada' do
      sign_in_with('Configurations_MailParser_Create')
      post '/api/reception_mailboxes', params: valid_params, as: :json

      expect(response).to have_http_status(:created)
      expect(body_data['Email']).to eq('nueva@test.com')
      expect(body_data['Active']).to be(true)
      expect(body_data).not_to have_key('Password')

      mailbox = ReceptionMailbox.find(body_data['Id'])
      expect(mailbox.password).to eq('s3cr3t')
    end

    it 'crea una bandeja OAuth2 sin contraseña' do
      sign_in_with('Configurations_MailParser_Create')
      post '/api/reception_mailboxes', params: {
        MailServer: 'outlook.office365.com', Email: 'oauth@test.com', Port: 993,
        UseToken: true,
        Url: 'https://login.microsoftonline.com/72f988bf-86f1-41af-91ab-2d7cd011db47/oauth2/v2.0/token',
        GrantType: 'client_credentials', Scope: 'https://outlook.office365.com/.default',
        ClientId: 'client', ClientSecret: 'secreto'
      }, as: :json

      expect(response).to have_http_status(:created)
      expect(body_data['UseToken']).to be(true)
      expect(body_data['HasClientSecret']).to be(true)
    end

    it 'devuelve los errores de validación en español' do
      sign_in_with('Configurations_MailParser_Create')
      post '/api/reception_mailboxes', params: { MailServer: '', Email: '', Port: '' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('no puede estar en blanco')
    end

    it 'responde 403 sin el permiso de creación' do
      sign_in_with('Configurations_MailParser_ViewConfigurations')
      post '/api/reception_mailboxes', params: valid_params, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/reception_mailboxes/:id' do
    let!(:mailbox) { create_mailbox(email: 'a@test.com', mail_server: 'imap.viejo') }

    it 'actualiza solo lo que viene en el cuerpo' do
      sign_in_with('Configurations_MailParser_Update')
      patch "/api/reception_mailboxes/#{mailbox.id}", params: { MailServer: 'imap.nuevo' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(mailbox.reload.mail_server).to eq('imap.nuevo')
      expect(mailbox.email).to eq('a@test.com')
    end

    it 'conserva la contraseña guardada cuando llega en blanco' do
      sign_in_with('Configurations_MailParser_Update')
      patch "/api/reception_mailboxes/#{mailbox.id}", params: { MailServer: 'imap.nuevo', Password: '' }, as: :json

      expect(mailbox.reload.password).to eq('secreta')
    end

    it 'da de baja la bandeja con Active: false' do
      sign_in_with('Configurations_MailParser_Update')
      patch "/api/reception_mailboxes/#{mailbox.id}", params: { Active: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(mailbox.reload.is_active).to be(false)
    end

    it 'no la deja dar de baja mientras una compañía la use' do
      Company.create!(name: 'Beta S.A.', reception_mailbox: mailbox)

      sign_in_with('Configurations_MailParser_Update')
      patch "/api/reception_mailboxes/#{mailbox.id}", params: { Active: false }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(mailbox.reload.is_active).to be(true)
    end

    it 'responde 404 cuando la bandeja no existe' do
      sign_in_with('Configurations_MailParser_Update')
      patch '/api/reception_mailboxes/999999', params: { MailServer: 'x' }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end

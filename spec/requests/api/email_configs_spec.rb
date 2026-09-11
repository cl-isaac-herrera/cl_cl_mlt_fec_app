# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::EmailConfigs', type: :request do
  let(:user)    { User.create!(email: 'bandejas@example.com') }
  let(:company) { Company.create!(name: 'ACME S.A.') }
  let(:role)    { Role.create!(name: 'Configurador') }

  # Deja al usuario con los permisos indicados sobre `company` y abre la sesión
  # con esa compañía activa: require_permission! resuelve contra la de la sesión.
  def sign_in_with(*permission_names)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.create!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def create_config(email:, host: 'smtp.test', port: 587, **attrs)
    EmailConfig.create!(email: email, host: host, port: port, password: 'secreta', **attrs)
  end

  describe 'GET /api/email_configs' do
    it 'lista las bandejas con el total real, no el de la página' do
      3.times { |i| create_config(email: "b#{i}@test.com") }

      sign_in_with('Configurations_EmailInbox_Access')
      get '/api/email_configs', params: { page: 1, per_page: 2 }

      expect(response).to have_http_status(:ok)
      expect(body_data['Items'].size).to eq(2)
      # El total es de la consulta completa: es lo que el contador de Tabulator
      # necesita para no sobreestimar (CLAUDE.md §17).
      expect(body_data['Total']).to eq(3)
    end

    it 'devuelve la segunda página, no la primera otra vez' do
      %w[a@test.com b@test.com c@test.com].each { |e| create_config(email: e) }

      sign_in_with('Configurations_EmailInbox_Access')
      get '/api/email_configs', params: { page: 2, per_page: 2 }

      expect(body_data['Items'].map { |c| c['Email'] }).to eq(['c@test.com'])
    end

    it 'filtra por correo sin distinguir mayúsculas y por SSL' do
      create_config(email: 'Ventas@Test.com', ssl: true)
      create_config(email: 'compras@test.com', ssl: false)

      sign_in_with('Configurations_EmailInbox_Access')

      get '/api/email_configs', params: { email: 'VENTAS' }
      expect(body_data['Items'].map { |c| c['Email'] }).to eq(['Ventas@Test.com'])

      get '/api/email_configs', params: { ssl: 'false' }
      expect(body_data['Items'].map { |c| c['Email'] }).to eq(['compras@test.com'])
    end

    it 'sin el filtro de SSL devuelve las dos: un filtro ausente no filtra' do
      create_config(email: 'con@test.com', ssl: true)
      create_config(email: 'sin@test.com', ssl: false)

      sign_in_with('Configurations_EmailInbox_Access')
      get '/api/email_configs'

      expect(body_data['Total']).to eq(2)
    end

    # Es la pantalla que ADMINISTRA las bandejas: sin las dadas de baja no habría
    # forma de reactivarlas (CLAUDE.md §28).
    it 'incluye las bandejas dadas de baja' do
      create_config(email: 'activa@test.com')
      create_config(email: 'baja@test.com', is_active: false)

      sign_in_with('Configurations_EmailInbox_Access')
      get '/api/email_configs'

      expect(body_data['Items'].map { |c| c['Email'] }).to contain_exactly('activa@test.com', 'baja@test.com')
      expect(body_data['Items'].find { |c| c['Email'] == 'baja@test.com' }['Active']).to be(false)
    end

    it 'nunca devuelve la contraseña, solo si hay una guardada' do
      create_config(email: 'a@test.com')

      sign_in_with('Configurations_EmailInbox_Access')
      get '/api/email_configs'

      item = body_data['Items'].first
      expect(item).not_to have_key('Password')
      expect(item['HasPassword']).to be(true)
    end

    it 'dice cuántas compañías usan cada bandeja' do
      config = create_config(email: 'a@test.com')
      Company.create!(name: 'Beta', email_config: config)
      Company.create!(name: 'Gamma', email_config: config)
      create_config(email: 'sinuso@test.com')

      sign_in_with('Configurations_EmailInbox_Access')
      get '/api/email_configs'

      counts = body_data['Items'].to_h { |c| [c['Email'], c['CompaniesCount']] }
      expect(counts).to eq('a@test.com' => 2, 'sinuso@test.com' => 0)
    end

    it 'responde 403 sin el permiso de acceso' do
      sign_in_with('Otro_Permiso')
      get '/api/email_configs'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /api/email_configs/assignable' do
    # El selector del formulario de compañías no puede ofrecer una bandeja dada
    # de baja: asignarla dejaría a la compañía sin poder enviar en silencio.
    it 'devuelve solo las activas, con la dirección y nada más' do
      create_config(email: 'activa@test.com', sender_address: 'Facturación')
      create_config(email: 'baja@test.com', is_active: false)

      sign_in_with('Configurations_Companies_Update')
      get '/api/email_configs/assignable'

      expect(response).to have_http_status(:ok)
      expect(body_data).to eq([{ 'Id' => EmailConfig.find_by(email: 'activa@test.com').id,
                                 'Email' => 'activa@test.com',
                                 'SenderAddress' => 'Facturación' }])
    end

    # Quien administra compañías necesita el selector aunque no administre
    # bandejas: exigir el permiso de bandejas rompería esa pantalla.
    it 'lo autoriza el permiso de compañías, no el de bandejas' do
      create_config(email: 'a@test.com')

      sign_in_with('Configurations_Companies_Create')
      get '/api/email_configs/assignable'

      expect(response).to have_http_status(:ok)
    end

    it 'responde 403 sin ninguno de los permisos que lo habilitan' do
      sign_in_with('Otro_Permiso')
      get '/api/email_configs/assignable'

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /api/email_configs' do
    let(:valid_params) do
      { Email: 'nueva@test.com', Password: 's3cr3t', Host: 'smtp.test', Port: 587,
        Ssl: true, SenderAddress: 'Facturación' }
    end

    it 'crea la bandeja activa y guarda la contraseña cifrada' do
      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_configs', params: valid_params, as: :json

      expect(response).to have_http_status(:created)
      expect(body_data['Email']).to eq('nueva@test.com')
      expect(body_data['Active']).to be(true)
      expect(body_data).not_to have_key('Password')

      config = EmailConfig.find(body_data['Id'])
      expect(config.password).to eq('s3cr3t')
      # `encrypts` es reversible pero lo guardado NO es el texto plano.
      expect(config.read_attribute_before_type_cast(:password)).not_to include('s3cr3t')
    end

    it 'rechaza un correo repetido con el mensaje en español' do
      create_config(email: 'repetida@test.com')

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_configs', params: valid_params.merge(Email: 'repetida@test.com'), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      # Se compara el mensaje y no solo su presencia: un "Translation missing"
      # también estaría presente (CLAUDE.md §30).
      expect(body['Message']).to eq('El correo ya está en uso')
    end

    it 'permite reusar el correo de una bandeja dada de baja' do
      create_config(email: 'reciclada@test.com', is_active: false)

      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_configs', params: valid_params.merge(Email: 'reciclada@test.com'), as: :json

      expect(response).to have_http_status(:created)
    end

    it 'devuelve los errores de validación en español' do
      sign_in_with('Configurations_EmailInbox_Create')
      post '/api/email_configs', params: { Email: '', Host: '', Port: '' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('El correo no puede estar en blanco, El servidor no puede ' \
                                    'estar en blanco y El puerto no puede estar en blanco')
    end

    it 'responde 403 con el permiso de acceso pero sin el de creación' do
      sign_in_with('Configurations_EmailInbox_Access')
      post '/api/email_configs', params: valid_params, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/email_configs/:id' do
    let!(:config) { create_config(email: 'a@test.com', host: 'smtp.viejo') }

    it 'actualiza solo lo que viene en el cuerpo' do
      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Host: 'smtp.nuevo' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(config.reload.host).to eq('smtp.nuevo')
      expect(config.email).to eq('a@test.com')
    end

    # El servidor nunca devuelve la contraseña, así que el formulario siempre
    # carga el campo vacío: tomarlo al pie de la letra dejaría a la bandeja sin
    # poder autenticar cada vez que alguien corrige el host.
    it 'conserva la contraseña guardada cuando llega en blanco' do
      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Host: 'smtp.nuevo', Password: '' }, as: :json

      expect(config.reload.password).to eq('secreta')
    end

    it 'reemplaza la contraseña cuando llega una nueva' do
      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Password: 'otra' }, as: :json

      expect(config.reload.password).to eq('otra')
    end

    it 'ignora un Id que llegue en el cuerpo: el del path es el que manda' do
      otra = create_config(email: 'otra@test.com')

      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Id: otra.id, Host: 'smtp.nuevo' }, as: :json

      expect(config.reload.host).to eq('smtp.nuevo')
      expect(otra.reload.host).to eq('smtp.test')
    end

    it 'da de baja la bandeja con Active: false' do
      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Active: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(config.reload.is_active).to be(false)
    end

    # Bajarla dejaría a la compañía sin poder enviar y sin ningún aviso:
    # `Company#email_config` pasa a nil por el default_scope y el correo falla
    # recién cuando hay algo que mandar.
    it 'no la deja dar de baja mientras una compañía la use, y dice cuál' do
      Company.create!(name: 'Beta S.A.', email_config: config)

      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Active: false }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('La bandeja no se puede desactivar porque Beta S.A. la usa ' \
                                    'para enviar correos')
      expect(config.reload.is_active).to be(true)
    end

    it 'permite editar (y reactivar) una bandeja dada de baja' do
      config.update!(is_active: false)

      sign_in_with('Configurations_EmailInbox_Update')
      patch "/api/email_configs/#{config.id}", params: { Active: true }, as: :json

      expect(response).to have_http_status(:ok)
      expect(config.reload.is_active).to be(true)
    end

    it 'responde 404 cuando la bandeja no existe' do
      sign_in_with('Configurations_EmailInbox_Update')
      patch '/api/email_configs/999999', params: { Host: 'x' }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    # El permiso se resuelve ANTES de buscar el registro: si se hiciera al revés,
    # un 404 le confirmaría a quien no tiene permiso qué ids existen.
    it 'responde 403 y no 404 para un id inexistente sin permiso' do
      sign_in_with('Configurations_EmailInbox_Access')
      patch '/api/email_configs/999999', params: { Host: 'x' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end

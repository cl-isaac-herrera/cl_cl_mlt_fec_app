# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::CredentialValidator do
  let(:connection) { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/') }
  let(:company) do
    Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME', connection_id: connection.id)
  end

  def validate(sap_user: 'manager', sap_password: 'secreto')
    described_class.for_company(company: company, sap_user: sap_user, sap_password: sap_password).call
  end

  # Estos tres no llegan a tocar SAP: se cortan antes de armar el client.
  describe 'prerequisitos' do
    it 'pide usuario y contraseña' do
      result = validate(sap_user: '', sap_password: '')

      expect(result).not_to be_valid
      expect(result.message).to eq('Ingrese el usuario y la contraseña de SAP.')
    end

    it 'avisa si la compañía no tiene conexión' do
      company.update!(connection_id: nil)

      expect(validate.message).to eq('La compañía no tiene una conexión SAP configurada.')
    end

    it 'avisa si la compañía no tiene base de SAP' do
      company.update!(sap_db: nil)

      expect(validate.message).to eq('La compañía no tiene una base de datos de SAP asignada.')
    end
  end

  describe 'sondeo de login' do
    # El path sale del catálogo, no del código: si alguien edita la fila desde la
    # pantalla de recursos, el sondeo cambia con ella.
    it 'usa el recurso que define el catálogo' do
      SlResource.create!(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                         query_params: '$top=1&$select=CardCode', page_size: 0, is_standard: true)
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get).and_return([])
      # La sesión del sondeo es desechable y se cierra al terminar (ver
      # `#discard_session!`): sin esto el doble se queja del mensaje inesperado.
      allow(client).to receive(:logout)

      expect(validate).to be_valid
      # Un solo argumento y sin `params:`: la query va pegada al path.
      expect(client).to have_received(:get).with('BusinessPartners?$top=1&$select=CardCode')
    end

    # Ya no hay sondeo de emergencia: si la fila no está, se dice por qué en vez de
    # probar contra otro endpoint a la espalda de quien configuró el catálogo.
    # La clase sigue sin levantar — devuelve un Result inválido con el motivo,
    # que es lo que `Api::SapCredentialValidationsController` le muestra al usuario.
    it 'devuelve un motivo claro si la consulta no está en el catálogo' do
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get)

      result = validate

      expect(result).not_to be_valid
      expect(result.message).to include('qsValidateSapCredentials')
      # Y no se le pidió nada a SAP: el path no se pudo armar.
      expect(client).not_to have_received(:get)
    end

    # El caso que hacía falso-positivo antes de tener el rescue propio: con una
    # sesión viva en el pool, el rescue genérico habría reportado "válidas" sin
    # haber sondeado, porque solo mira si hay sesión.
    it 'no reporta válidas por una sesión vieja del pool cuando el catálogo está mal' do
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get)
      node = instance_double(Clavisco::ServiceLayer::Node, valid?: true)
      allow(Clavisco::ServiceLayer::LoadBalancer.instance).to receive(:get_existing_node).and_return(node)

      expect(validate).not_to be_valid
    end

    # REGRESIÓN. El pool del Client indexa por `session_owner_id|company_db|username`
    # (sin la contraseña) y `get_node` devuelve la sesión existente sin pasar por
    # `/Login`. Con una llave compartida, una sesión viva de ese usuario hacía que
    # CUALQUIER contraseña se reportara como válida. La llave única por intento es
    # lo que lo evita; si alguien la vuelve a compartir, este ejemplo falla.
    it 'no reutiliza una sesión previa del mismo usuario: siempre ejecuta el /Login' do
      SlResource.create!(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                         query_params: '$top=1&$select=CardCode', page_size: 0, is_standard: true)

      # Sesión viva bajo la llave que usaría una implementación con llave compartida.
      node = instance_double(Clavisco::ServiceLayer::Node, valid?: true, session_id: 'abcdef123',
                                                          touch!: nil)
      allow(node).to receive(:synchronize).and_yield
      allow(node).to receive(:execute).and_return(
        instance_double(Net::HTTPOK, code: '200', body: { value: [] }.to_json, :[] => 'application/json')
      )
      pool = Clavisco::ServiceLayer::LoadBalancer.instance
      pool.instance_variable_get(:@sessions)['credential-validation|SBO_ACME|manager'] = node

      login = stub_request(:post, 'https://sap.test:50000/b1s/v1/Login').to_return(
        status: 401,
        body: { error: { code: -304, message: { lang: 'en-us', value: 'Invalid user or password' } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

      result = described_class.for_company(company: company, sap_user: 'manager',
                                          sap_password: 'INCORRECTA').call

      expect(result).not_to be_valid
      # Lo que prueba el arreglo: se pidió el /Login en vez de reusar la sesión.
      expect(login).to have_been_requested
    ensure
      pool&.instance_variable_set(:@sessions, {})
    end

    it 'trata el rechazo del /Login como credenciales inválidas' do
      SlResource.create!(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                         query_params: '$top=1&$select=CardCode', page_size: 0, is_standard: true)
      error = Clavisco::ServiceLayer::Client::AuthenticationError.new('SL Login failed: usuario o clave incorrectos')
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get).and_raise(error)
      allow(client).to receive(:logout)

      result = validate

      expect(result).not_to be_valid
      # Sin el prefijo del cliente: al usuario le sirve el motivo de SAP.
      expect(result.message).to eq('usuario o clave incorrectos')
    end
  end

  # Es el camino de las credenciales de LICENCIA de una conexión: se prueban
  # desde el formulario, con una conexión que puede no estar guardada, así que no
  # hay compañía de la que derivar el destino.
  describe 'destino explícito (credenciales de licencia)' do
    def validate_license(base_url: 'https://sap.test:50000/b1s/v1/', company_db: 'SBO_ACME',
                         sap_user: 'licencia', sap_password: 'secreto')
      described_class.new(base_url: base_url, company_db: company_db,
                          sap_user: sap_user, sap_password: sap_password).call
    end

    it 'sondea contra la URL y la base recibidas, sin pasar por una compañía' do
      SlResource.create!(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                         query_params: '$top=1', page_size: 0, is_standard: true)
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Clavisco::ServiceLayer::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:logout)

      expect(validate_license).to be_valid
      expect(Clavisco::ServiceLayer::Client).to have_received(:new).with(
        hash_including(base_url: 'https://sap.test:50000/b1s/v1/', company_db: 'SBO_ACME',
                       username: 'licencia', password: 'secreto')
      )
    end

    # Los motivos por defecto no pueden hablar de "la compañía": acá no hay una, y
    # decirle eso a quien está llenando el formulario de conexiones lo mandaría a
    # buscar el problema al lugar equivocado.
    it 'pide la URL sin culpar a una compañía' do
      expect(validate_license(base_url: '').message)
        .to eq('No hay una URL de Service Layer contra la que probar.')
    end

    it 'pide la base de datos sin culpar a una compañía' do
      expect(validate_license(company_db: '').message)
        .to eq('Indique la base de datos de SAP contra la que probar.')
    end

    it 'acepta motivos propios del llamador' do
      result = described_class.new(
        base_url: '', company_db: 'SBO_ACME', sap_user: 'licencia', sap_password: 'secreto',
        missing_messages: { base_url: 'Ingrese la URL del Service Layer antes de probar.' }
      ).call

      expect(result.message).to eq('Ingrese la URL del Service Layer antes de probar.')
    end

    # Sobreescribir un motivo no puede dejar el otro en nil: un `missing_messages`
    # parcial se completa con los defaults.
    it 'conserva los motivos por defecto que el llamador no sobreescribió' do
      result = described_class.new(
        base_url: 'https://sap.test:50000/b1s/v1/', company_db: '',
        sap_user: 'licencia', sap_password: 'secreto',
        missing_messages: { base_url: 'Ingrese la URL del Service Layer antes de probar.' }
      ).call

      expect(result.message).to eq('Indique la base de datos de SAP contra la que probar.')
    end
  end
end

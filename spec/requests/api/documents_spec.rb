# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/documents', type: :request do
  let(:user)    { User.create!(email: 'documentos@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  # start_date/end_date son obligatorios (filtran DocDate) — se dan por
  # defecto acá para no repetirlos en cada `it` que no los pone a prueba.
  def get_documents(params = {})
    get '/api/documents', params: { start_date: '2026-01-01', end_date: '2026-01-31' }.merge(params)
  end

  before do
    SlResource.unscoped.find_or_initialize_by(code: 'getDocuments01').tap do |r|
      r.update!(resource: 'Invoices',
                query_params: '$select=DocEntry,CardName&$filter=(Series eq 72)',
                page_size: 0, is_active: true)
    end
    allow(Sap::CompanyClient).to receive(:for).and_return(client)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get_documents(doc_type: '01')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')
      get_documents(doc_type: '01')

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    it 'devuelve los documentos que trae SAP, sin un Total (no hay forma honesta de calcularlo)' do
      allow(client).to receive(:get).and_return([{ 'DocEntry' => 1, 'CardName' => 'ACME' }])

      get_documents(doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(body_data['Items']).to eq([{ 'DocEntry' => 1, 'CardName' => 'ACME' }])
      expect(body_data['HasMore']).to be(false)
      expect(body_data).not_to have_key('Total')
    end

    it 'HasMore es true cuando SAP devuelve una fila de más que per_page' do
      allow(client).to receive(:get).and_return(
        [{ 'DocEntry' => 1 }, { 'DocEntry' => 2 }, { 'DocEntry' => 3 }]
      )

      get_documents(doc_type: '01', per_page: 2)

      expect(body_data['Items'].size).to eq(2)
      expect(body_data['HasMore']).to be(true)
    end

    it 'rechaza un tipo de documento inválido' do
      get_documents(doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rechaza un mensaje de receptor (no es un documento consultable acá)' do
      get_documents(doc_type: '05')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rechaza la búsqueda sin fecha de inicio o final — son obligatorias' do
      get '/api/documents', params: { doc_type: '01', end_date: '2026-01-31' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to match(/fecha de inicio/)
    end

    it 'rechaza una fecha con formato distinto de AAAA-MM-DD' do
      get_documents(doc_type: '01', start_date: '01/01/2026')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to match(/formato/)
    end

    it 'responde con un error claro si la compañía no tiene SAP configurado' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'ACME no tiene una conexión de SAP asignada.')

      get_documents(doc_type: '01')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('ACME no tiene una conexión de SAP asignada.')
    end

    it 'traduce un error del Service Layer a un mensaje legible, sin filtrar el prefijo del cliente' do
      allow(client).to receive(:get).and_raise(
        Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error: boom', sap_message: 'Sesión inválida')
      )

      get_documents(doc_type: '01')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('Sesión inválida')
    end
  end
end

RSpec.describe 'GET /api/documents/:id', type: :request do
  let(:user)    { User.create!(email: 'documentos-show@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def get_document(id, params = {})
    get "/api/documents/#{id}", params: params
  end

  before do
    SlResource.unscoped.find_or_initialize_by(code: 'getDocumentErrorDetails01').tap do |r|
      r.update!(resource: 'Invoices(#DocEntry#)',
                query_params: '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails',
                page_size: 0, is_active: true)
    end
    allow(Sap::CompanyClient).to receive(:for).and_return(client)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')
      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    # La ENTIDAD por llave, con los nombres reales de los UDFs — no la vista de
    # cabecera, que devuelve alias (`Status`, `ErrDetails`) y dejaba los dos
    # campos en `nil` (ver el comentario de `Api::DocumentsController#show`).
    #
    # El `DocType` NO viaja en la consulta: elige la FILA del catálogo
    # (`getDocumentErrorDetails01`), que ya sabe contra qué entidad va.
    it 'consulta la entidad del documento con el DocEntry del path' do
      allow(client).to receive(:get).and_return({ 'U_CL_FEC_Status' => 6, 'U_CL_FEC_ErrorDetails' => nil })

      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:get)
        .with('Invoices(25)?$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails')
    end

    it 'devuelve el Status y el ErrorDetails ACTUALES del documento' do
      allow(client).to receive(:get).and_return(
        { 'U_CL_FEC_Status' => 7, 'U_CL_FEC_ErrorDetails' => 'La clave ya existe' }
      )

      get_document(25, doc_type: '01')

      expect(body_data).to eq({ 'Status' => 7, 'ErrorDetails' => 'La clave ya existe' })
    end

    it 'responde 404 si SAP no devuelve el documento' do
      allow(client).to receive(:get).and_return(nil)

      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:not_found)
    end

    # Un `DocEntry` que no existe: el Service Layer contesta 404 y el cliente lo
    # levanta como `NotFoundError`. Tiene que salir como 404 y no como 502.
    it 'responde 404 cuando el Service Layer dice que la entidad no existe' do
      allow(client).to receive(:get).and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('not found'))

      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:not_found)
    end

    it 'rechaza un tipo de documento inválido' do
      get_document(25, doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde con un error claro si la compañía no tiene SAP configurado' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'ACME no tiene una conexión de SAP asignada.')

      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('ACME no tiene una conexión de SAP asignada.')
    end

    it 'traduce un error del Service Layer a un mensaje legible' do
      allow(client).to receive(:get).and_raise(
        Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error: boom', sap_message: 'Sesión inválida')
      )

      get_document(25, doc_type: '01')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('Sesión inválida')
    end
  end
end

RSpec.describe 'GET /api/documents/:id/attempts', type: :request do
  let(:user)    { User.create!(email: 'documentos-intentos@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def get_attempts(id, params = {})
    get "/api/documents/#{id}/attempts", params: params
  end

  # El historial vive en la UDT de SAP, no en la cola propia: la fuente es el
  # Service Layer (`Sap::DocSyncAttempts`), con la consulta del catálogo — que
  # ya viene en el esquema de test por su migración, así que se hace upsert.
  before do
    SlResource.unscoped.find_or_initialize_by(code: 'getDocSyncAttempts').tap do |r|
      r.update!(resource: 'U_CL_FEC_DOCSYNCATTMP',
                query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)' \
                              '&$orderby=U_CreatedAt desc',
                page_size: 0, is_active: true)
    end
    allow(Sap::CompanyClient).to receive(:for).and_return(client)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')
      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    # `SAPDB` no viaja: la compañía ya la determina el cliente de SAP con el que
    # se consulta. Sí el par `DocEntry` + `DocType`, que es la llave del
    # documento dentro de la base.
    it 'consulta la UDT con el DocEntry del path y el DocType' do
      allow(client).to receive(:get).and_return([])

      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:get).with(
        "U_CL_FEC_DOCSYNCATTMP?$filter=(U_DocEntry eq 25 and U_DocType eq '01')&$orderby=U_CreatedAt desc"
      )
    end

    it 'devuelve los intentos con las llaves en PascalCase' do
      allow(client).to receive(:get).and_return(
        [{ 'U_CreatedAt' => '2026-09-05T10:03:12-06:00', 'U_Status' => 4, 'U_Details' => 'SAP no respondió' }]
      )

      get_attempts(25, doc_type: '01')

      expect(body_data['Items']).to eq(
        [{ 'CreatedAt' => '2026-09-05T10:03:12-06:00', 'StatusCode' => 4, 'Details' => 'SAP no respondió' }]
      )
    end

    it 'rechaza un tipo de documento inválido' do
      get_attempts(25, doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde con un error claro si la compañía no tiene SAP configurado' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'ACME no tiene una conexión de SAP asignada.')

      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('ACME no tiene una conexión de SAP asignada.')
    end

    it 'responde 502 traduciendo el error del Service Layer' do
      allow(client).to receive(:get).and_raise(
        Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error: boom', sap_message: 'Sesión inválida')
      )

      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('Sesión inválida')
    end
  end
end

RSpec.describe 'GET /api/documents/:id/mails', type: :request do
  let(:user)    { User.create!(email: 'documentos-correos@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def get_mails(id, params = {})
    get "/api/documents/#{id}/mails", params: params
  end

  # El historial de correos vive en la UDT de SAP, no en la tabla `OutgoingMails`
  # de la base propia que leía el .NET: la fuente es el Service Layer
  # (`Sap::MailQueue#list`), con la consulta del catálogo — que ya viene en el
  # esquema de test por su migración, así que se hace upsert.
  before do
    SlResource.unscoped.find_or_initialize_by(code: 'getDocumentMails').tap do |r|
      r.update!(resource: 'U_CL_FEC_MAILSDETAILS',
                query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)' \
                              '&$orderby=Code desc',
                page_size: 0, is_active: true)
    end
    allow(Sap::CompanyClient).to receive(:for).and_return(client)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get_mails(25, doc_type: '01')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')
      get_mails(25, doc_type: '01')

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    # El `docId` del .NET era el id de la tabla local; la llave acá es el par
    # `DocEntry` + `DocType`, que es con el que la UDT identifica el correo.
    it 'consulta la UDT con el DocEntry del path y el DocType' do
      allow(client).to receive(:get).and_return([])

      get_mails(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:get).with(
        "U_CL_FEC_MAILSDETAILS?$filter=(U_DocEntry eq 25 and U_DocType eq '01')&$orderby=Code desc"
      )
    end

    it 'devuelve los correos con las llaves en PascalCase' do
      allow(client).to receive(:get).and_return(
        [{ 'Code' => '8', 'U_CreatedAt' => '2026-09-11T10:03:12-06:00',
           'U_LastAttempt' => '2026-09-11T10:04:00-06:00', 'U_Status' => 4, 'U_Type' => 1,
           'U_OutputTo' => 'cliente@test.com', 'U_OutputCC' => 'copia@test.com', 'U_OutputBCC' => nil,
           'U_Email' => 'bandeja@acme.test', 'U_Details' => nil }]
      )

      get_mails(25, doc_type: '01')

      expect(body_data['Items']).to eq(
        [{ 'Code' => '8', 'CreatedAt' => '2026-09-11T10:03:12-06:00',
           'LastAttempt' => '2026-09-11T10:04:00-06:00', 'Status' => 4, 'Type' => 1,
           'OutputTo' => 'cliente@test.com', 'OutputCC' => 'copia@test.com', 'OutputBCC' => nil,
           'Sender' => 'bandeja@acme.test', 'Details' => nil }]
      )
    end

    it 'devuelve una lista vacía cuando el documento no tiene correos' do
      allow(client).to receive(:get).and_return([])

      get_mails(25, doc_type: '01')

      expect(body_data['Items']).to eq([])
    end

    it 'rechaza un tipo de documento inválido' do
      get_mails(25, doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde con un error claro si la compañía no tiene SAP configurado' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'ACME no tiene una conexión de SAP asignada.')

      get_mails(25, doc_type: '01')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('ACME no tiene una conexión de SAP asignada.')
    end

    # La consulta dada de baja desde la pantalla de mantenimiento no se ejecuta:
    # el error tiene que decir eso y no llegar como un 500.
    it 'responde 422 si la consulta no está en el catálogo' do
      SlResource.unscoped.where(code: 'getDocumentMails').update_all(is_active: false)

      get_mails(25, doc_type: '01')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('getDocumentMails')
    end

    it 'responde 502 traduciendo el error del Service Layer' do
      allow(client).to receive(:get).and_raise(
        Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error: boom', sap_message: 'Sesión inválida')
      )

      get_mails(25, doc_type: '01')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('Sesión inválida')
    end
  end
end

# El botón "Reenviar" del panel "Correos". Reemplaza `POST /api/Email/` del .NET
# (`spResendDocEmail`), que insertaba en la tabla `OutgoingMails` de la base
# propia. Acá son DOS escrituras: la fila de la UDT (el detalle) y la de la cola
# externa (el disparador real del envío).
RSpec.describe 'POST /api/documents/:id/mails', type: :request do
  let(:user)    { User.create!(email: 'documentos-reenvio@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }
  let(:odbc_client) { instance_double(ExternalDb::Client) }

  # El correo de tipo Envío (1) del documento: el original, del que se copian los
  # destinatarios cuando no se indican otros.
  let(:original_mail) do
    { 'Code' => '8', 'U_CreatedAt' => '2026-09-11T10:03:12-06:00', 'U_Status' => 3, 'U_Type' => 1,
      'U_OutputTo' => 'cliente@test.com', 'U_OutputCC' => 'copia@test.com',
      'U_OutputBCC' => 'oculta@test.com', 'U_Details' => 'SMTP rechazó la conexión' }
  end

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body = JSON.parse(response.body)

  def resend(id, params = {})
    post "/api/documents/#{id}/mails", params: { doc_type: '01' }.merge(params)
  end

  before do
    SlResource.unscoped.find_or_initialize_by(code: 'getDocumentMails').tap do |r|
      r.update!(resource: 'U_CL_FEC_MAILSDETAILS',
                query_params: '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=Code desc',
                page_size: 0, is_active: true)
    end
    SlResource.unscoped.find_or_initialize_by(code: 'createDocumentMail').tap do |r|
      r.update!(resource: 'U_CL_FEC_MAILSDETAILS', query_params: nil, page_size: 0, is_active: true)
    end

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
    allow(client).to receive(:get).and_return([original_mail])
    allow(client).to receive(:post).and_return({ 'Code' => '9' })
    allow(ExternalDb::Pool).to receive(:with).with(Documents::MailQueue::GROUP_CODE).and_yield(odbc_client)
    allow(odbc_client).to receive(:call).and_return([])
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      resend(25)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')
      resend(25)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    context 'con otros destinatarios' do
      it 'crea la fila con lo que se escribió, en tipo Reenvío y estado Pendiente' do
        resend(25, OtherEmails: true, MailTo: 'otro@test.com', MailCC: 'otrocc@test.com')

        expect(response).to have_http_status(:ok)
        expect(client).to have_received(:post).with('U_CL_FEC_MAILSDETAILS', body: hash_including(
          'U_DocEntry' => 25,
          'U_DocType' => '01',
          'U_Status' => Documents::MailQueue::STATUS_PENDING,
          'U_Type' => Sap::MailQueue::TYPE_RESEND,
          'U_OutputTo' => 'otro@test.com',
          'U_OutputCC' => 'otrocc@test.com'
        ))
      end

      # Los destinatarios escritos REEMPLAZAN a los originales; no se mezclan con
      # ellos ni se arrastra la copia oculta del envío anterior, que iría a
      # alguien que quien reenvía no eligió y no puede ver.
      it 'no arrastra la copia oculta del correo original' do
        resend(25, OtherEmails: true, MailTo: 'otro@test.com')

        expect(client).to have_received(:post).with(anything, body: hash_including(
          'U_OutputCC' => nil, 'U_OutputBCC' => nil
        ))
      end

      it 'rechaza el reenvío sin "Para"' do
        resend(25, OtherEmails: true, MailTo: '', MailCC: 'solocc@test.com')

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('Indique al menos un destinatario en "Para".')
        expect(client).not_to have_received(:post)
      end
    end

    context 'sin otros destinatarios' do
      # Los TRES campos del correo de tipo Envío: el reenvío es el mismo correo
      # saliendo de nuevo, y dejar afuera la copia oculta cambiaría en silencio
      # quién lo recibe.
      it 'copia los destinatarios del correo de tipo Envío' do
        resend(25, OtherEmails: false)

        expect(response).to have_http_status(:ok)
        expect(client).to have_received(:post).with(anything, body: hash_including(
          'U_Type' => Sap::MailQueue::TYPE_RESEND,
          'U_OutputTo' => 'cliente@test.com',
          'U_OutputCC' => 'copia@test.com',
          'U_OutputBCC' => 'oculta@test.com'
        ))
      end

      # Sin el original no hay de dónde copiar, y mandar un correo sin
      # destinatario no es una opción: se dice qué hacer en su lugar.
      it 'responde 422 si el documento no tiene un correo de tipo Envío' do
        allow(client).to receive(:get).and_return([original_mail.merge('U_Type' => 2)])

        resend(25, OtherEmails: false)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to include('no tiene un correo de envío original')
        expect(client).not_to have_received(:post)
      end
    end

    # La fila de la UDT es el DETALLE; la de la cola externa es lo que hace que
    # `SendElectronicReceiptJob` mire este documento. Sin la segunda, el reenvío
    # queda registrado y no lo manda nadie.
    # La fila de la cola lleva el `Code` que devolvió el POST a la UDT: es el
    # enlace por el que el job sabe qué correo manda. Y va con tipo Reenvío, que
    # es lo que hace que el procedimiento NO aplique su dedupe.
    it 'encola el envío en la cola externa con el Code de la UDT y el tipo Reenvío' do
      resend(25, OtherEmails: false)

      expect(odbc_client).to have_received(:call).with(
        Documents::MailQueue::CREATE_PROCEDURE,
        ['SBO_ACME', 25, '01', 9, Sap::MailQueue::TYPE_RESEND], commit: true
      )
    end

    # Sin `Code` no hay enlace, y una fila de cola que no dice qué mandar la
    # termina marcando en Error el job. Mejor no encolar y decirlo.
    it 'no encola si SAP no devolvió el Code del correo registrado' do
      allow(client).to receive(:post).and_return({})

      resend(25, OtherEmails: false)

      expect(response).to have_http_status(:bad_gateway)
      expect(odbc_client).not_to have_received(:call)
    end

    it 'rechaza un tipo de documento inválido' do
      resend(25, doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde con un error claro si la compañía no tiene SAP configurado' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'ACME no tiene una conexión de SAP asignada.')

      resend(25, OtherEmails: false)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('ACME no tiene una conexión de SAP asignada.')
    end

    it 'responde 502 traduciendo el error del Service Layer' do
      allow(client).to receive(:post).and_raise(
        Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error: boom', sap_message: 'Sesión inválida')
      )

      resend(25, OtherEmails: false)

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('Sesión inválida')
    end

    it 'responde 502 si la cola externa no responde' do
      allow(ExternalDb::Pool).to receive(:with).and_raise(ExternalDb::Error, 'la base no responde')

      resend(25, OtherEmails: false)

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('la base no responde')
    end
  end
end

RSpec.describe 'PATCH /api/documents/:id/reprocess', type: :request do
  let(:user)    { User.create!(email: 'documentos-reprocess@example.com', name: 'Ana Pérez') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:odbc_client) { instance_double(ExternalDb::Client) }

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  def body = JSON.parse(response.body)

  def reprocess(id, params = {})
    patch "/api/documents/#{id}/reprocess", params: params
  end

  def stub_procedure(rows)
    allow(ExternalDb::Pool).to receive(:with).with(Documents::PendingQueue::GROUP_CODE).and_yield(odbc_client)
    allow(odbc_client).to receive(:call).and_return(rows)
  end

  # Las dos consultas del catálogo que usa `#record_reprocess_in_sap`: el POST
  # del intento a la UDT y el PATCH del estado del comprobante. La primera ya
  # viene en el esquema de test por su migración, así que se hace upsert.
  def stub_sap_resources
    SlResource.unscoped.find_or_initialize_by(code: 'createDocSyncAttempt').tap do |r|
      r.update!(resource: 'U_CL_FEC_DOCSYNCATTMP', query_params: nil, page_size: 0, is_active: true)
    end
    SlResource.create!(code: 'updateDocument01', resource: 'Invoices(#DocumentEntry#)', page_size: 0)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Emission_Reprocess' do
      sign_in_with('Documents_Emission_Reprocess_Otro')
      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Emission_Reprocess') }

    # Tres parámetros, no cuatro: el SP dejó de recibir `@Details` cuando el
    # historial de intentos pasó a la UDT de SAP.
    it 'reencola el documento con el DocEntry del path, el SAPDB de la compañía activa y el DocType' do
      stub_procedure([{ 'Id' => 7 }])

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(odbc_client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_UPT_REPROCESSDOCUMENT', [25, 'SBO_ACME', '01'], commit: true
      )
    end

    # Quién pidió el reprocesamiento es el detalle del intento, y vive en la UDT
    # (`Sap::DocSyncAttempts`) — la cola solo guarda el estado.
    it 'registra el intento en la UDT con el nombre del usuario en sesión' do
      stub_procedure([{ 'Id' => 7 }])
      stub_sap_resources
      sl_client = instance_double(Clavisco::ServiceLayer::Client, post: { 'Code' => '9' }, patch: nil)
      allow(Sap::UserClient).to receive(:for).with(company, user: user).and_return(sl_client)

      reprocess(25, doc_type: '01')

      expect(sl_client).to have_received(:post).with('U_CL_FEC_DOCSYNCATTMP', body: hash_including(
        'U_DocEntry' => 25,
        'U_DocType' => '01',
        'U_Status' => Documents::PendingQueue::STATUS_REPROCESS,
        'U_Details' => 'Reprocesamiento solicitado por Ana Pérez'
      ))
    end

    it 'responde con error cuando el documento no está Rechazado (el SP no devolvió fila)' do
      stub_procedure([])

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to match(/Rechazado/)
    end

    it 'rechaza un tipo de documento inválido' do
      reprocess(25, doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde 502 si la base de documentos no responde' do
      allow(ExternalDb::Pool).to receive(:with).with(Documents::PendingQueue::GROUP_CODE)
                                               .and_raise(ExternalDb::ConnectionError, 'no se pudo conectar')

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('no se pudo conectar')
    end

    # `company` (sin `sap_connection` en este spec) hace que
    # `Sap::UserClient.for` levante `MissingConfiguration` — el mismo criterio
    # tolerante de `SyncIssuedDocumentsJob#mark_sap`: la cola es la fuente de
    # verdad y ya quedó reencolada, así que la respuesta sigue en 200.
    it 'no falla la respuesta si la compañía no tiene SAP configurado (best-effort)' do
      stub_procedure([{ 'Id' => 7 }])

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
    end

    # Sin credenciales personales de SAP, `Sap::UserClient.for` también levanta
    # `MissingConfiguration` — mismo criterio tolerante, aunque la compañía SÍ
    # tenga conexión: falta la mitad de "usuario en sesión + compañía".
    it 'no falla la respuesta si el usuario no tiene credenciales propias de SAP (best-effort)' do
      stub_procedure([{ 'Id' => 7 }])
      Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1/').tap do |c|
        company.update!(connection_id: c.id)
      end

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
    end

    it 'marca SOLO U_CL_FEC_Status en SAP con las credenciales del usuario en sesión' do
      stub_procedure([{ 'Id' => 7 }])
      stub_sap_resources
      sl_client = instance_double(Clavisco::ServiceLayer::Client, post: { 'Code' => '9' }, patch: nil)
      allow(Sap::UserClient).to receive(:for).with(company, user: user).and_return(sl_client)

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(sl_client).to have_received(:patch).with(
        'Invoices(25)', body: { 'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_REPROCESS }
      )
    end
  end
end

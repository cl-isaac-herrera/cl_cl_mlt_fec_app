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

RSpec.describe 'GET /api/documents/:id/attempts', type: :request do
  let(:user)    { User.create!(email: 'documentos-intentos@example.com') }
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

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def get_attempts(id, params = {})
    get "/api/documents/#{id}/attempts", params: params
  end

  def stub_procedure(rows)
    allow(ExternalDb::Pool).to receive(:with).with(Documents::AttemptDetails::GROUP_CODE).and_yield(odbc_client)
    allow(odbc_client).to receive(:call).and_return(rows)
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

    it 'consulta la cola con el SAPDB de la compañía activa, el DocEntry del path y el DocType' do
      stub_procedure([])

      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(odbc_client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_SLT_DOCUMENTATTEMPS', ['SBO_ACME', 25, '01']
      )
    end

    it 'devuelve los intentos con las llaves en PascalCase' do
      stub_procedure([{ 'CreatedAt' => Time.new(2026, 9, 5, 10, 3, 12), 'StatusCode' => 4,
                        'Details' => 'SAP no respondió' }])

      get_attempts(25, doc_type: '01')

      expect(body_data['Items']).to eq(
        [{ 'CreatedAt' => '2026-09-05 10:03:12', 'StatusCode' => 4, 'Details' => 'SAP no respondió' }]
      )
    end

    it 'rechaza un tipo de documento inválido' do
      get_attempts(25, doc_type: 'XX')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde 502 si la base de documentos no responde' do
      allow(ExternalDb::Pool).to receive(:with).with(Documents::AttemptDetails::GROUP_CODE)
                                               .and_raise(ExternalDb::ConnectionError, 'no se pudo conectar')

      get_attempts(25, doc_type: '01')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('no se pudo conectar')
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

    it 'reencola el documento con el SAPDB de la compañía activa, el DocEntry del path y el DocType' do
      stub_procedure([{ 'Id' => 7 }])

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(odbc_client).to have_received(:call).with(
        'CL_D_CL_MLT_FEC_UPT_REPROCESSDOCUMENT', [25, 'SBO_ACME', '01', anything], commit: true
      )
    end

    it 'arma el detalle con el nombre del usuario en sesión' do
      stub_procedure([{ 'Id' => 7 }])

      reprocess(25, doc_type: '01')

      expect(odbc_client).to have_received(:call).with(
        anything, [anything, anything, anything, 'Reprocesamiento solicitado por Ana Pérez'], commit: true
      )
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
      SlResource.create!(code: 'updateDocument01', resource: 'Invoices(#DocumentEntry#)', page_size: 0)
      sl_client = instance_double(Clavisco::ServiceLayer::Client, patch: nil)
      allow(Sap::UserClient).to receive(:for).with(company, user: user).and_return(sl_client)

      reprocess(25, doc_type: '01')

      expect(response).to have_http_status(:ok)
      expect(sl_client).to have_received(:patch).with(
        'Invoices(25)', body: { 'U_CL_FEC_Status' => Documents::PendingQueue::STATUS_REPROCESS }
      )
    end
  end
end

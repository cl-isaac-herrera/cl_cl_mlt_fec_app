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
      get '/api/documents', params: { doc_type: '01' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')
      get '/api/documents', params: { doc_type: '01' }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    it 'devuelve los documentos que trae SAP, sin un Total (no hay forma honesta de calcularlo)' do
      allow(client).to receive(:get).and_return([{ 'DocEntry' => 1, 'CardName' => 'ACME' }])

      get '/api/documents', params: { doc_type: '01' }

      expect(response).to have_http_status(:ok)
      expect(body_data['Items']).to eq([{ 'DocEntry' => 1, 'CardName' => 'ACME' }])
      expect(body_data['HasMore']).to be(false)
      expect(body_data).not_to have_key('Total')
    end

    it 'HasMore es true cuando SAP devuelve una fila de más que per_page' do
      allow(client).to receive(:get).and_return(
        [{ 'DocEntry' => 1 }, { 'DocEntry' => 2 }, { 'DocEntry' => 3 }]
      )

      get '/api/documents', params: { doc_type: '01', per_page: 2 }

      expect(body_data['Items'].size).to eq(2)
      expect(body_data['HasMore']).to be(true)
    end

    it 'rechaza un tipo de documento inválido' do
      get '/api/documents', params: { doc_type: 'XX' }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rechaza un mensaje de receptor (no es un documento consultable acá)' do
      get '/api/documents', params: { doc_type: '05' }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde con un error claro si la compañía no tiene SAP configurado' do
      allow(Sap::CompanyClient).to receive(:for)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'ACME no tiene una conexión de SAP asignada.')

      get '/api/documents', params: { doc_type: '01' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('ACME no tiene una conexión de SAP asignada.')
    end

    it 'traduce un error del Service Layer a un mensaje legible, sin filtrar el prefijo del cliente' do
      allow(client).to receive(:get).and_raise(
        Clavisco::ServiceLayer::Client::ServiceLayerError.new('SL error: boom', sap_message: 'Sesión inválida')
      )

      get '/api/documents', params: { doc_type: '01' }

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to eq('Sesión inválida')
    end
  end
end

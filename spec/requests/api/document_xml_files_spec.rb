# frozen_string_literal: true

require 'rails_helper'

# Las dos descargas de XML del listado de documentos emitidos. Reemplazan
# `GET /api/Documents/GetXMLDoc` y `DownloadDocumentXML` del .NET.
#
# El XML no está en SAP: SAP guarda su URL de Azure en `U_CL_FEC_XmlSentUrl` /
# `U_CL_FEC_XmlResponseUrl`, y el endpoint la resuelve por `DocEntry` antes de
# bajar el blob — nunca la acepta del cliente.
RSpec.describe 'Api::Documents::XmlFiles', type: :request do
  let(:user)    { User.create!(email: 'documentos@example.com') }
  let(:role)    { Role.create!(name: 'Configurador') }
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  let(:client)  { instance_double(Clavisco::ServiceLayer::Client) }

  let(:account)   { 'clviscofe' }
  let(:key)       { Base64.strict_encode64('una-clave-de-prueba-cualquiera') }
  let(:container) { 'clvsfe' }

  let(:clave)        { '50601012600310182273300100001010000000011199999999' }
  let(:sent_url)     { blob_url("3101822733/#{clave}.xml") }
  let(:response_url) { blob_url("3101822733/#{clave}_respuesta.xml") }

  def blob_url(path) = "https://#{account}.blob.core.windows.net/#{container}/#{path}"

  def body = JSON.parse(response.body)

  def azure_setting(code, value, is_visible: true)
    Setting.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.group_code  = 'AZURE_STORAGE'
      record.description = code
      record.is_visible  = is_visible
      record.value       = value
      record.save!
    end
  end

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: company)
    UserRole.create!(user: user, role: role, company: company)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: company)
  end

  # Lo que SAP devuelve para `Invoices(25)?$select=U_CL_FEC_XmlSentUrl,…`.
  def stub_sap(row)
    allow(client).to receive(:get).with('Invoices(25)?$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl')
                                  .and_return(row)
  end

  def get_xml(kind, doc_entry: 25, doc_type: '01')
    get "/api/documents/#{doc_entry}/xml_files/#{kind}", params: { doc_type: doc_type }
  end

  before do
    SlResource.unscoped.find_or_initialize_by(code: 'getDocumentXmlUrls01').tap do |record|
      record.update!(resource: 'Invoices(#DocEntry#)',
                     query_params: '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl',
                     page_size: 0, is_active: true)
    end

    azure_setting('AZURE_STORAGE_ACCOUNT_NAME', account)
    azure_setting('AZURE_STORAGE_ACCOUNT_KEY', key, is_visible: false)
    azure_setting('AZURE_STORAGE_CONTAINER', container)

    allow(Sap::CompanyClient).to receive(:for).and_return(client)
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      get_xml('sent')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Documents_Issued_ViewDocuments' do
      sign_in_with('Documents_Issued_ViewDocuments_Otro')

      get_xml('sent')

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'con permiso' do
    before { sign_in_with('Documents_Issued_ViewDocuments') }

    it 'baja el XML del comprobante con el nombre con el que quedó archivado' do
      stub_sap('U_CL_FEC_XmlSentUrl' => sent_url, 'U_CL_FEC_XmlResponseUrl' => response_url)
      request = stub_request(:get, sent_url).to_return(status: 200, body: '<FacturaElectronica/>')

      get_xml('sent')

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('<FacturaElectronica/>')
      expect(response.media_type).to eq('application/xml')
      expect(response.headers['Content-Disposition']).to include("#{clave}.xml")
      expect(request).to have_been_made.once
    end

    it 'baja el XML de respuesta desde la OTRA URL del documento' do
      stub_sap('U_CL_FEC_XmlSentUrl' => sent_url, 'U_CL_FEC_XmlResponseUrl' => response_url)
      request = stub_request(:get, response_url).to_return(status: 200, body: '<MensajeHacienda/>')

      get_xml('response')

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to include("#{clave}_respuesta.xml")
      expect(request).to have_been_made.once
    end

    # HANA devuelve los identificadores en MAYÚSCULAS y el mismo catálogo sirve
    # a las dos bases: leer con `row['U_CL_FEC_XmlSentUrl']` daría `nil` ahí.
    it 'lee el campo sin importar la caja con la que lo devuelva la base' do
      stub_sap('U_CL_FEC_XMLSENTURL' => sent_url)
      stub_request(:get, sent_url).to_return(status: 200, body: '<FacturaElectronica/>')

      get_xml('sent')

      expect(response).to have_http_status(:ok)
    end

    it 'responde 404 con el motivo cuando el documento no tiene ese XML archivado' do
      stub_sap('U_CL_FEC_XmlSentUrl' => sent_url, 'U_CL_FEC_XmlResponseUrl' => nil)

      get_xml('response')

      expect(response).to have_http_status(:not_found)
      expect(body['Message']).to eq('Este documento todavía no tiene un XML de respuesta archivado: ' \
                                    'se guarda cuando Hacienda lo acepta o lo rechaza.')
    end

    it 'responde 404 cuando el archivo pedido no es ninguno de los dos' do
      get_xml('otro')

      expect(response).to have_http_status(:not_found)
      expect(body['Message']).to eq('El archivo XML solicitado no existe.')
    end

    it 'responde 404 cuando SAP no encuentra el documento' do
      allow(client).to receive(:get)
        .and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('SL 404'))

      get_xml('sent')

      expect(response).to have_http_status(:not_found)
      expect(body['Message']).to eq('SAP no devolvió el documento solicitado.')
    end

    it 'rechaza un mensaje de receptor (no es un comprobante emitido)' do
      get_xml('sent', doc_type: '05')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde 422 cuando el tipo de documento no tiene consulta en el catálogo' do
      SlResource.unscoped.where(code: 'getDocumentXmlUrls02').delete_all

      get_xml('sent', doc_type: '02')

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'responde 502 cuando Azure rechaza la descarga' do
      stub_sap('U_CL_FEC_XmlSentUrl' => sent_url)
      stub_request(:get, sent_url).to_return(status: 403, body: '')

      get_xml('sent')

      expect(response).to have_http_status(:bad_gateway)
      expect(body['Message']).to include('Azure Storage rechazó la descarga')
    end

    # La URL sale de SAP y de la compañía activa: pasarla en el pedido no puede
    # cambiar de qué carpeta (y por lo tanto, de qué contribuyente) se baja.
    it 'ignora cualquier URL que venga en el pedido' do
      stub_sap('U_CL_FEC_XmlSentUrl' => sent_url)
      mine  = stub_request(:get, sent_url).to_return(status: 200, body: '<FacturaElectronica/>')
      other = stub_request(:get, blob_url('9999999999/ajeno.xml')).to_return(status: 200, body: '<Ajeno/>')

      get '/api/documents/25/xml_files/sent',
          params: { doc_type: '01', url: blob_url('9999999999/ajeno.xml') }

      expect(response.body).to eq('<FacturaElectronica/>')
      expect(mine).to have_been_made.once
      expect(other).not_to have_been_made
    end
  end

  it 'responde 403 cuando la compañía activa no es del usuario' do
    UserRole.create!(user: user, role: role, company: company)
    RolePermission.create!(role: role,
                           permission: Permission.find_or_create_by!(name: 'Documents_Issued_ViewDocuments'))
    sign_in(user, company: company)

    get_xml('sent')

    expect(response).to have_http_status(:forbidden)
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::CompanyConfig do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # Las tres filas ya vienen en el esquema de test, insertadas por la migración
  # que completa el catálogo (`20260922100000_add_company_config_sl_resources.rb`).
  def upsert_resource(code, resource:)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: resource, query_params: nil, page_size: 0, is_active: true)
    end
  end

  before do
    upsert_resource('getCompanyConfig', resource: 'U_CL_FEC_ISSUERCONFIG(1)')
    upsert_resource('createCompanyConfig', resource: 'U_CL_FEC_ISSUERCONFIG')
    upsert_resource('updateCompanyConfig', resource: 'U_CL_FEC_ISSUERCONFIG(1)')
  end

  subject(:company_config) { described_class.new(client: client, actor: 'user@acme.cr') }

  def sap_row(legal_name: 'ACME S.A.', id_type: '02', economic_activity_code: '620100',
              tax_registry_8707: nil)
    {
      'Code' => '1', 'U_LegalName' => legal_name, 'U_CommercialName' => 'ACME',
      'U_IdNumber' => '3101822733', 'U_IdType' => id_type,
      'U_EconomicActivityCode' => economic_activity_code, 'U_TaxRegistry8707' => tax_registry_8707,
      'U_UpdatedAt' => '2026-09-20T10:00:00-06:00', 'U_UpdatedBy' => 'seed@acme.cr'
    }
  end

  def valid_attributes(overrides = {})
    { legal_name: 'ACME S.A.', commercial_name: 'ACME', id_number: '3101822733', id_type: '02',
      economic_activity_code: '620100', tax_registry_8707: nil }.merge(overrides)
  end

  describe '#read' do
    it 'arma la configuración con los datos de la UDT' do
      allow(client).to receive(:get).and_return(sap_row)

      config = company_config.read

      expect(config.legal_name).to eq('ACME S.A.')
      expect(config.commercial_name).to eq('ACME')
      expect(config.id_number).to eq('3101822733')
      expect(config.id_type).to eq('02')
      expect(config.economic_activity_code).to eq('620100')
    end

    it 'consulta la fila fija (Code 1)' do
      allow(client).to receive(:get).and_return(sap_row)

      company_config.read

      expect(client).to have_received(:get).with('U_CL_FEC_ISSUERCONFIG(1)')
    end

    it 'devuelve nil cuando la fila todavía no se creó' do
      allow(client).to receive(:get)
        .and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('not found'))

      expect(company_config.read).to be_nil
    end
  end

  describe '#create' do
    it 'manda las columnas del emisor y quién escribe' do
      allow(client).to receive(:post)

      company_config.create(valid_attributes)

      expect(client).to have_received(:post).with(
        'U_CL_FEC_ISSUERCONFIG',
        body: hash_including('U_LegalName' => 'ACME S.A.', 'U_CommercialName' => 'ACME',
                              'U_IdNumber' => '3101822733', 'U_IdType' => '02',
                              'U_EconomicActivityCode' => '620100', 'U_UpdatedBy' => 'user@acme.cr')
      )
    end

    it 'rechaza un tipo de identificación fuera del catálogo' do
      expect { company_config.create(valid_attributes(id_type: '99')) }
        .to raise_error(Sap::CompanyConfig::InvalidConfig, /tipo de identificación/)
    end

    it 'rechaza un valor más largo que el que acepta la UDT' do
      expect { company_config.create(valid_attributes(tax_registry_8707: '1' * 13)) }
        .to raise_error(Sap::CompanyConfig::InvalidConfig, /registro fiscal/)
    end

    it 'rechaza una cédula más larga que la columna de la UDT' do
      expect { company_config.create(valid_attributes(id_number: '1' * 21)) }
        .to raise_error(Sap::CompanyConfig::InvalidConfig, /número de identificación/)
    end
  end

  describe '#update' do
    it 'manda SOLO las llaves presentes — PATCH parcial' do
      allow(client).to receive(:patch)

      company_config.update(legal_name: 'ACME Costa Rica S.A.')

      expect(client).to have_received(:patch).with(
        'U_CL_FEC_ISSUERCONFIG(1)',
        body: { 'U_LegalName' => 'ACME Costa Rica S.A.', 'U_UpdatedAt' => anything,
                'U_UpdatedBy' => 'user@acme.cr' }
      )
    end

    it 'no manda U_IdType cuando no vino en la petición' do
      allow(client).to receive(:patch)

      company_config.update(economic_activity_code: '620100')

      expect(client).to have_received(:patch) do |_path, body:|
        expect(body).not_to have_key('U_IdType')
      end
    end

    # Compañías dadas de alta antes de que existiera la UDT (o cuyo `create`
    # nunca corrió) no tienen fila en SAP: el PATCH responde 404 y el `update`
    # se autocura creando la fila en vez de fallar.
    it 'crea la fila si todavía no existe (404 al actualizar)' do
      allow(client).to receive(:patch)
        .and_raise(Clavisco::ServiceLayer::Client::NotFoundError.new('Entity with value(1) does not exist'))
      allow(client).to receive(:post)

      company_config.update(legal_name: 'ACME Costa Rica S.A.')

      expect(client).to have_received(:post).with(
        'U_CL_FEC_ISSUERCONFIG',
        body: hash_including('U_LegalName' => 'ACME Costa Rica S.A.')
      )
    end
  end
end

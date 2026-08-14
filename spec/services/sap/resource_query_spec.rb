# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::ResourceQuery do
  def create_resource(code:, resource:, query_params: nil, page_size: 0)
    SlResource.create!(code: code, resource: resource, query_params: query_params,
                       page_size: page_size, is_standard: true)
  end

  describe '#path' do
    it 'pega la query cruda al recurso, sin form-encoding' do
      create_resource(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                      query_params: '$top=1&$select=CardCode')

      # Lo que NO debe pasar es `%24top=1`: el Service Layer no reconoce el `$`
      # escapado como opción de sistema. Por eso no se usa el `params:` del Client.
      expect(described_class.new('qsValidateSapCredentials').path)
        .to eq('BusinessPartners?$top=1&$select=CardCode')
    end

    it 'devuelve solo el recurso cuando la consulta no lleva query' do
      create_resource(code: 'Drafts', resource: 'Drafts')

      expect(described_class.new('Drafts').path).to eq('Drafts')
    end

    it 'preserva el orden y los paréntesis del $filter' do
      create_resource(code: 'GetTaxes', resource: 'view.svc/CL_TAXES_B1SLQuery',
                      query_params: '$filter=(contains(TaxCode, @Vm) and Rate gt @Rate)&$top=5')

      expect(described_class.new('GetTaxes', bindings: { Vm: 'IVA', Rate: 13 }).path)
        .to eq("view.svc/CL_TAXES_B1SLQuery?$filter=(contains(TaxCode, 'IVA') and Rate gt 13)&$top=5")
    end
  end

  describe 'marcadores de la query (@Nombre)' do
    before do
      create_resource(code: 'CheckIfExistApInvoice', resource: 'view.svc/CL_CHECK_B1SLQuery',
                      query_params: '$filter=(U_FeNumProvRef eq @Clave)')
    end

    it 'formatea los strings como literal OData, con comillas simples' do
      query = described_class.new('CheckIfExistApInvoice', bindings: { Clave: '506123' })

      expect(query.query).to eq("$filter=(U_FeNumProvRef eq '506123')")
    end

    it 'duplica las comillas simples del valor, que es como OData las escapa' do
      query = described_class.new('CheckIfExistApInvoice', bindings: { Clave: "O'Brien" })

      expect(query.query).to eq("$filter=(U_FeNumProvRef eq 'O''Brien')")
    end

    it 'no encomilla los números ni los booleanos' do
      create_resource(code: 'GetByNum', resource: 'Orders',
                      query_params: '$filter=(DocNum eq @Num and Canceled eq @Flag)')

      query = described_class.new('GetByNum', bindings: { Num: 42, Flag: false })

      expect(query.query).to eq('$filter=(DocNum eq 42 and Canceled eq false)')
    end

    it 'acepta la clave como símbolo o como string' do
      con_simbolo = described_class.new('CheckIfExistApInvoice', bindings: { Clave: 'X' }).query
      con_string  = described_class.new('CheckIfExistApInvoice', bindings: { 'Clave' => 'X' }).query

      expect(con_simbolo).to eq(con_string)
    end

    # Sin esto el `@Clave` viajaría literal a SAP y el error de OData no diría
    # nada sobre el parámetro que faltó.
    it 'levanta si un marcador quedó sin valor' do
      expect { described_class.new('CheckIfExistApInvoice').query }
        .to raise_error(described_class::MissingBinding, /'Clave'/)
    end
  end

  describe 'marcadores del path (#Nombre#)' do
    before do
      create_resource(code: 'ClosePurchaseOrders', resource: 'PurchaseOrders(#DocumentEntry#)/Close')
    end

    it 'los reemplaza crudos, sin encomillar: son parte del path' do
      expect(described_class.new('ClosePurchaseOrders', bindings: { DocumentEntry: 42 }).path)
        .to eq('PurchaseOrders(42)/Close')
    end

    # Un valor con `/` o `?` cambiaría a qué endpoint se le está pegando.
    it 'rechaza un valor que podría alterar la URL' do
      expect { described_class.new('ClosePurchaseOrders', bindings: { DocumentEntry: '1)/Cancel?x=' }).path }
        .to raise_error(described_class::UnsafeBinding, /DocumentEntry/)
    end
  end

  describe '#params' do
    it 'descompone la query con la forma que usa el submódulo' do
      create_resource(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                      query_params: '$top=1&$select=CardCode')

      expect(described_class.new('qsValidateSapCredentials').params)
        .to eq({ '$top' => '1', '$select' => 'CardCode' })
    end

    it 'separa por el primer = , así que un valor con = queda entero' do
      create_resource(code: 'GetRaro', resource: 'Orders', query_params: '$filter=(A eq B=C)')

      expect(described_class.new('GetRaro').params).to eq({ '$filter' => '(A eq B=C)' })
    end

    it 'es un hash vacío cuando no hay query' do
      create_resource(code: 'Drafts', resource: 'Drafts')

      expect(described_class.new('Drafts').params).to eq({})
    end
  end

  describe '#merge' do
    before do
      create_resource(code: 'GetSuppliers', resource: 'view.svc/CL_SUPPLIERS_B1SLQuery',
                      query_params: '$select=*')
    end

    it 'agrega opciones sin concatenar strings a mano' do
      expect(described_class.new('GetSuppliers').merge('$top' => 50).path)
        .to eq('view.svc/CL_SUPPLIERS_B1SLQuery?$select=*&$top=50')
    end

    it 'sobreescribe una opción existente' do
      expect(described_class.new('GetSuppliers').merge('$select' => 'CardCode').query)
        .to eq('$select=CardCode')
    end

    it 'no muta la consulta original' do
      query = described_class.new('GetSuppliers')
      query.merge('$top' => 50)

      expect(query.query).to eq('$select=*')
    end
  end

  describe 'resolución del código' do
    it 'levanta cuando el código no existe' do
      expect { described_class.new('NoExiste').path }
        .to raise_error(described_class::UnknownResource, /'NoExiste'/)
    end

    # Una consulta dada de baja no se debe ejecutar: el `default_scope` de
    # SoftDeletable la deja fuera y acá eso es lo correcto.
    it 'levanta cuando la consulta está dada de baja' do
      create_resource(code: 'Vieja', resource: 'Orders').update!(is_active: false)

      expect { described_class.new('Vieja').path }
        .to raise_error(described_class::UnknownResource)
    end
  end

  describe '.path_for' do
    it 'resuelve el path de un tirón' do
      create_resource(code: 'qsValidateSapCredentials', resource: 'BusinessPartners',
                      query_params: '$top=1&$select=CardCode')

      expect(described_class.path_for('qsValidateSapCredentials'))
        .to eq('BusinessPartners?$top=1&$select=CardCode')
    end

    it 'acepta los bindings como segundo argumento posicional' do
      create_resource(code: 'ClosePurchaseOrders', resource: 'PurchaseOrders(#DocumentEntry#)/Close')

      expect(described_class.path_for('ClosePurchaseOrders', DocumentEntry: 42))
        .to eq('PurchaseOrders(42)/Close')
    end
  end

  # El builder no conoce al Client ni al verbo: el catálogo tiene lecturas y
  # escrituras, así que ejecutar acá obligaría a un método por verbo.
  it 'no expone ejecución: no conoce al Client' do
    expect(described_class.new('X')).not_to respond_to(:get)
    expect(described_class).not_to respond_to(:get)
  end
end

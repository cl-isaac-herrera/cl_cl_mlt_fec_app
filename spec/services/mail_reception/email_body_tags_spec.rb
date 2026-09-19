# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailReception::EmailBodyTags do
  let(:company) do
    build_stubbed(
      :company,
      economic_activity_code: '620102',
      default_recept_message: MessageType::REJECTED,
      default_recept_details: 'Recibido (default)',
      default_recept_tax_factor: 25.0,
      default_recept_tax_condition: '04'
    )
  end

  def resolve(body)
    described_class.new(body, company: company).resolve
  end

  it 'toma los 5 tags del cuerpo cuando todos vienen bien formados' do
    body = '[Status:ACEPTADO][DetalleMensaje:Recibido conforme][CodigoActividadReceptor:930000]' \
           '[CondicionImpuesto:03][TaxFactor:40]'

    result = resolve(body)

    expect(result.message).to eq(MessageType::ACCEPTED)
    expect(result.details).to eq('Recibido conforme')
    expect(result.economic_activity_code).to eq('930000')
    expect(result.tax_condition).to eq('03')
    expect(result.tax_factor).to eq(40.0)
  end

  it 'cae al default de la compañía cuando un tag no viene en el cuerpo' do
    result = resolve('Buenas tardes, adjunto la factura.')

    expect(result.message).to eq(company.default_recept_message)
    expect(result.details).to eq(company.default_recept_details)
    expect(result.tax_condition).to eq(company.default_recept_tax_condition)
    expect(result.tax_factor).to eq(company.default_recept_tax_factor)
    expect(result.economic_activity_code).to eq(company.economic_activity_code)
  end

  it 'cae al default de la compañía cuando Status trae un valor fuera de catálogo' do
    result = resolve('[Status:QUIENSABE]')

    expect(result.message).to eq(company.default_recept_message)
  end

  it 'cae al default de la compañía cuando CondicionImpuesto trae un valor fuera de catálogo' do
    result = resolve('[CondicionImpuesto:99]')

    expect(result.tax_condition).to eq(company.default_recept_tax_condition)
  end

  it 'cae al default de la compañía cuando TaxFactor no es numérico' do
    result = resolve('[TaxFactor:no-es-un-numero]')

    expect(result.tax_factor).to eq(company.default_recept_tax_factor)
  end

  it 'el último tag repetido gana' do
    result = resolve('[Status:ACEPTADO][Status:RECHAZADO]')

    expect(result.message).to eq(MessageType::REJECTED)
  end

  it 'sin ningún default de compañía, un tag ausente queda en nil' do
    empty_company = build_stubbed(:company, economic_activity_code: nil)

    result = described_class.new('sin tags acá', company: empty_company).resolve

    expect(result.message).to be_nil
    expect(result.details).to be_nil
    expect(result.tax_condition).to be_nil
    expect(result.tax_factor).to be_nil
    expect(result.economic_activity_code).to be_nil
  end
end

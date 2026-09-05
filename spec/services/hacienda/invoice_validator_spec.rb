# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::InvoiceValidator do
  describe '#call' do
    it 'no reporta errores para un documento consistente' do
      result = described_class.new(valid_invoice_document).call

      expect(result).to be_valid
      expect(result.errors).to eq([])
    end

    # La razón de ser de acumular en vez de cortar en el primer error (a
    # diferencia del legacy .NET): un documento con fallas en dos bloques
    # distintos (cabecera y línea) reporta las DOS de una sola pasada.
    it 'acumula errores de varios bloques en una sola pasada' do
      document = valid_invoice_document
      document['CondicionVenta'] = '77'
      document['DetalleServicio'] = [valid_line('CodigoCABYS' => nil)]

      result = described_class.new(document).call

      expect(result).not_to be_valid
      expect(result.errors.map(&:field)).to include('CondicionVenta', 'CodigoCABYS')
    end

    it 'identifica en qué línea ocurrió un error de línea' do
      document = valid_invoice_document
      document['DetalleServicio'] = [valid_line, valid_line('CodigoCABYS' => nil)]

      result = described_class.new(document).call

      failing = result.errors.find { |e| e.field == 'CodigoCABYS' }
      expect(failing.line_number).to eq(2)
    end
  end
end

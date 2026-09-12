# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::DocumentValidator do
  def validate(document, doc_type: DocType::FE) = described_class.new(document, doc_type: doc_type).call

  describe '.validates?' do
    it 'cubre los tipos que este producto sabe emitir' do
      expect(described_class.validates?(DocType::FE)).to be(true)
      expect(described_class.validates?(DocType::TE)).to be(true)
    end

    # Sus reglas todavía no se revisaron una por una contra `Validations.cs`.
    it 'no cubre los tipos que todavía no se migran' do
      expect(described_class.validates?(DocType::NC)).to be(false)
      expect(described_class.validates?(DocType::REP)).to be(false)
    end
  end

  describe '#call' do
    it 'no reporta errores para un documento consistente' do
      result = validate(valid_unified_document)

      expect(result).to be_valid
      expect(result.errors).to eq([])
    end

    # La razón de ser de acumular en vez de cortar en el primer error (a
    # diferencia del legacy .NET): un documento con fallas en dos bloques
    # distintos (cabecera y línea) reporta las DOS de una sola pasada.
    it 'acumula errores de varios bloques en una sola pasada' do
      document = valid_unified_document
      document['CondicionVenta'] = '77'
      document['DetalleServicio'] = [valid_line('CodigoCABYS' => nil)]

      result = validate(document)

      expect(result).not_to be_valid
      expect(result.errors.map(&:field)).to include('CondicionVenta', 'CodigoCABYS')
    end

    it 'identifica en qué línea ocurrió un error de línea' do
      document = valid_unified_document
      document['DetalleServicio'] = [valid_line, valid_line('CodigoCABYS' => nil)]

      result = validate(document)

      failing = result.errors.find { |e| e.field == 'CodigoCABYS' }
      expect(failing.line_number).to eq(2)
    end
  end

  # El legacy corre UN SOLO `OwnValidations` para todos los tipos y excluye
  # reglas puntuales según el `DocType` (CLAUDE.md §39). De todo ese método, lo
  # único que separa factura de tiquete es la identificación del receptor.
  describe 'tiquete electrónico' do
    def tiquete_sin_receptor
      document = valid_unified_document
      document['Receptor']['Identificacion'] = { 'Tipo' => nil, 'Numero' => nil }
      document
    end

    it 'acepta un tiquete sin identificación del receptor' do
      expect(validate(tiquete_sin_receptor, doc_type: DocType::TE)).to be_valid
    end

    # El error que motivó este cambio: en el legacy la regla del medio de pago
    # excluye SOLO a Recibo de Pago (`Validations.cs` L375), así que el tiquete
    # la cumple igual que la factura. Antes se le saltaba entera.
    it 'exige el medio de pago en contado, igual que la factura' do
      document = tiquete_sin_receptor
      document['CondicionVenta'] = '01'
      document['ResumenFactura']['MedioPago'] = []

      result = validate(document, doc_type: DocType::TE)

      expect(result).not_to be_valid
      expect(result.errors.map(&:message))
        .to include('El medio de pago es requerido para la condición de venta Contado.')
    end

    it 'revisa las líneas y los totales, igual que la factura' do
      document = tiquete_sin_receptor
      document['DetalleServicio'] = [valid_line('CodigoCABYS' => nil)]

      expect(validate(document, doc_type: DocType::TE).errors.map(&:field)).to include('CodigoCABYS')
    end

    # `Validations.cs` L817: para TE ninguna de las dos ramas del `if` da
    # verdadero, así que el legacy nunca revisa sus referencias.
    it 'no revisa la información de referencia' do
      document = tiquete_sin_receptor
      document['InformacionReferencia'] = [{ 'TipoDocIR' => '99', 'Numero' => nil }]

      expect(validate(document, doc_type: DocType::TE)).to be_valid
    end

    it 'sí la revisa en factura electrónica' do
      document = valid_unified_document
      document['InformacionReferencia'] = [{ 'TipoDocIR' => '99', 'Numero' => nil }]

      expect(validate(document)).not_to be_valid
    end
  end
end

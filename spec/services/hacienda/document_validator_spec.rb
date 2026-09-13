# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::DocumentValidator do
  def validate(document, doc_type: DocType::FE) = described_class.new(document, doc_type: doc_type).call

  describe '.validates?' do
    it 'cubre los tipos que este producto sabe emitir' do
      expect(described_class.validates?(DocType::FE)).to be(true)
      expect(described_class.validates?(DocType::TE)).to be(true)
      expect(described_class.validates?(DocType::ND)).to be(true)
      expect(described_class.validates?(DocType::NC)).to be(true)
    end

    # Sus reglas todavía no se revisaron una por una contra `Validations.cs`.
    it 'no cubre los tipos que todavía no se migran' do
      expect(described_class.validates?(DocType::FEC)).to be(false)
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

  # `Validations.cs` exime a ND y NC de la misma regla que a TE (la
  # identificación del receptor, L324 y L329) y NO las exime de ninguna otra:
  # el bloque de referencias (L817) sí corre para las dos. Lo único que piden
  # de MÁS sale del otro validador del legacy, el XSD: `InformacionReferencia`
  # es obligatoria en `NotaCreditoElectronica_V4.4.xsd` y opcional en el de
  # factura.
  describe 'notas de crédito y de débito' do
    # La misma base de la factura, más la referencia que la nota sí necesita.
    def nota
      valid_unified_document.merge('InformacionReferencia' => [valid_reference])
    end

    it 'acepta una nota de crédito consistente' do
      expect(validate(nota, doc_type: DocType::NC)).to be_valid
    end

    it 'acepta una nota de débito consistente' do
      expect(validate(nota, doc_type: DocType::ND)).to be_valid
    end

    it 'acepta una nota sin identificación del receptor' do
      document = nota
      document['Receptor']['Identificacion'] = { 'Tipo' => nil, 'Numero' => nil }

      expect(validate(document, doc_type: DocType::NC)).to be_valid
    end

    # Lo que se exime es EXIGIRLA, no revisarla (CLAUDE.md §39).
    it 'revisa la identificación del receptor si la nota la trae' do
      document = nota
      document['Receptor']['Identificacion'] = { 'Tipo' => '01', 'Numero' => '12345' }

      expect(validate(document, doc_type: DocType::NC).errors.map(&:field))
        .to include('Receptor.Identificacion.Numero')
    end

    it 'exige que la nota diga qué documento corrige' do
      document = nota
      document['InformacionReferencia'] = []

      result = validate(document, doc_type: DocType::NC)

      expect(result).not_to be_valid
      expect(result.errors.map(&:message)).to include(
        'Nota de crédito electrónica debe indicar el documento que corrige en la ' \
        'información de referencia.'
      )
    end

    it 'nombra el tipo correcto cuando la que falta es la de una nota de débito' do
      document = nota
      document['InformacionReferencia'] = []

      expect(validate(document, doc_type: DocType::ND).errors.map(&:message))
        .to include(a_string_starting_with('Nota de débito electrónica'))
    end

    # La factura no la exige: el XSD la declara `minOccurs="0"`.
    it 'no se la exige a la factura ni al tiquete' do
      document = valid_unified_document
      document['InformacionReferencia'] = []

      expect(validate(document)).to be_valid
      expect(validate(document, doc_type: DocType::TE)).to be_valid
    end

    # `Validations.cs` L817: la primera rama del `if` da verdadero para todo lo
    # que no sea 01/04/08/09, así que las notas sí pasan por el bloque.
    it 'revisa la información de referencia que trae' do
      document = nota
      document['InformacionReferencia'] = [valid_reference('Razon' => nil)]

      expect(validate(document, doc_type: DocType::NC).errors.map(&:field)).to include('Razon')
    end

    it 'revisa las líneas y los totales, igual que la factura' do
      document = nota
      document['DetalleServicio'] = [valid_line('CodigoCABYS' => nil)]

      expect(validate(document, doc_type: DocType::ND).errors.map(&:field)).to include('CodigoCABYS')
    end
  end
end

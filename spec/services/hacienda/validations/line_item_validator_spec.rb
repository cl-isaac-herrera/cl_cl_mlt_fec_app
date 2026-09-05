# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::LineItemValidator do
  def errors_for(line, number = 1) = described_class.new(line, number).call
  def fields_for(line, number = 1) = errors_for(line, number).map(&:field)

  it 'no reporta nada para una línea consistente' do
    expect(errors_for(valid_line)).to eq([])
  end

  it 'identifica la línea en cada error' do
    expect(errors_for(valid_line('CodigoCABYS' => nil), 7).first.line_number).to eq(7)
  end

  it 'exige el código CABYS' do
    expect(fields_for(valid_line('CodigoCABYS' => nil))).to include('CodigoCABYS')
  end

  it 'rechaza un tipo de código comercial fuera del catálogo' do
    line = valid_line('CodigoComercial' => { 'Tipo' => '77', 'Codigo' => 'X' })

    expect(fields_for(line)).to include('CodigoComercial.Tipo')
  end

  it 'detecta que el monto total no coincide con cantidad × precio' do
    line = valid_line('MontoTotal' => BigDecimal(999))

    expect(fields_for(line)).to include('MontoTotal')
  end

  it 'exige la naturaleza del descuento cuando el código es 99 (Otros)' do
    line = valid_line(
      'Descuento' => { 'MontoDescuento' => BigDecimal(10), 'CodigoDescuento' => '99',
                       'NaturalezaDescuento' => nil, 'CodigoDescuentoOTRO' => nil,
                       'PorcentajeDescuento' => BigDecimal(5) },
      'SubTotal' => BigDecimal(190)
    )

    expect(fields_for(line)).to include('Descuento.NaturalezaDescuento')
  end

  it 'detecta que el subtotal no coincide con monto total menos descuento' do
    line = valid_line('SubTotal' => BigDecimal(999))

    expect(fields_for(line)).to include('SubTotal')
  end

  describe 'impuesto' do
    it 'bloquea el código 08 (IVA Régimen de Bienes Usados) como no soportado' do
      line = valid_line('Impuesto' => valid_impuesto('Codigo' => '08'))

      expect(fields_for(line)).to include('Impuesto.Codigo')
    end

    it 'exige un código de impuesto válido cuando hay monto' do
      line = valid_line('Impuesto' => valid_impuesto('Codigo' => '77'))

      expect(fields_for(line)).to include('Impuesto.Codigo')
    end

    it 'exige el código de tarifa del IVA' do
      line = valid_line('Impuesto' => valid_impuesto('CodigoTarifaIVA' => nil))

      expect(fields_for(line)).to include('Impuesto.CodigoTarifaIVA')
    end

    it 'no exige el código de tarifa cuando la línea usa DetalleSurtido' do
      line = valid_line('Impuesto' => valid_impuesto('CodigoTarifaIVA' => nil),
                        'DetalleSurtido' => [{ 'CodigoCABYSSurtido' => '1' * 13 }])

      expect(fields_for(line)).not_to include('Impuesto.CodigoTarifaIVA')
    end

    it 'rechaza un código de tarifa fuera del catálogo' do
      line = valid_line('Impuesto' => valid_impuesto('CodigoTarifaIVA' => '77'))

      expect(fields_for(line)).to include('Impuesto.CodigoTarifaIVA')
    end

    it 'detecta que el monto de impuesto no coincide con la tarifa aplicada a la base' do
      line = valid_line('Impuesto' => valid_impuesto('Monto' => BigDecimal(999)))

      expect(fields_for(line)).to include('Impuesto.Monto')
    end

    # Regla del descuento "Royalty": el impuesto se calcula sobre el monto
    # total y no sobre la base imponible.
    it 'calcula el impuesto sobre el monto total cuando el descuento es de tipo Royalty' do
      line = valid_line(
        'Descuento' => { 'MontoDescuento' => BigDecimal(0), 'CodigoDescuento' => '01',
                         'NaturalezaDescuento' => 'Regalía', 'CodigoDescuentoOTRO' => nil,
                         'PorcentajeDescuento' => BigDecimal(0) },
        'BaseImponible' => BigDecimal(999), # si se usara la base, fallaría
        'Impuesto' => valid_impuesto('Monto' => BigDecimal(26)) # 13% de 200 (MontoTotal)
      )

      expect(fields_for(line)).not_to include('Impuesto.Monto')
    end

    it 'un artículo de regalía (precio cero) con tarifa exige impuesto mayor a cero' do
      line = valid_line(
        'PrecioUnitario' => BigDecimal(0), 'MontoTotal' => BigDecimal(0), 'SubTotal' => BigDecimal(0),
        'ImpuestoNeto' => BigDecimal(0), 'MontoTotalLinea' => BigDecimal(0),
        'Impuesto' => valid_impuesto('Monto' => BigDecimal(0))
      )

      expect(fields_for(line)).to eq(['Impuesto.Monto'])
    end

    it 'bloquea el monto de exportación como no soportado' do
      line = valid_line('Impuesto' => valid_impuesto('MontoExportacion' => BigDecimal(50)))

      expect(fields_for(line)).to include('Impuesto.MontoExportacion')
    end
  end

  describe 'exoneración' do
    def line_with_exoneracion(overrides = {})
      valid_line(
        'Impuesto' => valid_impuesto(
          'Exoneracion' => valid_exoneracion({
            'TipoDocumentoEX1' => '01', 'NumeroDocumento' => 'DOC-1',
            'NombreInstitucion' => '01', 'FechaEmisionEX' => '2026-01-01',
            'TarifaExonerada' => BigDecimal(13), 'MontoExoneracion' => BigDecimal(26)
          }.merge(overrides))
        ),
        'ImpuestoNeto' => BigDecimal(0), 'MontoTotalLinea' => BigDecimal(200)
      )
    end

    it 'una exoneración total y consistente no reporta nada' do
      expect(errors_for(line_with_exoneracion)).to eq([])
    end

    it 'rechaza un tipo de documento de exoneración fuera del catálogo' do
      line = line_with_exoneracion('TipoDocumentoEX1' => '77')

      expect(fields_for(line)).to include('Impuesto.Exoneracion.TipoDocumentoEX1')
    end

    it 'exige el nombre de la institución cuando es 99 (Otros)' do
      line = line_with_exoneracion('NombreInstitucion' => '99', 'NombreInstitucionOtros' => nil)

      expect(fields_for(line)).to include('Impuesto.Exoneracion.NombreInstitucionOtros')
    end

    it 'exige la fecha de emisión de la exoneración' do
      line = line_with_exoneracion('FechaEmisionEX' => nil)

      expect(fields_for(line)).to include('Impuesto.Exoneracion.FechaEmisionEX')
    end

    it 'exige una tarifa exonerada mayor a cero' do
      line = line_with_exoneracion('TarifaExonerada' => BigDecimal(0))

      expect(fields_for(line)).to include('Impuesto.Exoneracion.TarifaExonerada')
    end

    it 'rechaza una tarifa exonerada mayor a la tarifa del impuesto' do
      line = line_with_exoneracion('TarifaExonerada' => BigDecimal(50))

      expect(fields_for(line)).to include('Impuesto.Exoneracion.TarifaExonerada')
    end

    it 'rechaza un monto de exoneración en cero' do
      line = line_with_exoneracion('MontoExoneracion' => BigDecimal(0))

      expect(fields_for(line)).to include('Impuesto.Exoneracion.MontoExoneracion')
    end

    it 'detecta que el monto de exoneración no coincide con la tarifa sobre el subtotal' do
      line = line_with_exoneracion('MontoExoneracion' => BigDecimal(999))

      expect(fields_for(line)).to include('Impuesto.Exoneracion.MontoExoneracion')
    end
  end

  # Regla #40/#41: corren siempre, no solo cuando hay exoneración (ver el
  # comentario de `#impuesto_neto_cuadra` en el validador).
  describe 'impuesto neto y total de línea (siempre, con o sin exoneración)' do
    it 'detecta que el impuesto neto no coincide con impuesto − exoneración' do
      line = valid_line('ImpuestoNeto' => BigDecimal(999))

      expect(fields_for(line)).to include('ImpuestoNeto')
    end

    it 'detecta que el monto total de línea no coincide con subtotal + impuesto neto' do
      line = valid_line('MontoTotalLinea' => BigDecimal(999))

      expect(fields_for(line)).to include('MontoTotalLinea')
    end
  end
end

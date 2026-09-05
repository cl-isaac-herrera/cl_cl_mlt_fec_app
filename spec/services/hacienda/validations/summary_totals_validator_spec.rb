# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Hacienda::Validations::SummaryTotalsValidator do
  def errors_for(document) = described_class.new(document).call
  def fields_for(document) = errors_for(document).map(&:field)

  it 'no reporta nada para un documento consistente' do
    expect(errors_for(valid_invoice_document)).to eq([])
  end

  it 'no corre en absoluto sin líneas — igual que el legacy' do
    document = valid_invoice_document
    document['DetalleServicio'] = []
    document['ResumenFactura']['TotalMercanciasGravadas'] = BigDecimal(999) # sería inconsistente

    expect(errors_for(document)).to eq([])
  end

  describe 'recalculado desde las líneas (bloque F)' do
    it 'detecta que el total de mercancías gravadas no coincide con las líneas' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalMercanciasGravadas'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalMercanciasGravadas')
    end

    it 'clasifica una línea con unidad de servicio como Servicio y no Mercancía' do
      document = valid_invoice_document
      document['DetalleServicio'] = [valid_line('UnidadMedida' => 'Sp')] # servicio profesional
      document['ResumenFactura'] = valid_resumen_factura(
        'TotalServGravados' => BigDecimal(200), 'TotalMercanciasGravadas' => BigDecimal(0)
      )

      expect(errors_for(document)).to eq([])
    end

    # Solo se aísla el recálculo de este total puntual: forzar además el resto
    # del resumen a quedar consistente exigiría reclasificar la línea también
    # como exenta por tarifa, que es una decisión de quien arma el documento
    # y no algo que este ejemplo necesite resolver.
    it 'excluye del total gravado de mercancías la línea con régimen especial de fábrica exento' do
      document = valid_invoice_document
      document['DetalleServicio'] = [valid_line('IVACobradoFabrica' => '02')]
      document['ResumenFactura']['TotalMercanciasGravadas'] = BigDecimal(0)

      expect(fields_for(document)).not_to include('ResumenFactura.TotalMercanciasGravadas')
    end

    it 'detecta que el impuesto asumido por el emisor fábrica no coincide' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalImpAsumEmisorFabrica'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalImpAsumEmisorFabrica')
    end
  end

  describe 'cuadre entre los totales del resumen (bloque G)' do
    it 'detecta que el total gravado no es la suma de servicios y mercancías gravadas' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalGravado'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalGravado')
    end

    it 'detecta que el total de venta no cuadra contra sus cuatro componentes' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalVenta'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalVenta')
    end

    it 'detecta que el total de descuentos no coincide con la suma de las líneas' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalDescuentos'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalDescuentos')
    end

    it 'detecta que la venta neta no es venta menos descuentos' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalVentaNeta'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalVentaNeta')
    end

    it 'detecta impuesto declarado sin respaldo alguno en las líneas' do
      document = valid_invoice_document
      document['DetalleServicio'] = [
        valid_line('Impuesto' => valid_impuesto('Monto' => BigDecimal(0)), 'ImpuestoNeto' => BigDecimal(0))
      ]
      # TotalImpuesto se queda en 26 a propósito: nada en las líneas lo respalda.

      expect(fields_for(document)).to include('ResumenFactura.TotalImpuesto')
    end

    it 'detecta que el total no sujeto no es la suma de servicios y mercancías no sujetas' do
      document = valid_invoice_document
      document['ResumenFactura']['TotalNoSujeto'] = BigDecimal(999)

      expect(fields_for(document)).to include('ResumenFactura.TotalNoSujeto')
    end

    describe 'otros cargos' do
      it 'rechaza un total declarado MENOR a la suma real (subestimado)' do
        document = valid_invoice_document
        document['OtrosCargos'] = [{ 'MontoCargo' => BigDecimal(50) }]
        document['ResumenFactura']['TotalOtrosCargos'] = BigDecimal(10)

        expect(fields_for(document)).to include('ResumenFactura.TotalOtrosCargos')
      end

      it 'NO rechaza un total declarado mayor a la suma real' do
        document = valid_invoice_document
        document['OtrosCargos'] = [{ 'MontoCargo' => BigDecimal(10) }]
        document['ResumenFactura']['TotalOtrosCargos'] = BigDecimal(50)

        expect(errors_for(document)).to eq([])
      end
    end
  end
end

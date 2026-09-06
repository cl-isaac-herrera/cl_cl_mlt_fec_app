# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::IssuedDocumentsSearch do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # Fila customizada tal como la deja la pantalla de mantenimiento de
  # `sl_resources`: el `$filter` de `Series` ya viene resuelto por instalación,
  # sin marcadores `@Nombre`.
  #
  # `find_or_initialize_by` y no `create!`: `getDocuments01`..`10` los siembra
  # `db/migrate/20260905160000_add_get_documents_sl_resources.rb`, que SÍ corre
  # contra la base de test (es una migración, no un seed) — un `create!` con el
  # mismo código chocaría contra esa fila.
  def create_resource(code, resource, filter: nil)
    query_params = '$select=DocEntry,DocNum,CardCode,CardName,U_CL_FEC_Status,U_CL_FEC_FechaEmision'
    query_params += "&$filter=(#{filter})" if filter
    record = SlResource.unscoped.find_or_initialize_by(code: code)
    record.update!(resource: resource, query_params: query_params, page_size: 0, is_active: true)
    record
  end

  # start_date/end_date son obligatorios (`InvalidDateRange` si faltan): se
  # dan por defecto acá para que los tests que no ponen a prueba la fecha no
  # tengan que repetirlos, y se pisan con `filters:` cuando sí importan.
  def search(doc_type: DocType::FE, page: 1, per_page: 10, filters: {})
    described_class.new(doc_type: doc_type, client: client, page: page, per_page: per_page,
                        filters: { start_date: '2026-01-01', end_date: '2026-01-31' }.merge(filters)).call
  end

  before { allow(client).to receive(:get).and_return([]) }

  describe 'resolución del recurso' do
    it 'levanta UnsupportedDocType si el tipo no tiene fila en el catálogo' do
      # '99' no es uno de los 7 tipos con fila `getDocuments<tipo>` — a
      # diferencia de '01' (FE), que sí la tiene desde
      # `20260905160000_add_get_documents_sl_resources.rb` (migración, no seed:
      # corre también contra la base de test).
      expect { search(doc_type: '99') }.to raise_error(described_class::UnsupportedDocType, /99/)
    end

    it 'conserva el $filter de Series del catálogo' do
      create_resource('getDocuments01', 'Invoices', filter: 'Series eq 72')

      search

      expect(client).to have_received(:get).with(/Invoices\?.*Series eq 72/)
    end
  end

  describe 'paginación (techo real de 20 filas por respuesta, TODOS.md → SAP)' do
    before { create_resource('getDocuments01', 'Invoices', filter: 'Series eq 72') }

    it 'pide una fila de más para detectar si hay página siguiente' do
      search(page: 1, per_page: 10)

      expect(client).to have_received(:get).with(/\$top=11/)
      expect(client).to have_received(:get).with(/\$skip=0/)
    end

    it 'calcula $skip a partir de la página pedida' do
      search(page: 3, per_page: 10)

      expect(client).to have_received(:get).with(/\$skip=20/)
    end

    it 'acota per_page a MAX_PAGE_SIZE aunque se pida más' do
      search(page: 1, per_page: 999)

      expect(client).to have_received(:get).with(/\$top=20/)
    end

    it 'has_more es true cuando SAP devolvió la fila de más' do
      allow(client).to receive(:get).and_return([{ 'DocEntry' => 1 }, { 'DocEntry' => 2 }])

      result = search(page: 1, per_page: 1)

      expect(result.has_more).to be(true)
      expect(result.items).to eq([{ 'DocEntry' => 1 }])
    end

    it 'has_more es false cuando SAP devolvió menos o igual que per_page' do
      allow(client).to receive(:get).and_return([{ 'DocEntry' => 1 }])

      result = search(page: 1, per_page: 1)

      expect(result.has_more).to be(false)
      expect(result.items).to eq([{ 'DocEntry' => 1 }])
    end
  end

  describe 'rango de fechas (DocDate) — obligatorio' do
    before { create_resource('getDocuments01', 'Invoices', filter: 'Series eq 72') }

    it 'filtra DocDate con literal datetime, combinado con el Series del catálogo' do
      search(filters: { start_date: '2026-09-01', end_date: '2026-09-05' })

      expect(client).to have_received(:get).with(
        /Series eq 72\) and DocDate ge datetime'2026-09-01T00:00:00' and DocDate le datetime'2026-09-05T23:59:59'/
      )
    end

    it 'levanta InvalidDateRange si falta start_date' do
      expect { search(filters: { start_date: nil, end_date: '2026-09-05' }) }
        .to raise_error(described_class::InvalidDateRange, /fecha de inicio/)
    end

    it 'levanta InvalidDateRange si falta end_date' do
      expect { search(filters: { start_date: '2026-09-01', end_date: nil }) }
        .to raise_error(described_class::InvalidDateRange, /fecha de inicio/)
    end

    it 'levanta InvalidDateRange si el formato no es AAAA-MM-DD' do
      expect { search(filters: { start_date: '01/09/2026', end_date: '2026-09-05' }) }
        .to raise_error(described_class::InvalidDateRange, /formato/)
    end
  end

  describe 'filtros del request' do
    before { create_resource('getDocuments01', 'Invoices', filter: 'Series eq 72') }

    it 'usa contains para texto libre' do
      search(filters: { receptor: "O'Brien" })

      expect(client).to have_received(:get).with(/contains\(CardName,'O''Brien'\)/)
    end

    # La cédula del receptor se filtra por `FederalTaxID` (el campo del
    # documento), no por `CardCode` (el código interno del socio de negocio en
    # SAP) — son datos distintos y el segundo nunca coincide con una cédula.
    it 'filtra la cédula por FederalTaxID, no por CardCode' do
      search(filters: { cedula: '3101822733' })

      expect(client).to have_received(:get).with(/contains\(FederalTaxID,'3101822733'\)/)
    end

    it 'ignora un status no numérico' do
      search(filters: { status: 'todos' })

      expect(client).not_to have_received(:get).with(/U_CL_FEC_Status eq/)
    end

    it 'filtra por status cuando es numérico' do
      search(filters: { status: '4' })

      expect(client).to have_received(:get).with(/U_CL_FEC_Status eq 4/)
    end

    it 'no agrega ninguna condición opcional cuando solo llegan las fechas (obligatorias)' do
      captured_path = nil
      allow(client).to receive(:get) { |path|
        captured_path = path
        []
      }

      search

      expect(captured_path).to match(/Invoices\?\$select=.*Series eq 72\) and DocDate ge datetime'2026-01-01T00:00:00'/)
      expect(captured_path).to match(/DocDate le datetime'2026-01-31T23:59:59'&\$top=/)
      expect(captured_path).not_to match(/contains\(|U_CL_FEC_Status eq/)
    end
  end
end

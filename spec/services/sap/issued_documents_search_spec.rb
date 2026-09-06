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

  def search(doc_type: DocType::FE, page: 1, per_page: 10, filters: {})
    described_class.new(doc_type: doc_type, client: client, page: page, per_page: per_page,
                        filters: filters).call
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

  describe 'filtros del request' do
    before { create_resource('getDocuments01', 'Invoices', filter: 'Series eq 72') }

    it 'combina el filtro de fecha con AND, sin pisar el de Series' do
      search(filters: { start_date: '2026-09-01', end_date: '2026-09-05' })

      expect(client).to have_received(:get).with(
        /Series eq 72\) and U_CL_FEC_FechaEmision ge '2026-09-01' and U_CL_FEC_FechaEmision le '2026-09-05T23:59:59'/
      )
    end

    it 'usa contains para texto libre' do
      search(filters: { receptor: "O'Brien" })

      expect(client).to have_received(:get).with(/contains\(CardName,'O''Brien'\)/)
    end

    it 'ignora un status no numérico' do
      search(filters: { status: 'todos' })

      expect(client).to have_received(:get).with(/Invoices\?\$select=.*Series eq 72\)&\$top=/)
    end

    it 'filtra por status cuando es numérico' do
      search(filters: { status: '4' })

      expect(client).to have_received(:get).with(/U_CL_FEC_Status eq 4/)
    end

    it 'no agrega ninguna condición cuando no hay filtros' do
      search

      expect(client).to have_received(:get).with(/Invoices\?\$select=.*Series eq 72\)&\$top=/)
    end
  end
end

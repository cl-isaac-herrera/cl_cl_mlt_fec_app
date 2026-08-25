# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::DocumentDetails do
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  # Un doble en vez del Client real: acá se prueba QUÉ se le pide a SAP y cómo se
  # interpreta lo que devuelve, no el transporte HTTP.
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # Las seis consultas del catálogo, con el mismo filtro y `page_size` que siembra
  # `db/seeds.rb`. Se crean acá porque los specs no corren el seed.
  before do
    filter = '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)'
    {
      described_class::HEADER => ['DOCHEADERINFO', 0],
      described_class::LINES => ['DOCLINESINFO', 999],
      described_class::OTHER_CHARGES => ['DOCOTHERCHARGESINFO', 999],
      described_class::PAYMENT_METHODS => ['DOCPAYMENTMETHODSINFO', 999],
      described_class::REFERENCES => ['DOCREFERENCEINFO', 999],
      described_class::OTHERS => ['DOCOTHERSINFO', 999]
    }.each do |code, (view, page_size)|
      SlResource.create!(code: code, resource: "view.svc/CL_D_CL_MLT_FEC_SLT_#{view}_B1SLQuery",
                         query_params: filter, page_size: page_size)
    end
  end

  def fetch(doc_entry: 25, doc_type: DocType::FE)
    described_class.new(company: company, doc_entry: doc_entry, doc_type: doc_type, client: client).call
  end

  # Una vista del Service Layer siempre devuelve una colección, aunque el filtro
  # deje una sola fila. Tratarla como objeto daría nil en todos los campos.
  def stub_get(header: [{ 'Clave' => '506…' }], lines: [], others: [])
    allow(client).to receive(:get) do |path|
      case path
      when /DOCHEADERINFO/ then header
      when /DOCLINESINFO/ then lines
      when /DOCOTHERSINFO/ then others
      else []
      end
    end
  end

  describe 'qué se le pide a SAP' do
    it 'filtra por el par DocEntry + DocType' do
      stub_get

      fetch(doc_entry: 25, doc_type: DocType::NC)

      expect(client).to have_received(:get).with(/DocEntry eq 25 and DocType eq '03'/).at_least(:once)
    end

    # Sin `$top` el Service Layer devuelve 20 filas y corta: un documento de 25
    # líneas se emitiría con 20 y los totales no cuadrarían contra Hacienda.
    it 'aplica el $top que define el catálogo en las listas' do
      stub_get

      fetch

      expect(client).to have_received(:get).with(/DOCLINESINFO.*\$top=999/)
    end

    # La cabecera es una sola fila: paginarla no significa nada.
    it 'no le pone $top a la cabecera' do
      paths = []
      allow(client).to receive(:get) { |path| paths << path; path.match?(/DOCHEADERINFO/) ? [{}] : [] }

      fetch

      expect(paths.grep(/DOCHEADERINFO/).first).not_to include('$top')
    end
  end

  describe 'cabecera' do
    it 'devuelve la fila única desenvuelta de la colección' do
      stub_get(header: [{ 'Clave' => '506123' }])

      expect(fetch.header.string('Clave')).to eq('506123')
    end

    # Sin cabecera no hay nada que armar: corta en vez de dejar pasar un
    # comprobante vacío.
    it 'levanta cuando SAP no devolvió cabecera' do
      stub_get(header: [])

      expect { fetch }.to raise_error(described_class::HeaderNotFound, /no devolvió cabecera/)
    end

    # Más de una fila significa que la vista está mal filtrada. No corta —el .NET
    # tomaba la primera— pero deja constancia.
    it 'avisa y usa la primera si vinieron varias' do
      stub_get(header: [{ 'Clave' => 'A' }, { 'Clave' => 'B' }])
      allow(Rails.logger).to receive(:warn)

      expect(fetch.header.string('Clave')).to eq('A')
      expect(Rails.logger).to have_received(:warn).with(/devolvió 2 filas/)
    end
  end

  describe 'bloque Otros' do
    # Es una vuelta menos al Service Layer por documento cuando la compañía no lo
    # usa, y el resultado no se iba a leer.
    it 'no se consulta cuando la compañía no tiene use_additional_fields' do
      stub_get(others: [{ 'Codigo' => 'X' }])

      expect(fetch.others).to eq([])
      expect(client).not_to have_received(:get).with(/DOCOTHERSINFO/)
    end

    it 'se consulta cuando la compañía lo tiene encendido' do
      company.update!(use_additional_fields: true)
      stub_get(others: [{ 'Codigo' => 'X', 'Valor' => 'Y' }])

      expect(fetch.others.first.string('Valor')).to eq('Y')
    end
  end

  describe 'listas' do
    it 'devuelve listas vacías y no nil cuando el documento no tiene ese bloque' do
      stub_get

      result = fetch

      expect(result.lines).to eq([])
      expect(result.other_charges).to eq([])
      expect(result.references).to eq([])
    end

    # `Client#get` devuelve nil cuando el cuerpo viene vacío.
    it 'tolera que SAP devuelva nil en vez de una colección' do
      allow(client).to receive(:get) { |path| path.match?(/DOCHEADERINFO/) ? [{ 'Clave' => 'A' }] : nil }

      expect(fetch.lines).to eq([])
    end
  end
end

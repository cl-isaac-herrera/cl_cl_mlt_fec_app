# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::DocumentDetails do
  let(:company) { Company.create!(name: 'ACME S.A.', sap_db: 'SBO_ACME') }
  # Un doble en vez del Client real: acá se prueba QUÉ se le pide a SAP y cómo se
  # interpreta lo que devuelve, no el transporte HTTP.
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # Las seis consultas del catálogo, con el mismo filtro y `page_size` que siembra
  # `db/seeds.rb` (0 en las seis). Se crean acá porque los specs no corren el seed.
  before do
    filter = '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)'
    [described_class::HEADER, described_class::LINES, described_class::OTHER_CHARGES,
     described_class::PAYMENT_METHODS, described_class::REFERENCES, described_class::OTHERS]
      .zip(%w[DOCHEADERINFO DOCLINESINFO DOCOTHERCHARGESINFO DOCPAYMENTMETHODSINFO
              DOCREFERENCEINFO DOCOTHERSINFO])
      .each do |code, view|
        SlResource.create!(code: code, resource: "view.svc/CL_D_CL_MLT_FEC_SLT_#{view}_B1SLQuery",
                           query_params: filter, page_size: 0)
      end
  end

  def fetch(doc_entry: 25, doc_type: DocType::FE)
    described_class.new(company: company, doc_entry: doc_entry, doc_type: doc_type, client: client).call
  end

  # Una vista del Service Layer siempre devuelve una colección, aunque el filtro
  # deje una sola fila. Tratarla como objeto daría nil en todos los campos.
  def stub_get(header: [{ 'Clave' => '506…' }], lines: [], others: [])
    allow(client).to receive(:get) do |path, **|
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

      expect(client).to have_received(:get).with(/DocEntry eq 25 and DocType eq '03'/, anything).at_least(:once)
    end

    # Sin este header el Service Layer devuelve 20 filas y corta: un documento
    # de 25 líneas se emitiría con 20 y los totales no cuadrarían contra
    # Hacienda (`TODOS.md` → SAP, "deuda del acceso a Service Layer").
    it 'manda Prefer: odata.maxpagesize en las listas, para traerlas completas' do
      stub_get

      fetch

      expect(client).to have_received(:get).with(/DOCLINESINFO/, headers: { 'Prefer' => 'odata.maxpagesize=0' })
    end

    it 'manda el mismo header en la cabecera: paginarla distinto no significa nada' do
      stub_get

      fetch

      expect(client).to have_received(:get).with(/DOCHEADERINFO/, headers: { 'Prefer' => 'odata.maxpagesize=0' })
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
      expect(client).not_to have_received(:get).with(/DOCOTHERSINFO/, anything)
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
      allow(client).to receive(:get) { |path, **| path.match?(/DOCHEADERINFO/) ? [{ 'Clave' => 'A' }] : nil }

      expect(fetch.lines).to eq([])
    end
  end
end

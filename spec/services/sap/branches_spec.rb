# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::Branches do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # `find_or_initialize_by` y no `create!`: las cuatro filas ya vienen en el
  # esquema de test, insertadas por la migración que completa el catálogo
  # (`20260913120000_add_branches_sl_resources.rb`).
  def upsert_resource(code, resource:, query_params: nil)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: resource, query_params: query_params, page_size: 0, is_active: true)
    end
  end

  before do
    upsert_resource('getBranches', resource: 'U_CL_FEC_SUCURSALES',
                                   query_params: '$orderby=U_SucursalNum asc')
    upsert_resource('getBranchByCode', resource: 'U_CL_FEC_SUCURSALES(#Code#)')
    upsert_resource('createBranch', resource: 'U_CL_FEC_SUCURSALES')
    upsert_resource('updateBranch', resource: 'U_CL_FEC_SUCURSALES(#Code#)')
  end

  subject(:branches) { described_class.new(client: client) }

  # Una fila como la devuelve el Service Layer para la UDT.
  def sap_row(code: 1, number: 1, active: 'Y', alias_name: 'Central')
    {
      'Code' => code.to_s, 'U_SucursalNum' => number,
      'U_EmsrUbProvincia' => '1', 'U_EmsrUbCanton' => '01', 'U_EmsrUbDistrito' => '01',
      'U_EmsrUbBarrio' => 'Carmen', 'U_EmsrUbOtrasSenas' => '100 m norte',
      'U_EmsrTlfCodigoPais' => 506, 'U_EmsrTlfNumTelefono' => '22223333',
      'U_EmsrFaxCodigoPais' => 506, 'U_EmsrFaxNumTelefono' => nil,
      'U_EmsrCorreoElectronico' => 'sucursal@acme.cr',
      'U_Active' => active, 'U_Alias' => alias_name
    }
  end

  def valid_attributes(overrides = {})
    {
      number: 2, provincia: '1', canton: '01', distrito: '01', barrio: 'Carmen',
      otras_senas: '100 m norte', telefono_codigo_pais: 506, telefono: '22223333',
      fax_codigo_pais: 506, fax: nil, correo: 'sucursal@acme.cr',
      active: true, alias_name: 'Central'
    }.merge(overrides)
  end

  describe '#list' do
    it 'pide una fila de más para saber si hay página siguiente, y la recorta' do
      allow(client).to receive(:get).and_return([sap_row(code: 1), sap_row(code: 2), sap_row(code: 3)])

      result = branches.list(page: 1, per_page: 2)

      expect(client).to have_received(:get).with(a_string_including('$top=3', '$skip=0'))
      expect(result.items.size).to eq(2)
      expect(result.has_more).to be(true)
    end

    it 'has_more es false cuando SAP no devolvió la fila de más' do
      allow(client).to receive(:get).and_return([sap_row])

      expect(branches.list(per_page: 10).has_more).to be(false)
    end

    it 'conserva el $orderby del catálogo' do
      allow(client).to receive(:get).and_return([])

      branches.list

      expect(client).to have_received(:get).with(a_string_including('$orderby=U_SucursalNum asc'))
    end

    it 'traduce la Y/N de la UDT a un booleano' do
      allow(client).to receive(:get).and_return([sap_row(active: 'N')])

      expect(branches.list.items.first.active).to be(false)
    end

    # El estado es un filtro, no un corte fijo: sin él la consulta trae activas
    # e inactivas, que es lo que permite reactivar una sucursal dada de baja.
    it 'no filtra por estado cuando `active` no viene' do
      allow(client).to receive(:get).and_return([])

      branches.list(filters: {})

      expect(client).to have_received(:get).with(satisfy { |path| !path.include?('U_Active') })
    end

    it 'distingue `false` de "sin filtrar"' do
      allow(client).to receive(:get).and_return([])

      branches.list(filters: { active: false })

      expect(client).to have_received(:get).with(a_string_including("U_Active eq 'N'"))
    end

    it 'arma el filtro de alias y de ubicación que manda la pantalla' do
      allow(client).to receive(:get).and_return([])

      branches.list(filters: { alias: 'Cen', provincia: '1', canton: '01', distrito: '02' })

      expect(client).to have_received(:get).with(
        a_string_including("contains(U_Alias,'Cen')", "U_EmsrUbProvincia eq '1'",
                           "U_EmsrUbCanton eq '01'", "U_EmsrUbDistrito eq '02'")
      )
    end

    it 'escapa las comillas simples del filtro de texto' do
      allow(client).to receive(:get).and_return([])

      branches.list(filters: { alias: "O'Brien" })

      expect(client).to have_received(:get).with(a_string_including("contains(U_Alias,'O''Brien')"))
    end

    # El `$filter` que una instalación le haya agregado desde la pantalla de
    # mantenimiento no se pisa: se le suman las condiciones del request.
    it 'combina el $filter del catálogo con el del request' do
      upsert_resource('getBranches', resource: 'U_CL_FEC_SUCURSALES',
                                     query_params: "$filter=(U_Alias ne 'oculta')&$orderby=U_SucursalNum asc")
      allow(client).to receive(:get).and_return([])

      branches.list(filters: { active: true })

      expect(client).to have_received(:get).with(
        a_string_including("(U_Alias ne 'oculta') and U_Active eq 'Y'")
      )
    end

    it 'acota per_page al techo del Service Layer' do
      allow(client).to receive(:get).and_return([])

      branches.list(per_page: 500)

      expect(client).to have_received(:get).with(a_string_including("$top=#{described_class::MAX_PAGE_SIZE + 1}"))
    end
  end

  describe '#find' do
    it 'lee la entidad por su Code, sin comillas (la UDT es autoincremental)' do
      allow(client).to receive(:get).and_return(sap_row(code: 7, number: 3))

      branch = branches.find(7)

      expect(client).to have_received(:get).with('U_CL_FEC_SUCURSALES(7)')
      expect(branch.code).to eq(7)
      expect(branch.number).to eq(3)
    end
  end

  describe '#create' do
    before { allow(client).to receive(:get).and_return([]) } # el número está libre

    it 'manda los campos de la UDT y devuelve el Code que asignó SAP' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      expect(branches.create(valid_attributes)).to eq(9)

      expect(client).to have_received(:post).with('U_CL_FEC_SUCURSALES', body: hash_including(
        'U_SucursalNum' => 2,
        'U_EmsrUbProvincia' => '1',
        'U_EmsrTlfCodigoPais' => 506,
        'U_Active' => 'Y',
        'U_Alias' => 'Central'
      ))
    end

    # `Code` y `Name` los asigna SAP: mandarlos es pedirle que falle.
    it 'no manda Code ni Name' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      branches.create(valid_attributes)

      expect(client).to have_received(:post) do |_path, body:|
        expect(body.keys).not_to include('Code', 'Name')
      end
    end

    it 'traduce el estado inactivo a la N de la UDT' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      branches.create(valid_attributes(active: false))

      expect(client).to have_received(:post).with(anything, body: hash_including('U_Active' => 'N'))
    end

    it 'rechaza un campo requerido en blanco antes de escribir' do
      allow(client).to receive(:post)

      expect { branches.create(valid_attributes(alias_name: '')) }
        .to raise_error(described_class::InvalidBranch, 'El alias es requerido.')
      expect(client).not_to have_received(:post)
    end

    it 'rechaza un número de sucursal que no es positivo' do
      expect { branches.create(valid_attributes(number: 0)) }
        .to raise_error(described_class::InvalidBranch, /mayor a cero/)
    end

    it 'rechaza un correo con formato inválido' do
      expect { branches.create(valid_attributes(correo: 'sucursal.acme.cr')) }
        .to raise_error(described_class::InvalidBranch, /formato válido/)
    end

    # El largo lo impone el schema de la UDT; pasarse lo rechaza SAP con un
    # error genérico, así que se ataja acá para poder decir qué campo es.
    it 'rechaza un alias más largo de lo que declara el schema' do
      expect { branches.create(valid_attributes(alias_name: 'x' * 51)) }
        .to raise_error(described_class::InvalidBranch, /no puede tener más de 50 caracteres/)
    end

    it 'rechaza un número de sucursal ya usado' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, number: 2)])
      allow(client).to receive(:post)

      expect { branches.create(valid_attributes(number: 2)) }
        .to raise_error(described_class::DuplicateNumber, 'Ya existe una sucursal con el número 2.')
      expect(client).not_to have_received(:post)
    end
  end

  describe '#update' do
    it 'escribe sobre la entidad por su Code' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:patch)

      branches.update(code: 7, attributes: valid_attributes)

      expect(client).to have_received(:patch).with('U_CL_FEC_SUCURSALES(7)', body: hash_including(
        'U_SucursalNum' => 2, 'U_Alias' => 'Central'
      ))
    end

    # La propia fila no cuenta como duplicado: si no, guardar sin cambiar el
    # número sería imposible.
    it 'no se reporta a sí misma como duplicada' do
      allow(client).to receive(:get).and_return([sap_row(code: 7, number: 2)])
      allow(client).to receive(:patch)

      expect { branches.update(code: 7, attributes: valid_attributes(number: 2)) }.not_to raise_error
    end

    it 'rechaza el número de OTRA sucursal' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, number: 2)])
      allow(client).to receive(:patch)

      expect { branches.update(code: 7, attributes: valid_attributes(number: 2)) }
        .to raise_error(described_class::DuplicateNumber)
      expect(client).not_to have_received(:patch)
    end
  end
end

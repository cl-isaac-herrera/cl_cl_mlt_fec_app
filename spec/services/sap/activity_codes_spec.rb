# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sap::ActivityCodes do
  let(:client) { instance_double(Clavisco::ServiceLayer::Client) }

  # `find_or_initialize_by` y no `create!`: las cuatro filas ya vienen en el
  # esquema de test, insertadas por la migración que completa el catálogo
  # (`20260915100000_add_activity_codes_sl_resources.rb`).
  def upsert_resource(code, resource:, query_params: nil)
    SlResource.unscoped.find_or_initialize_by(code: code).tap do |record|
      record.update!(resource: resource, query_params: query_params, page_size: 0, is_active: true)
    end
  end

  before do
    upsert_resource('getActivityCodes', resource: 'U_CL_FEC_ACTIVITYCODE',
                                        query_params: '$orderby=U_ActivityCode asc')
    upsert_resource('getActivityCodeByCode', resource: 'U_CL_FEC_ACTIVITYCODE(#Code#)')
    upsert_resource('createActivityCode', resource: 'U_CL_FEC_ACTIVITYCODE')
    upsert_resource('updateActivityCode', resource: 'U_CL_FEC_ACTIVITYCODE(#Code#)')
  end

  subject(:activity_codes) { described_class.new(client: client, actor: 'user@acme.cr') }

  # Una fila como la devuelve el Service Layer para la UDT.
  def sap_row(code: 1, activity_code: '621004', active: 'Y', description: 'Comercio al por menor')
    {
      'Code' => code.to_s, 'U_ActivityCode' => activity_code, 'U_Description' => description,
      'U_CreatedAt' => '2026-09-01T10:00:00-06:00', 'U_CreatedBy' => 'seed@acme.cr',
      'U_UpdatedAt' => nil, 'U_UpdatedBy' => nil, 'U_Active' => active
    }
  end

  def valid_attributes(overrides = {})
    { activity_code: '621005', description: 'Venta de repuestos' }.merge(overrides)
  end

  describe '#list' do
    it 'pide una fila de más para saber si hay página siguiente, y la recorta' do
      allow(client).to receive(:get).and_return([sap_row(code: 1), sap_row(code: 2), sap_row(code: 3)])

      result = activity_codes.list(page: 1, per_page: 2)

      expect(client).to have_received(:get).with(a_string_including('$top=3', '$skip=0'))
      expect(result.items.size).to eq(2)
      expect(result.has_more).to be(true)
    end

    it 'has_more es false cuando SAP no devolvió la fila de más' do
      allow(client).to receive(:get).and_return([sap_row])

      expect(activity_codes.list(per_page: 10).has_more).to be(false)
    end

    it 'conserva el $orderby del catálogo' do
      allow(client).to receive(:get).and_return([])

      activity_codes.list

      expect(client).to have_received(:get).with(a_string_including('$orderby=U_ActivityCode asc'))
    end

    # No hay pantalla que muestre inactivos (ver la cabecera de la clase): la
    # lista SIEMPRE filtra por activo, no es un filtro opcional del request.
    it 'siempre filtra por Active = Y, sin que el llamador lo pida' do
      allow(client).to receive(:get).and_return([])

      activity_codes.list(filters: {})

      expect(client).to have_received(:get).with(a_string_including("U_Active eq 'Y'"))
    end

    it 'arma el filtro de código y de descripción que manda la pantalla' do
      allow(client).to receive(:get).and_return([])

      activity_codes.list(filters: { activity_code: '621004', description: 'menor' })

      expect(client).to have_received(:get).with(
        a_string_including("U_ActivityCode eq '621004'", "contains(U_Description,'menor')", "U_Active eq 'Y'")
      )
    end

    it 'escapa las comillas simples del filtro de texto' do
      allow(client).to receive(:get).and_return([])

      activity_codes.list(filters: { description: "O'Brien" })

      expect(client).to have_received(:get).with(a_string_including("contains(U_Description,'O''Brien')"))
    end

    # El `$filter` que una instalación le haya agregado desde la pantalla de
    # mantenimiento no se pisa: se le suman las condiciones del request.
    it 'combina el $filter del catálogo con el del request' do
      upsert_resource('getActivityCodes', resource: 'U_CL_FEC_ACTIVITYCODE',
                                          query_params: "$filter=(U_ActivityCode ne '000000')&$orderby=U_ActivityCode asc")
      allow(client).to receive(:get).and_return([])

      activity_codes.list

      expect(client).to have_received(:get).with(
        a_string_including("(U_ActivityCode ne '000000') and U_Active eq 'Y'")
      )
    end

    it 'acota per_page al techo del Service Layer' do
      allow(client).to receive(:get).and_return([])

      activity_codes.list(per_page: 500)

      expect(client).to have_received(:get).with(a_string_including("$top=#{described_class::MAX_PAGE_SIZE + 1}"))
    end
  end

  describe '#find' do
    it 'lee la entidad por su Code, sin comillas (la UDT es autoincremental)' do
      allow(client).to receive(:get).and_return(sap_row(code: 7, activity_code: '621099'))

      item = activity_codes.find(7)

      expect(client).to have_received(:get).with('U_CL_FEC_ACTIVITYCODE(7)')
      expect(item.code).to eq(7)
      expect(item.activity_code).to eq('621099')
    end
  end

  describe '#create' do
    before { allow(client).to receive(:get).and_return([]) } # el código no existe, ni activo ni inactivo

    it 'manda los campos de la UDT, siempre activo, y devuelve el Code que asignó SAP' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      expect(activity_codes.create(valid_attributes)).to eq(9)

      expect(client).to have_received(:post).with('U_CL_FEC_ACTIVITYCODE', body: hash_including(
        'U_ActivityCode' => '621005',
        'U_Description'  => 'Venta de repuestos',
        'U_Active'       => 'Y',
        'U_CreatedBy'    => 'user@acme.cr'
      ))
    end

    # `Code` lo asigna SAP: mandarlo es pedirle que falle.
    it 'no manda Code' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      activity_codes.create(valid_attributes)

      expect(client).to have_received(:post) do |_path, body:|
        expect(body.keys).not_to include('Code')
      end
    end

    # El PATCH del Service Layer es parcial: no reenviar Updated* en el alta no
    # los deja en blanco a propósito, simplemente no hay nada que actualizar.
    it 'no manda UpdatedAt ni UpdatedBy en el alta' do
      allow(client).to receive(:post).and_return({ 'Code' => '9' })

      activity_codes.create(valid_attributes)

      expect(client).to have_received(:post) do |_path, body:|
        expect(body.keys).not_to include('U_UpdatedAt', 'U_UpdatedBy')
      end
    end

    it 'rechaza un campo requerido en blanco antes de escribir' do
      allow(client).to receive(:post)

      expect { activity_codes.create(valid_attributes(description: '')) }
        .to raise_error(described_class::InvalidActivityCode, 'La descripción es requerido.')
      expect(client).not_to have_received(:post)
    end

    # El largo lo impone el schema de la UDT; pasarse lo rechaza SAP con un
    # error genérico, así que se ataja acá para poder decir qué campo es.
    it 'rechaza un código más largo de lo que declara el schema' do
      expect { activity_codes.create(valid_attributes(activity_code: '1234567')) }
        .to raise_error(described_class::InvalidActivityCode, /no puede tener más de 6 caracteres/)
    end

    it 'rechaza un código de actividad que ya está ACTIVO' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, activity_code: '621005', active: 'Y')])
      allow(client).to receive(:post)

      expect { activity_codes.create(valid_attributes(activity_code: '621005')) }
        .to raise_error(described_class::DuplicateActivityCode,
                        'Ya existe un código de actividad activo con el valor 621005.')
      expect(client).not_to have_received(:post)
    end

    # El corazón de la regla de negocio: dar de alta un código que ya existe
    # pero INACTIVO no crea una fila nueva, reactiva la que ya estaba.
    it 'reactiva la fila inactiva en vez de crear una nueva' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, activity_code: '621005', active: 'N')])
      allow(client).to receive(:patch)
      allow(client).to receive(:post)

      expect(activity_codes.create(valid_attributes(activity_code: '621005', description: 'Nueva descripción')))
        .to eq(4)

      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(4)', body: hash_including(
        'U_ActivityCode' => '621005', 'U_Description' => 'Nueva descripción', 'U_Active' => 'Y'
      ))
      expect(client).not_to have_received(:post)
    end
  end

  describe '#update' do
    it 'escribe sobre la entidad por su Code, siempre activa' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:patch)

      activity_codes.update(code: 7, attributes: valid_attributes)

      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(7)', body: hash_including(
        'U_ActivityCode' => '621005', 'U_Description' => 'Venta de repuestos',
        'U_Active' => 'Y', 'U_UpdatedBy' => 'user@acme.cr'
      ))
    end

    # No reenvía CreatedAt/CreatedBy: el PATCH del Service Layer es parcial y
    # esos dos campos se quedan como están.
    it 'no reenvía CreatedAt ni CreatedBy' do
      allow(client).to receive(:get).and_return([])
      allow(client).to receive(:patch)

      activity_codes.update(code: 7, attributes: valid_attributes)

      expect(client).to have_received(:patch) do |_path, body:|
        expect(body.keys).not_to include('U_CreatedAt', 'U_CreatedBy')
      end
    end

    # La propia fila no cuenta como duplicada: si no, guardar sin cambiar el
    # código sería imposible.
    it 'no se reporta a sí misma como duplicada' do
      allow(client).to receive(:get).and_return([sap_row(code: 7, activity_code: '621005')])
      allow(client).to receive(:patch)

      expect { activity_codes.update(code: 7, attributes: valid_attributes(activity_code: '621005')) }
        .not_to raise_error
    end

    it 'rechaza el código de OTRA fila activa' do
      allow(client).to receive(:get).and_return([sap_row(code: 4, activity_code: '621005')])
      allow(client).to receive(:patch)

      expect { activity_codes.update(code: 7, attributes: valid_attributes(activity_code: '621005')) }
        .to raise_error(described_class::DuplicateActivityCode)
      expect(client).not_to have_received(:patch)
    end
  end

  describe '#deactivate' do
    # El "eliminar" de la pantalla: nunca borra, solo apaga U_Active — y no
    # toca ActivityCode ni Description, el PATCH del Service Layer es parcial.
    it 'manda únicamente Active: N, sin tocar ActivityCode ni Description' do
      allow(client).to receive(:patch)

      activity_codes.deactivate(code: 7)

      expect(client).to have_received(:patch).with('U_CL_FEC_ACTIVITYCODE(7)', body: {
        'U_Active' => 'N', 'U_UpdatedAt' => anything, 'U_UpdatedBy' => 'user@acme.cr'
      })
    end
  end
end

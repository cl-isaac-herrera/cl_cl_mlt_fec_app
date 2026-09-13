# frozen_string_literal: true

module Sap
  # Sucursales del emisor, en la UDT `@CL_FEC_SUCURSALES` —cuyos datos el
  # Service Layer expone como el entity set `U_CL_FEC_SUCURSALES`, que es el
  # nombre que guarda el catálogo (`db/seeds.rb` → `SL_RESOURCES_BRANCHES`)—
  # declarada en `config/sap_schemas/sucursales_udt.json`.
  #
  #   branches = Sap::Branches.new(client: client)
  #   branches.list(page: 1, per_page: 10, filters: { alias: 'Central', active: true })
  #   branches.create(attributes)
  #   branches.update(code: 3, attributes: attributes)
  #
  # ── Por qué SAP y no la base de la aplicación ───────────────────────────────
  # El .NET las guardaba en su propia base (`spGetSucursalByCompany`,
  # `spCreateSucursal`, `spUpdateSucursal`) con una columna `CompanyId`. Acá la
  # compañía es la BASE de SAP contra la que se consulta, así que no hay ningún
  # `CompanyId` que mandar ni que filtrar: la fila que devuelve una compañía es,
  # por construcción, de esa compañía.
  #
  # Es además donde el resto del producto ya las lee: la ubicación, el teléfono
  # y el correo del emisor de un comprobante salen de esta UDT con el prefijo
  # `Emsr` (ver `Documents::UnifiedBuilder#emisor`). Mantener una segunda copia
  # en la base de la aplicación obligaría a sincronizar las dos a mano.
  #
  # ── Por qué NO hay `Total` ──────────────────────────────────────────────────
  # Mismo motivo que `Sap::IssuedDocumentsSearch`: el Service Layer no devuelve
  # más de 20 filas por respuesta sin el header `Prefer: odata.maxpagesize`, que
  # `Clavisco::ServiceLayer::Client` todavía no soporta (`TODOS.md` → SAP). En
  # vez de mentir un total se pide una fila de más y se avisa `has_more`.
  class Branches
    # Los `code` del catálogo (`db/seeds.rb` → `SL_RESOURCES_BRANCHES`).
    LIST_CODE   = 'getBranches'
    FETCH_CODE  = 'getBranchByCode'
    CREATE_CODE = 'createBranch'
    UPDATE_CODE = 'updateBranch'

    # Deja margen bajo el techo real de 20 filas por respuesta del Service Layer
    # para que `per_page + 1` —la fila que se espía para saber si hay página
    # siguiente— nunca choque contra ese límite. Mismo criterio y mismo valor que
    # `Sap::IssuedDocumentsSearch::MAX_PAGE_SIZE`.
    MAX_PAGE_SIZE = 19

    # Los datos de la sucursal no pasan la validación. No es un error de SAP: no
    # se llegó a intentar la escritura.
    class InvalidBranch < StandardError; end

    # Ya hay otra sucursal con ese número. Se separa de `InvalidBranch` porque el
    # motivo no está en los datos que se mandaron sino en lo que ya existe.
    class DuplicateNumber < StandardError; end

    # `U_Active` es `db_Alpha(1)` con `ValidValues` Y/N (así lo declara el
    # schema), no un booleano: la traducción a `true`/`false` pasa acá, en el
    # borde, para que nadie más abajo tenga que saber que una sucursal activa es
    # la letra Y.
    ACTIVE_YES = 'Y'
    ACTIVE_NO  = 'N'

    # Una sucursal ya leída. `code` es la llave que SAP autoincrementa en la UDT
    # —reemplaza al `Id` de la tabla del .NET— y `number` es el número de
    # sucursal ante Hacienda, que es el que ve el usuario.
    Branch = Data.define(:code, :number, :provincia, :canton, :distrito, :barrio,
                         :otras_senas, :telefono_codigo_pais, :telefono,
                         :fax_codigo_pais, :fax, :correo, :active, :alias_name)

    Result = Struct.new(:items, :has_more, keyword_init: true)

    # Largos que declara `config/sap_schemas/sucursales_udt.json`. Se validan acá
    # para que pasarse devuelva un mensaje que diga qué campo y cuánto, en vez del
    # error genérico con el que SAP rechaza la escritura.
    MAX_LENGTHS = {
      provincia:   1,
      canton:      2,
      distrito:    2,
      barrio:      50,
      otras_senas: 250,
      telefono:    15,
      fax:         20,
      correo:      160,
      alias_name:  50
    }.freeze

    # Nombre visible de cada campo, para los mensajes de error. Son los mismos
    # rótulos del formulario, así que el usuario reconoce cuál corregir.
    LABELS = {
      number:      'El número de sucursal',
      provincia:   'La provincia',
      canton:      'El cantón',
      distrito:    'El distrito',
      barrio:      'El barrio',
      otras_senas: 'La dirección',
      telefono:    'El teléfono',
      fax:         'El fax',
      correo:      'El correo electrónico',
      alias_name:  'El alias'
    }.freeze

    # Los que no pueden ir en blanco. `fax` queda fuera a propósito: el
    # formulario lo ofrece opcional y el schema lo declara `tNO`.
    REQUIRED = %i[number provincia canton distrito barrio otras_senas telefono correo alias_name].freeze

    # Mismo criterio que el validador del formulario: se comprueba la forma, no
    # se intenta decidir si el buzón existe.
    EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[A-Za-z]{2,}\z/

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía activa.
    def initialize(client:)
      @client = client
    end

    # Las sucursales de la compañía, paginadas y filtradas EN SAP.
    #
    # Devuelve activas e inactivas: el estado es uno de los filtros, no un corte
    # fijo de la consulta. Una sucursal dada de baja tiene que poder verse para
    # poder reactivarse — mismo criterio que el `unscoped` de las pantallas de
    # administración de la base propia (`CLAUDE.md` §28).
    #
    # @param filters [Hash] `:alias, :provincia, :canton, :distrito, :active`
    #   (todos opcionales; `:active` es terciario — `nil` no filtra).
    # @return [Result]
    def list(page: 1, per_page: 10, filters: {})
      size = per_page.to_i.clamp(1, MAX_PAGE_SIZE)
      num  = [page.to_i, 1].max

      rows = Array.wrap(client.get(list_query(num, size, filters).path))

      Result.new(items: rows.first(size).map { |raw| build(Documents::Row.new(raw)) },
                 has_more: rows.size > size)
    end

    # Una sucursal por su `Code`: la entidad por llave, sin ambigüedad posible.
    # La usa el panel de edición para releer del servidor en vez de confiar en la
    # fila de la tabla, que pudo quedar vieja.
    #
    # @return [Branch]
    # @raise [Clavisco::ServiceLayer::Client::NotFoundError] si el `Code` no existe.
    def find(code)
      build(Documents::Row.new(client.get(Sap::ResourceQuery.path_for(FETCH_CODE, Code: code))))
    end

    # Registra una sucursal nueva.
    #
    # `Code` y `Name` NO se mandan: la UDT es `bott_NoObjectAutoIncrement`, así
    # que los asigna SAP — mismo criterio que `Sap::MailQueue#create`.
    #
    # @param attributes [Hash] con las llaves de `Branch` (menos `code`).
    # @return [Integer, nil] el `Code` que SAP le asignó a la fila nueva.
    def create(attributes)
      validate!(attributes)
      ensure_number_available!(attributes[:number])

      row = Documents::Row.new(client.post(Sap::ResourceQuery.path_for(CREATE_CODE), body: body_for(attributes)))
      row.integer('Code')
    end

    # Actualiza una sucursal existente.
    #
    # Se mandan TODOS los campos y no solo los que cambiaron: el formulario es el
    # estado completo de la sucursal, y un PATCH parcial armado desde la pantalla
    # no podría distinguir "no lo tocaron" de "lo dejaron en blanco".
    #
    # @param code [Integer] la llave de la UDT, no el número de sucursal.
    def update(code:, attributes:)
      validate!(attributes)
      ensure_number_available!(attributes[:number], except_code: code)

      client.patch(Sap::ResourceQuery.path_for(UPDATE_CODE, Code: code), body: body_for(attributes))
    end

    private

    attr_reader :client

    # El `$filter` que traiga el catálogo se CONSERVA y se le suman con `and` las
    # condiciones del request — nunca se reemplaza. Es lo mismo que hace
    # `Sap::IssuedDocumentsSearch#query`: una instalación puede haberle agregado
    # una condición propia desde la pantalla de mantenimiento.
    def list_query(page, per_page, filters)
      base     = Sap::ResourceQuery.new(LIST_CODE)
      combined = [base.params['$filter'], request_filter(filters)].reject(&:blank?).join(' and ')

      extra = { '$top' => per_page + 1, '$skip' => (page - 1) * per_page }
      extra['$filter'] = combined if combined.present?

      base.merge(extra)
    end

    # Las condiciones que dependen del request. `contains` para el alias (texto
    # libre) y `eq` para los códigos de ubicación, que son exactos.
    #
    # Cantón y distrito se comparan solos aunque su código solo sea único dentro
    # del padre: la pantalla siempre manda la cadena completa (provincia →
    # cantón → distrito), así que el `and` de los tres desambigua.
    def request_filter(filters)
      [
        text_contains('U_Alias', filters[:alias]),
        text_eq('U_EmsrUbProvincia', filters[:provincia]),
        text_eq('U_EmsrUbCanton', filters[:canton]),
        text_eq('U_EmsrUbDistrito', filters[:distrito]),
        active_filter(filters[:active]),
        numeric_eq('U_SucursalNum', filters[:number])
      ].compact.join(' and ')
    end

    # `nil` = sin filtrar, que NO es lo mismo que `false` ("solo las inactivas").
    # Por eso se compara contra `nil` y no con `present?` — mismo cuidado que el
    # `is_standard` de `SlResource.search`.
    def active_filter(value)
      return nil if value.nil?

      "U_Active eq #{quote(value ? ACTIVE_YES : ACTIVE_NO)}"
    end

    def text_contains(field, value)
      return nil if value.blank?

      "contains(#{field},#{quote(value)})"
    end

    def text_eq(field, value)
      return nil if value.blank?

      "#{field} eq #{quote(value)}"
    end

    def numeric_eq(field, value)
      return nil if value.blank?
      return nil unless value.to_s.match?(/\A-?\d+\z/)

      "#{field} eq #{value}"
    end

    # Literal string OData: comillas simples, duplicando las que traiga el valor.
    # Duplica `Clavisco::ServiceLayer::OdataFilter#format_value`, que es `private`
    # en el submódulo — mismo motivo que `Sap::ResourceQuery#odata_literal`
    # (`TODOS.md` → SAP).
    def quote(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def build(row)
      Branch.new(
        code:                 row.integer('Code'),
        number:               row.integer('U_SucursalNum'),
        provincia:            row.string('U_EmsrUbProvincia'),
        canton:               row.string('U_EmsrUbCanton'),
        distrito:             row.string('U_EmsrUbDistrito'),
        barrio:               row.string('U_EmsrUbBarrio'),
        otras_senas:          row.string('U_EmsrUbOtrasSenas'),
        telefono_codigo_pais: row.integer('U_EmsrTlfCodigoPais'),
        telefono:             row.string('U_EmsrTlfNumTelefono'),
        fax_codigo_pais:      row.integer('U_EmsrFaxCodigoPais'),
        fax:                  row.string('U_EmsrFaxNumTelefono'),
        correo:               row.string('U_EmsrCorreoElectronico'),
        active:               row.string('U_Active').to_s.casecmp(ACTIVE_YES).zero?,
        alias_name:           row.string('U_Alias')
      )
    end

    def body_for(attributes)
      {
        'U_SucursalNum'           => attributes[:number].to_i,
        'U_EmsrUbProvincia'       => attributes[:provincia],
        'U_EmsrUbCanton'          => attributes[:canton],
        'U_EmsrUbDistrito'        => attributes[:distrito],
        'U_EmsrUbBarrio'          => attributes[:barrio],
        'U_EmsrUbOtrasSenas'      => attributes[:otras_senas],
        'U_EmsrTlfCodigoPais'     => attributes[:telefono_codigo_pais].to_i,
        'U_EmsrTlfNumTelefono'    => attributes[:telefono],
        'U_EmsrFaxCodigoPais'     => attributes[:fax_codigo_pais].to_i,
        'U_EmsrFaxNumTelefono'    => attributes[:fax],
        'U_EmsrCorreoElectronico' => attributes[:correo],
        'U_Active'                => attributes[:active] ? ACTIVE_YES : ACTIVE_NO,
        'U_Alias'                 => attributes[:alias_name]
      }
    end

    # La pantalla ya valida lo mismo, pero la UI se puede manipular y la UDT no
    # tiene validaciones propias: lo que llegue mal se escribe tal cual y termina
    # en un comprobante.
    def validate!(attributes)
      errors = REQUIRED.filter_map { |field| "#{LABELS[field]} es requerido." if attributes[field].blank? }

      errors << "#{LABELS[:number]} debe ser mayor a cero." if positive_number?(attributes[:number]) == false
      errors << "#{LABELS[:correo]} no tiene un formato válido." unless valid_email?(attributes[:correo])
      errors.concat(length_errors(attributes))

      raise InvalidBranch, errors.first if errors.any?
    end

    # `nil` cuando el campo vino en blanco: de eso ya se queja `REQUIRED`, y
    # sumar "debe ser mayor a cero" encima solo confunde.
    def positive_number?(value)
      return nil if value.blank?

      value.to_s.match?(/\A\d+\z/) && value.to_i.positive?
    end

    # Un correo en blanco lo reporta `REQUIRED`; acá solo se juzga el formato del
    # que sí vino.
    def valid_email?(value)
      value.blank? || value.to_s.match?(EMAIL_FORMAT)
    end

    def length_errors(attributes)
      MAX_LENGTHS.filter_map do |field, max|
        value = attributes[field]
        next if value.blank? || value.to_s.length <= max

        "#{LABELS[field]} no puede tener más de #{max} caracteres."
      end
    end

    # El número de sucursal es lo que Hacienda usa para armar el consecutivo del
    # comprobante: dos sucursales con el mismo número emitirían consecutivos que
    # chocan entre sí. La UDT no puede declararlo único, así que se comprueba
    # acá, contra SAP, antes de escribir.
    #
    # @param except_code [Integer, nil] al editar, la propia fila no cuenta como
    #   duplicado.
    def ensure_number_available!(number, except_code: nil)
      taken = list(page: 1, per_page: MAX_PAGE_SIZE, filters: { number: number })
              .items
              .reject { |branch| except_code.present? && branch.code == except_code.to_i }

      return if taken.empty?

      raise DuplicateNumber, "Ya existe una sucursal con el número #{number}."
    end
  end
end

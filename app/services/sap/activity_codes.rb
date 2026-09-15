# frozen_string_literal: true

module Sap
  # Códigos de actividad económica de la compañía, en la UDT
  # `@CL_FEC_ACTIVITYCODE` —cuyos datos el Service Layer expone como el entity
  # set `U_CL_FEC_ACTIVITYCODE`, que es el nombre que guarda el catálogo
  # (`db/seeds.rb` → `SL_RESOURCES_ACTIVITY_CODES`)— declarada en
  # `config/sap_schemas/activity_codes_udt.json`.
  #
  #   activity_codes = Sap::ActivityCodes.new(client: client, actor: 'user@acme.cr')
  #   activity_codes.list(page: 1, per_page: 10)
  #   activity_codes.create(attributes)               # alta, o reactiva uno inactivo
  #   activity_codes.update(code: 3, attributes: attributes)
  #   activity_codes.deactivate(code: 3)
  #
  # ── Por qué SAP y no la base de la aplicación ───────────────────────────────
  # El .NET los guardaba en su propia base (`spGetActivityCodesByCompany`,
  # `spSaveCompanyActivityCodes` — este último reemplazaba la lista ENTERA en
  # cada guardado) con una columna `CompanyId`. Acá la compañía es la BASE de SAP
  # contra la que se consulta, así que no hay ningún `CompanyId` que mandar ni
  # que filtrar — mismo criterio que `Sap::Branches`.
  #
  # ── No hay un estado "Activo" que el usuario vea o elija ────────────────────
  # A diferencia de `Sap::Branches`, acá el activo/inactivo NO es un campo del
  # formulario: es un efecto de las dos únicas acciones que el usuario tiene.
  # Un código que aparece en la lista está activo, y punto:
  #
  #   - el botón "eliminar" lo INACTIVA (`deactivate`) y desaparece de la lista
  #     —nunca se borra, un comprobante viejo pudo referenciarlo—;
  #   - volver a dar de alta el MISMO código de actividad no crea una fila
  #     duplicada: `create` encuentra la fila inactiva y la reactiva.
  #
  # Por esto `list` (y por lo tanto lo que ve la pantalla) filtra SIEMPRE por
  # `Active = 'Y'`: un código inactivo no es "dado de baja pero visible para
  # reactivar" como una sucursal — es indistinguible de uno que nunca existió,
  # hasta que alguien vuelve a escribir ese mismo código.
  #
  # ── Por qué NO hay `Total` ──────────────────────────────────────────────────
  # Mismo motivo que `Sap::Branches`: el Service Layer no devuelve más de 20
  # filas por respuesta sin el header `Prefer: odata.maxpagesize`, que
  # `Clavisco::ServiceLayer::Client` todavía no soporta (`TODOS.md` → SAP). En
  # vez de mentir un total se pide una fila de más y se avisa `has_more`.
  class ActivityCodes
    # Los `code` del catálogo (`db/seeds.rb` → `SL_RESOURCES_ACTIVITY_CODES`).
    LIST_CODE   = 'getActivityCodes'
    FETCH_CODE  = 'getActivityCodeByCode'
    CREATE_CODE = 'createActivityCode'
    UPDATE_CODE = 'updateActivityCode'

    # Deja margen bajo el techo real de 20 filas por respuesta del Service Layer
    # para que `per_page + 1` —la fila que se espía para saber si hay página
    # siguiente— nunca choque contra ese límite. Mismo criterio y mismo valor que
    # `Sap::Branches::MAX_PAGE_SIZE`.
    MAX_PAGE_SIZE = 19

    # Los datos del código no pasan la validación. No es un error de SAP: no se
    # llegó a intentar la escritura.
    class InvalidActivityCode < StandardError; end

    # Ya hay otro código de actividad ACTIVO con el mismo valor. Se separa de
    # `InvalidActivityCode` porque el motivo no está en los datos que se
    # mandaron sino en lo que ya existe. En la práctica casi no debería pasar
    # —la pantalla no deja ver dos códigos activos iguales para elegir— salvo
    # que otro proceso lo haya creado mientras tanto.
    class DuplicateActivityCode < StandardError; end

    # `U_Active` es `db_Alpha(1)` con `ValidValues` Y/N (así lo declara el
    # schema), no un booleano: la traducción a `true`/`false` pasa acá, en el
    # borde, para que nadie más abajo tenga que saber que un código activo es la
    # letra Y.
    ACTIVE_YES = 'Y'
    ACTIVE_NO  = 'N'

    # Un código de actividad ya leído. `code` es la llave que SAP autoincrementa
    # en la UDT —reemplaza al `Id` de la tabla del .NET—; `activity_code` es el
    # código de actividad económica ante Hacienda, que es el que ve el usuario.
    # `active` es de uso INTERNO del servicio (decidir si `create` reactiva en
    # vez de crear); no se expone a la API.
    ActivityCode = Data.define(:code, :activity_code, :description, :active,
                               :created_at, :created_by, :updated_at, :updated_by)

    Result = Struct.new(:items, :has_more, keyword_init: true)

    # Largos que declara `config/sap_schemas/activity_codes_udt.json`. Se validan
    # acá para que pasarse devuelva un mensaje que diga qué campo y cuánto, en vez
    # del error genérico con el que SAP rechaza la escritura.
    MAX_LENGTHS = {
      activity_code: 6,
      description:   254
    }.freeze

    # Nombre visible de cada campo, para los mensajes de error. Son los mismos
    # rótulos del formulario, así que el usuario reconoce cuál corregir.
    LABELS = {
      activity_code: 'El código de actividad',
      description:   'La descripción'
    }.freeze

    REQUIRED = %i[activity_code description].freeze

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía activa.
    # @param actor [String, nil] identificador de quien escribe (`U_CreatedBy` /
    #   `U_UpdatedBy`). Mismo criterio que `Clavisco::DataAccess::Auditable`:
    #   `Current.user&.email || 'system'`.
    def initialize(client:, actor: nil)
      @client = client
      @actor  = actor.presence || 'system'
    end

    # Los códigos de actividad ACTIVOS de la compañía, paginados y filtrados EN
    # SAP. No hay forma de pedir los inactivos: no hay pantalla que los
    # muestre (ver la nota de cabecera).
    #
    # @param filters [Hash] `:activity_code, :description` (opcionales).
    # @return [Result]
    def list(page: 1, per_page: 10, filters: {})
      size = per_page.to_i.clamp(1, MAX_PAGE_SIZE)
      num  = [page.to_i, 1].max

      rows = Array.wrap(client.get(list_query(num, size, filters).path))

      Result.new(items: rows.first(size).map { |raw| build(Documents::Row.new(raw)) },
                 has_more: rows.size > size)
    end

    # Un código por su `Code`: la entidad por llave, sin ambigüedad posible. Lo
    # usa el panel de edición para releer del servidor en vez de confiar en la
    # fila de la tabla, que pudo quedar vieja.
    #
    # @return [ActivityCode]
    # @raise [Clavisco::ServiceLayer::Client::NotFoundError] si el `Code` no existe.
    def find(code)
      build(Documents::Row.new(client.get(Sap::ResourceQuery.path_for(FETCH_CODE, Code: code))))
    end

    # Registra un código de actividad — o, si el mismo código ya existe pero
    # INACTIVO (alguien lo eliminó antes), lo reactiva en vez de crear una fila
    # nueva. Es la única forma en que el usuario "recupera" un código dado de
    # baja: volviendo a escribirlo.
    #
    # `Code` NO se manda al crear: la UDT es `bott_NoObjectAutoIncrement`, así
    # que lo asigna SAP — mismo criterio que `Sap::Branches#create`.
    #
    # @param attributes [Hash] `:activity_code, :description`.
    # @return [Integer, nil] el `Code` de la fila (nueva o reactivada).
    def create(attributes)
      validate!(attributes)

      dormant = find_any_by_activity_code(attributes[:activity_code])
      if dormant
        raise DuplicateActivityCode, "Ya existe un código de actividad activo con el valor #{attributes[:activity_code]}." if dormant.active

        client.patch(Sap::ResourceQuery.path_for(UPDATE_CODE, Code: dormant.code), body: update_body(attributes))
        return dormant.code
      end

      row = Documents::Row.new(client.post(Sap::ResourceQuery.path_for(CREATE_CODE), body: create_body(attributes)))
      row.integer('Code')
    end

    # Actualiza el código/descripción de una fila ACTIVA existente. No toca el
    # estado: para eso está `deactivate`.
    #
    # Se mandan los dos campos editables y no solo el que cambió: el formulario
    # es el estado completo de la fila, y un PATCH parcial no podría distinguir
    # "no lo tocaron" de "lo dejaron en blanco".
    #
    # @param code [Integer] la llave de la UDT, no el código de actividad.
    def update(code:, attributes:)
      validate!(attributes)
      ensure_activity_code_available!(attributes[:activity_code], except_code: code)

      client.patch(Sap::ResourceQuery.path_for(UPDATE_CODE, Code: code), body: update_body(attributes))
    end

    # Inactiva la fila: es el "eliminar" de la pantalla. Nunca se borra —un
    # comprobante viejo pudo referenciarla— y vuelve a estar disponible el día
    # que alguien dé de alta el mismo `activity_code` (ver `create`).
    #
    # @param code [Integer] la llave de la UDT.
    def deactivate(code:)
      client.patch(Sap::ResourceQuery.path_for(UPDATE_CODE, Code: code), body: deactivate_body)
    end

    private

    attr_reader :client, :actor

    # El `$filter` que traiga el catálogo se CONSERVA y se le suman con `and` las
    # condiciones del request — nunca se reemplaza. Mismo criterio que
    # `Sap::Branches#list_query`.
    def list_query(page, per_page, filters)
      base     = Sap::ResourceQuery.new(LIST_CODE)
      combined = [base.params['$filter'], request_filter(filters)].reject(&:blank?).join(' and ')

      extra = { '$top' => per_page + 1, '$skip' => (page - 1) * per_page }
      extra['$filter'] = combined if combined.present?

      base.merge(extra)
    end

    # `eq` para el código (exacto, es la llave de negocio) y `contains` para la
    # descripción (texto libre). `Active` SIEMPRE se filtra en `Y`: no hay
    # ningún llamador que pida ver los inactivos (ver la nota de cabecera).
    def request_filter(filters)
      [
        text_eq('U_ActivityCode', filters[:activity_code]),
        text_contains('U_Description', filters[:description]),
        "U_Active eq #{quote(ACTIVE_YES)}"
      ].compact.join(' and ')
    end

    def text_contains(field, value)
      return nil if value.blank?

      "contains(#{field},#{quote(value)})"
    end

    def text_eq(field, value)
      return nil if value.blank?

      "#{field} eq #{quote(value)}"
    end

    # Literal string OData: comillas simples, duplicando las que traiga el valor.
    # Duplica `Clavisco::ServiceLayer::OdataFilter#format_value`, que es `private`
    # en el submódulo — mismo motivo que `Sap::ResourceQuery#odata_literal`
    # (`TODOS.md` → SAP).
    def quote(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def build(row)
      ActivityCode.new(
        code:          row.integer('Code'),
        activity_code: row.string('U_ActivityCode'),
        description:   row.string('U_Description'),
        active:        row.string('U_Active').to_s.casecmp(ACTIVE_YES).zero?,
        created_at:    row.string('U_CreatedAt'),
        created_by:    row.string('U_CreatedBy'),
        updated_at:    row.string('U_UpdatedAt'),
        updated_by:    row.string('U_UpdatedBy')
      )
    end

    # El alta manda `CreatedAt`/`CreatedBy`; `Updated*` se dejan sin mandar
    # (`Mandatory` `tNO` en el schema) porque todavía no hay ninguna
    # actualización que registrar. Siempre activo: no existe un alta inactiva.
    def create_body(attributes)
      {
        'U_ActivityCode' => attributes[:activity_code],
        'U_Description'  => attributes[:description],
        'U_Active'       => ACTIVE_YES,
        'U_CreatedAt'    => Time.current.iso8601,
        'U_CreatedBy'    => actor
      }
    end

    # El PATCH del Service Layer es parcial: no reenviar `CreatedAt`/`CreatedBy`
    # deja esos dos campos intactos en SAP. También lo usa `create` para
    # reactivar una fila inactiva —ahí SÍ importa mandar `Active` en `Y`, que es
    # lo que la reactiva—; en una edición normal la fila ya estaba activa (no
    # hay forma de editar una que no lo esté) así que mandarlo de nuevo es un
    # no-op.
    def update_body(attributes)
      {
        'U_ActivityCode' => attributes[:activity_code],
        'U_Description'  => attributes[:description],
        'U_Active'       => ACTIVE_YES,
        'U_UpdatedAt'    => Time.current.iso8601,
        'U_UpdatedBy'    => actor
      }
    end

    # Nada de `ActivityCode`/`Description`: inactivar no los toca, y el PATCH
    # del Service Layer es parcial.
    def deactivate_body
      {
        'U_Active'    => ACTIVE_NO,
        'U_UpdatedAt' => Time.current.iso8601,
        'U_UpdatedBy' => actor
      }
    end

    # La pantalla ya valida lo mismo, pero la UI se puede manipular y la UDT no
    # tiene validaciones propias: lo que llegue mal se escribe tal cual y termina
    # en un comprobante.
    def validate!(attributes)
      errors = REQUIRED.filter_map { |field| "#{LABELS[field]} es requerido." if attributes[field].blank? }
      errors.concat(length_errors(attributes))

      raise InvalidActivityCode, errors.first if errors.any?
    end

    def length_errors(attributes)
      MAX_LENGTHS.filter_map do |field, max|
        value = attributes[field]
        next if value.blank? || value.to_s.length <= max

        "#{LABELS[field]} no puede tener más de #{max} caracteres."
      end
    end

    # El código de actividad es la llave que ve Hacienda, y la UDT no puede
    # declararlo único: se comprueba acá, contra SAP, antes de escribir. Solo
    # entre los ACTIVOS —dar de baja un código libera el valor para poder darlo
    # de alta de nuevo—, mismo criterio que `email_configs` (`CLAUDE.md` §38).
    # La usa `update`; `create` no, porque su regla es distinta (reactiva en vez
    # de rechazar cuando lo que encuentra está inactivo).
    #
    # @param except_code [Integer, nil] al editar, la propia fila no cuenta como
    #   duplicada.
    def ensure_activity_code_available!(activity_code, except_code: nil)
      taken = list(page: 1, per_page: MAX_PAGE_SIZE, filters: { activity_code: activity_code })
              .items
              .reject { |row| except_code.present? && row.code == except_code.to_i }

      return if taken.empty?

      raise DuplicateActivityCode, "Ya existe un código de actividad activo con el valor #{activity_code}."
    end

    # A diferencia de `list`/`ensure_activity_code_available!`, acá SÍ hace
    # falta ver los inactivos: es como `create` decide si tiene que reactivar
    # una fila en vez de pedirle una nueva a SAP. El `$filter` del catálogo se
    # conserva igual que en `list_query` — no se reemplaza. `$top=2` alcanza:
    # si hay más de una coincidencia ya hay datos inconsistentes en SAP, y
    # cualquiera de las dos sirve igual para decidir.
    def find_any_by_activity_code(activity_code)
      base     = Sap::ResourceQuery.new(LIST_CODE)
      combined = [base.params['$filter'], "U_ActivityCode eq #{quote(activity_code)}"].reject(&:blank?).join(' and ')

      row = Array.wrap(client.get(base.merge('$filter' => combined, '$top' => 2).path)).first
      row && build(Documents::Row.new(row))
    end
  end
end

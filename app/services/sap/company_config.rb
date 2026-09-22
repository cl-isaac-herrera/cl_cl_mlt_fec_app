# frozen_string_literal: true

module Sap
  # Configuración del emisor ante Hacienda de una compañía, en la UDT
  # `@CL_FEC_ISSUERCONFIG` —cuyos datos el Service Layer expone como el entity
  # set `U_CL_FEC_ISSUERCONFIG`, que es el nombre que guarda el catálogo
  # (`db/seeds.rb` → `SL_RESOURCES_COMPANY_CONFIG`)— declarada en
  # `config/sap_schemas/company_config_udt.json`.
  #
  #   config = Sap::CompanyConfig.new(client: client, actor: 'user@acme.cr')
  #   config.read                                     # => Config o nil
  #   config.create(legal_name: 'ACME S.A.', id_type: '02', …)
  #   config.update(legal_name: 'ACME S.A.', …)        # PATCH parcial
  #
  # ── Una sola fila por base de SAP, `Code` fijo ──────────────────────────────
  # La compañía ES la base de SAP contra la que se consulta (mismo criterio que
  # `Sap::Branches`/`Sap::ActivityCodes`): no hay `CompanyId` que mandar. A
  # diferencia de esas dos, acá solo existe UNA fila —la configuración de ESA
  # compañía—, así que no hace falta un `Code` dinámico: la UDT es
  # `bott_NoObjectAutoIncrement` y la única fila que se crea siempre recibe el
  # `Code` `1`, que es el que declara el catálogo (`getCompanyConfig` y
  # `updateCompanyConfig` van contra `U_CL_FEC_ISSUERCONFIG(1)`).
  #
  # ── Por qué revive una decisión que CLAUDE.md §32 documentó como revertida ──
  # Estos mismos campos vivieron como UDFs de `OADM`
  # (`20260819130000_add_issuer_fields_to_companies.rb` los trajo de vuelta a
  # `companies`). La razón de aquella reversión —costaba una vuelta a SAP para
  # pintar un formulario, credenciales de SAP obligatorias para editarlo,
  # validación imposible del lado del modelo— sigue siendo válida: se acepta a
  # propósito, documentado en `docs/PLAN-UDT-CONFIG-EMISOR.md`.
  #
  # ── La emisión de documentos NO usa este servicio ───────────────────────────
  # `Documents::UnifiedBuilder` no lo llama: la vista de cabecera que ya
  # consulta `Sap::DocumentDetails` trae la identificación del emisor resuelta
  # en `Emsr*`/`Rcpr*` según el tipo de documento (ver la cabecera de esa
  # clase), en la MISMA consulta que arma el resto del comprobante. Este
  # servicio es solo para la sección "Datos Generales" del formulario de
  # compañías.
  #
  # ── Qué NO está acá ──────────────────────────────────────────────────────────
  # `CommercialName`: nadie lo leería — el nombre comercial sale de
  # `companies.name` (`Api::CompaniesController#serialize_detail`) o de la vista
  # de cabecera (`EmsrNombreComercial`) para la emisión; declararlo acá sería la
  # MISMA duplicación sin lector que costó la reversión original.
  #
  # `IdNumber` (la cédula): se queda ÚNICA Y EXCLUSIVAMENTE en
  # `companies.issuer_id_number`. Tres consumidores la necesitan SIN depender de
  # SAP: `CompanyFiles::Store` arma con ella la carpeta del certificado/logo/
  # formato de impresión en disco (`CLAUDE.md` §34); `MailReceptionJob#archive`
  # la usa para decidir a qué compañía pertenece un correo entrante
  # (`Company.find_by(issuer_id_number: …)` — no se puede resolver al revés,
  # consultando SAP, porque hace falta saber la compañía para tener su
  # conexión); y el listado/filtro de compañías la muestra y busca localmente.
  # Los tres son consultas que corren SIN saber de antemano con qué compañía
  # están tratando, así que no pueden empezar por hablar con el SAP de esa
  # compañía. Tenerla también en la UDT sería una fuente doble que puede
  # divergir (`CLAUDE.md` §39, "cada rol tiene UNA sola fuente"); con una sola
  # alcanza.
  class CompanyConfig
    READ_CODE   = 'getCompanyConfig'
    CREATE_CODE = 'createCompanyConfig'
    UPDATE_CODE = 'updateCompanyConfig'

    # Los datos no pasan la validación. No es un error de SAP: no se llegó a
    # intentar la escritura.
    class InvalidConfig < StandardError; end

    # La configuración ya leída. `nil` en cualquier campo es "todavía no se
    # cargó", no un error — mismo criterio que las columnas `allow_nil` que
    # reemplaza.
    Config = Data.define(:legal_name, :id_type, :economic_activity_code, :tax_registry_8707,
                          :updated_at, :updated_by)

    # Largos que declara `config/sap_schemas/company_config_udt.json` — los
    # mismos `limit:` que tenían las columnas de `companies` que reemplaza. Se
    # validan acá para que pasarse devuelva un mensaje que diga qué campo y
    # cuánto, en vez del error genérico con el que SAP rechaza la escritura.
    MAX_LENGTHS = {
      legal_name:              100,
      id_type:                 2,
      economic_activity_code:  6,
      tax_registry_8707:       12
    }.freeze

    # `'01'.to_i` perdería el cero adelante — mismo motivo que
    # `Company::ISSUER_ID_TYPES`, que replica.
    ID_TYPES = %w[01 02 03 04].freeze

    LABELS = {
      legal_name:              'La razón social',
      id_type:                 'El tipo de identificación',
      economic_activity_code:  'El código de actividad económica',
      tax_registry_8707:       'El registro fiscal (ley 8707)'
    }.freeze

    # `attributes` → `U_Campo` del cuerpo. El orden es el de la UDT.
    FIELD_MAP = {
      legal_name:              'U_LegalName',
      id_type:                 'U_IdType',
      economic_activity_code:  'U_EconomicActivityCode',
      tax_registry_8707:       'U_TaxRegistry8707'
    }.freeze

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía.
    # @param actor [String, nil] identificador de quien escribe (`U_UpdatedBy`).
    #   Mismo criterio que `Sap::ActivityCodes`: `Current.user&.email || 'system'`.
    def initialize(client:, actor: nil)
      @client = client
      @actor  = actor.presence || 'system'
    end

    # La configuración de la compañía, o `nil` si todavía no se creó la fila
    # (una compañía dada de alta antes de que este servicio existiera, sin
    # backfill todavía).
    #
    # @return [Config, nil]
    def read
      build(Documents::Row.new(client.get(Sap::ResourceQuery.path_for(READ_CODE))))
    rescue Clavisco::ServiceLayer::Client::NotFoundError
      nil
    end

    # Registra la fila única. Se usa UNA vez, al dar de alta la compañía
    # (`Api::CompaniesController#create`): ahí el formulario manda el bloque
    # completo, así que `attributes` trae las cuatro llaves aunque alguna venga
    # en blanco — a diferencia de `update`, acá no hace falta filtrar por
    # `key?`.
    #
    # @param attributes [Hash] `:legal_name, :id_type, :economic_activity_code,
    #   :tax_registry_8707`.
    def create(attributes)
      validate!(attributes)

      client.post(Sap::ResourceQuery.path_for(CREATE_CODE), body: body_for(attributes))
    end

    # Actualiza la fila única. El PATCH del Service Layer es parcial: solo se
    # mandan las llaves que `attributes` trae, para que un guardado parcial de
    # "Datos Generales" no borre en SAP lo que esa petición no mencionó — mismo
    # criterio que `Api::Companies::GeneralController#general_params`.
    #
    # @param attributes [Hash] subconjunto de `:legal_name, :id_type,
    #   :economic_activity_code, :tax_registry_8707`.
    def update(attributes)
      validate!(attributes)

      client.patch(Sap::ResourceQuery.path_for(UPDATE_CODE), body: body_for(attributes))
    end

    private

    attr_reader :client, :actor

    def build(row)
      Config.new(
        legal_name:              row.string('U_LegalName'),
        id_type:                 row.string('U_IdType'),
        economic_activity_code:  row.string('U_EconomicActivityCode'),
        tax_registry_8707:       row.string('U_TaxRegistry8707'),
        updated_at:              row.string('U_UpdatedAt'),
        updated_by:              row.string('U_UpdatedBy')
      )
    end

    def body_for(attributes)
      body = {}
      FIELD_MAP.each { |key, field| body[field] = attributes[key] if attributes.key?(key) }
      body['U_UpdatedAt'] = Time.current.iso8601
      body['U_UpdatedBy'] = actor
      body
    end

    # La pantalla ya valida lo mismo, pero la UI se puede manipular y la UDT no
    # tiene validaciones propias: lo que llegue mal se escribe tal cual y
    # termina en un comprobante.
    def validate!(attributes)
      errors = length_errors(attributes)
      errors.concat(id_type_errors(attributes))

      raise InvalidConfig, errors.first if errors.any?
    end

    def length_errors(attributes)
      MAX_LENGTHS.filter_map do |field, max|
        value = attributes[field]
        next if value.blank? || value.to_s.length <= max

        "#{LABELS[field]} no puede tener más de #{max} caracteres."
      end
    end

    def id_type_errors(attributes)
      return [] unless attributes.key?(:id_type)

      value = attributes[:id_type]
      return [] if value.blank? || ID_TYPES.include?(value)

      ["#{LABELS[:id_type]} no es válido."]
    end
  end
end

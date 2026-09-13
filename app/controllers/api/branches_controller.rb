# frozen_string_literal: true

module Api
  # Sucursales del emisor (pantalla /configurations/branches).
  #
  # Reemplaza el `SucursalController` del .NET, cuyos paths llevaban el verbo
  # adentro y el id en el cuerpo (`GET /api/Sucursal/GetSucursalByCompany?companyId=N`,
  # `PATCH /api/Sucursal`). Acá el verbo va en el método HTTP y la llave en el
  # path (`CLAUDE.md` §28).
  #
  # Tres cambios de fondo respecto del .NET, además del nombrado:
  #
  #   - **La fuente es SAP, no la base de la aplicación.** El .NET las guardaba
  #     en su propia tabla (`spGetSucursalByCompany`); acá viven en la UDT
  #     `@CL_FEC_SUCURSALES` de la compañía, que es de donde la emisión ya las
  #     lee (`Documents::UnifiedBuilder#emisor`). Ver `Sap::Branches`.
  #   - **`companyId` no viaja.** La compañía activa sale de la sesión (§28 regla
  #     5) y determina contra qué base de SAP se consulta; la fila que devuelve
  #     una compañía es, por construcción, de esa compañía.
  #   - **El filtrado y la paginación los hace SAP.** El .NET devolvía todas las
  #     sucursales y la pantalla filtraba en el browser. Acá las condiciones
  #     viajan al `$filter` de la consulta, así que el estado (activas /
  #     inactivas / todas) también es un filtro y no un corte fijo.
  #
  # ── Qué cliente usa cada acción ─────────────────────────────────────────────
  # Las lecturas van con `Sap::CompanyClient` (credenciales de LICENCIA de la
  # conexión), para que abrir la pantalla no dependa de que la persona tenga
  # credenciales de SAP propias — mismo criterio que `Api::DocumentsController#index`.
  # Las escrituras van con `Sap::UserClient` (credenciales de `Current.user`),
  # para que SAP pueda atribuirle el cambio a quien lo hizo y no al usuario
  # técnico de la sincronización — mismo criterio que `#reprocess`.
  #
  # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
  class BranchesController < AuthorizedController
    # El orden importa: primero el permiso (401/403) y después la compañía. Un
    # usuario sin permiso no tiene por qué enterarse de cómo está configurada.
    before_action :authorize_action
    before_action :require_company!

    MAX_PER_PAGE     = Sap::Branches::MAX_PAGE_SIZE
    DEFAULT_PER_PAGE = 10

    # `S_Sucursal` es el permiso de acceso heredado del .NET —el mismo que gatea
    # el nodo del menú (`app/javascript/data/menu.js`)—; crear y modificar ya
    # están renombrados a la convención `{Módulo}_{Recurso}_{Acción}` (§28).
    PERMISSIONS = {
      'index'  => 'S_Sucursal',
      'show'   => 'S_Sucursal',
      'create' => 'Configurations_Branches_Create',
      'update' => 'Configurations_Branches_Update'
    }.freeze

    # GET /api/branches?alias=&provincia=&canton=&distrito=&active=&page=1&per_page=10
    #
    # Devuelve activas e inactivas: `active` es un filtro más y en blanco no
    # filtra nada. Una sucursal dada de baja tiene que poder verse para poder
    # reactivarse.
    #
    # Sin `Total` y con `HasMore` en su lugar: ver `Sap::Branches`.
    def index
      result = branches.list(page: page, per_page: per_page, filters: filters)

      render json: ApiResponse.success(
        { Items: result.items.map { |branch| serialize(branch) }, HasMore: result.has_more }
      ).to_h
    end

    # GET /api/branches/:id
    #
    # `:id` es el `Code` de la UDT, la llave que SAP autoincrementa — no el
    # número de sucursal. Lo consume el panel de edición para releer la fila del
    # servidor en vez de confiar en la que trajo la tabla.
    def show
      render json: ApiResponse.success(serialize(branches.find(params[:id]))).to_h
    rescue Clavisco::ServiceLayer::Client::NotFoundError
      render json: ApiResponse.not_found('La sucursal no existe.').to_h, status: :not_found
    end

    # POST /api/branches
    def create
      code = branches(write: true).create(branch_params)

      render json: ApiResponse.success({ Code: code }, code: 201,
                                       message: 'Sucursal registrada con éxito.').to_h,
             status: :created
    end

    # PATCH /api/branches/:id
    #
    # El `Code` viaja en el path, no en el cuerpo como el `Id` del .NET: un
    # `Code` que llegue en el JSON se ignora, porque `branch_params` no lo mira.
    def update
      branches(write: true).update(code: params[:id], attributes: branch_params)

      render json: ApiResponse.success({ Code: params[:id].to_i },
                                       message: 'Sucursal actualizada con éxito.').to_h
    rescue Clavisco::ServiceLayer::Client::NotFoundError
      render json: ApiResponse.not_found('La sucursal no existe.').to_h, status: :not_found
    end

    # Los desenlaces que no son "salió bien", compartidos por las cuatro
    # acciones. Viven acá y no repetidos en cada una para que una acción nueva no
    # pueda nacer sin ellos:
    #
    #   - datos del formulario o número repetido → 422, es del llamador;
    #   - falta configuración (conexión, base, credenciales) → 422, tampoco se
    #     llegó a hablar con SAP;
    #   - `UnknownResource` → 422: la consulta no está en el catálogo, así que no
    #     hay nada que pedirle a SAP;
    #   - el Service Layer respondió mal → 502, el problema es el enlace.
    #
    # ⚠️ `NotFoundError` es subclase de `ServiceLayerError` y lo rescatan `show`
    # y `update` en su propio `rescue` —que corre primero— para devolver 404: un
    # `Code` que no existe es un recurso ausente, no una falla del enlace.
    rescue_from Sap::Branches::InvalidBranch, Sap::Branches::DuplicateNumber,
                Sap::CompanyClient::MissingConfiguration, Sap::UserClient::MissingConfiguration,
                Sap::ResourceQuery::UnknownResource do |error|
      render json: ApiResponse.error(error.message).to_h, status: :unprocessable_content
    end

    rescue_from Clavisco::ServiceLayer::Client::ServiceLayerError do |error|
      render json: ApiResponse.error(error.sap_message || error.message).to_h, status: :bad_gateway
    end

    private

    def authorize_action
      require_permission!(PERMISSIONS.fetch(action_name))
    end

    def require_company!
      return if company

      render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
             status: :forbidden
    end

    # La compañía activa, validada contra las asignadas al usuario (§28 regla 5):
    # el id sale de la sesión, nunca de un parámetro.
    def company
      @company ||= Company.assigned_to(Current.user.id).find_by(id: Current.company_id)
    end

    # @param write [Boolean] las escrituras se atribuyen a la persona; las
    #   lecturas usan la licencia de la conexión (ver la cabecera de la clase).
    def branches(write: false)
      client = if write
                 Sap::UserClient.for(company, user: Current.user)
               else
                 Sap::CompanyClient.for(company)
               end

      Sap::Branches.new(client: client)
    end

    # `EmsrTlfCodigoPais`/`EmsrFaxCodigoPais` no se aceptan del cuerpo: son 506
    # fijo —el formulario ni siquiera los muestra, y el país está deshabilitado
    # en "Costa Rica"—, así que dejar que el cliente los mande sería aceptar un
    # dato que la pantalla no puede producir. El día que haya sucursales fuera
    # del país, el campo entra al formulario y recién ahí al cuerpo.
    COUNTRY_CODE = 506

    def branch_params
      {
        number:               params[:SucursalNum],
        provincia:            text(:EmsrUbProvincia),
        canton:               text(:EmsrUbCanton),
        distrito:             text(:EmsrUbDistrito),
        barrio:               text(:EmsrUbBarrio),
        otras_senas:          text(:EmsrUbOtrasSenas),
        telefono_codigo_pais: COUNTRY_CODE,
        telefono:             text(:EmsrTlfNumTelefono),
        fax_codigo_pais:      COUNTRY_CODE,
        fax:                  text(:EmsrFaxNumTelefono),
        correo:               text(:EmsrCorreoElectronico),
        active:               boolean(:Active),
        alias_name:           text(:Alias)
      }
    end

    def filters
      {
        alias:     params[:alias].presence,
        provincia: params[:provincia].presence,
        canton:    params[:canton].presence,
        distrito:  params[:distrito].presence,
        active:    active_filter
      }
    end

    # Terciario, no booleano: en blanco significa "todas" —activas e inactivas—
    # y no "las inactivas". Por eso `nil` y no `false` cuando el parámetro no
    # viene; `Sap::Branches` lo distingue comparando contra `nil`.
    #
    # @return [Boolean, nil]
    def active_filter
      return nil if params[:active].blank?

      ActiveModel::Type::Boolean.new.cast(params[:active])
    end

    def text(key)    = params[key].to_s.strip.presence
    def boolean(key) = ActiveModel::Type::Boolean.new.cast(params[key])

    def page = [params[:page].to_i, 1].max

    def per_page
      (params[:per_page].presence || DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
    end

    # `Code` es la llave de la UDT y `SucursalNum` el número ante Hacienda: son
    # dos cosas distintas y las dos viajan. La pantalla identifica la fila por
    # `Code` y muestra `SucursalNum`.
    def serialize(branch)
      {
        Code:                  branch.code,
        SucursalNum:           branch.number,
        EmsrUbProvincia:       branch.provincia,
        EmsrUbCanton:          branch.canton,
        EmsrUbDistrito:        branch.distrito,
        EmsrUbBarrio:          branch.barrio,
        EmsrUbOtrasSenas:      branch.otras_senas,
        EmsrTlfCodigoPais:     branch.telefono_codigo_pais,
        EmsrTlfNumTelefono:    branch.telefono,
        EmsrFaxCodigoPais:     branch.fax_codigo_pais,
        EmsrFaxNumTelefono:    branch.fax,
        EmsrCorreoElectronico: branch.correo,
        Active:                branch.active,
        Alias:                 branch.alias_name
      }
    end
  end
end

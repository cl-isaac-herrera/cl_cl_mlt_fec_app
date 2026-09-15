# frozen_string_literal: true

module Api
  module Companies
    # Sección "Códigos de actividad" del formulario de compañías.
    #
    # Reemplaza `PUT /api/Companies/:companyId/activity-codes` del .NET, que
    # reemplazaba la lista ENTERA en cada guardado (`spSaveCompanyActivityCodes`).
    # Acá cada código es su propio recurso —igual que `Sap::Branches`— y se
    # crea o actualiza uno a la vez.
    #
    # ── No hay un estado "Activo" en la pantalla ─────────────────────────────────
    # A diferencia de `Sap::Branches`, acá "activo" no es un campo que el usuario
    # vea ni edite: un código que aparece en la lista está activo. El botón
    # "eliminar" lo inactiva (`deactivate`, nunca `destroy` — un comprobante
    # viejo pudo referenciarlo) y desaparece de la lista; si más tarde se vuelve
    # a dar de alta el MISMO código, `create` encuentra la fila inactiva y la
    # reactiva en vez de crear una duplicada. Ver `Sap::ActivityCodes`.
    #
    # ── La fuente es SAP, no la base de la aplicación ───────────────────────────
    # El .NET los guardaba en su propia tabla, filtrados por `CompanyId`. Acá
    # viven en la UDT `@CL_FEC_ACTIVITYCODE` de la compañía, así que no hay
    # `CompanyId` que mandar ni que filtrar: la fila que devuelve una compañía
    # es, por construcción, de esa compañía.
    #
    # ── Por qué anidado bajo `companies/:company_id` y NO como `Sap::Branches` ──
    # `Sap::Branches` opera sobre la compañía ACTIVA de la sesión porque tiene su
    # propia pantalla (`/configurations/branches`). Esta sección vive DENTRO del
    # formulario de edición de una compañía (`/configurations/companies/:id/edit`),
    # que puede no ser la compañía activa del selector — así que la compañía sale
    # del path, resuelta con el mismo alcance que la lectura del formulario
    # (`VisibleCompanies`, igual que `GeneralController`/`TaxAuthorityController`).
    #
    # ── Qué cliente usa cada acción ─────────────────────────────────────────────
    # Las lecturas van con `Sap::CompanyClient` (credenciales de LICENCIA de la
    # conexión); las escrituras con `Sap::UserClient` (credenciales de
    # `Current.user`), para que SAP le atribuya el cambio a quien lo hizo. Mismo
    # criterio que `Api::BranchesController`.
    #
    # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
    class ActivityCodesController < AuthorizedController
      include VisibleCompanies

      MAX_PER_PAGE     = Sap::ActivityCodes::MAX_PAGE_SIZE
      DEFAULT_PER_PAGE = 10

      # El permiso se resuelve ANTES de buscar la compañía: si se hiciera al
      # revés, un 404 le confirmaría a quien no tiene permiso qué ids existen.
      # Es el mismo permiso que gatea el resto de las secciones del formulario
      # (`GeneralController`, `TaxAuthorityController`, …): esta no tiene botón
      # ni pantalla propia, es una sección más del mismo form.
      before_action :authorize_action
      before_action :load_company

      # GET /api/companies/:company_id/activity_codes?activity_code=&description=&page=1&per_page=10
      #
      # Solo devuelve los ACTIVOS: no existe una vista de los inactivos (ver la
      # nota de cabecera) — un código que se eliminó no se "reactiva desde la
      # pantalla", se reactiva volviendo a darlo de alta con el mismo valor.
      #
      # Sin `Total` y con `HasMore` en su lugar: ver `Sap::ActivityCodes`.
      def index
        result = activity_codes.list(page: page, per_page: per_page, filters: filters)

        render json: ApiResponse.success(
          { Items: result.items.map { |item| serialize(item) }, HasMore: result.has_more }
        ).to_h
      end

      # GET /api/companies/:company_id/activity_codes/:id
      #
      # `:id` es el `Code` de la UDT, la llave que SAP autoincrementa — no el
      # código de actividad. Lo consume el panel de edición para releer la fila
      # del servidor en vez de confiar en la que trajo la tabla.
      def show
        render json: ApiResponse.success(serialize(activity_codes.find(params[:id]))).to_h
      rescue Clavisco::ServiceLayer::Client::NotFoundError
        render json: ApiResponse.not_found('El código de actividad no existe.').to_h, status: :not_found
      end

      # POST /api/companies/:company_id/activity_codes
      #
      # Si el código de actividad ya existe pero INACTIVO, esto lo reactiva en
      # vez de crear una fila nueva — transparente para quien llama: el
      # resultado es el mismo `Code` de siempre, con la descripción que se
      # acaba de mandar.
      def create
        code = activity_codes(write: true).create(activity_code_params)

        render json: ApiResponse.success({ Code: code }, code: 201,
                                         message: 'Código de actividad registrado con éxito.').to_h,
               status: :created
      end

      # PATCH /api/companies/:company_id/activity_codes/:id
      #
      # Edita el código/descripción de una fila activa. El `Code` viaja en el
      # path, no en el cuerpo: uno que llegue en el JSON se ignora, porque
      # `activity_code_params` no lo mira.
      def update
        activity_codes(write: true).update(code: params[:id], attributes: activity_code_params)

        render json: ApiResponse.success({ Code: params[:id].to_i },
                                         message: 'Código de actividad actualizado con éxito.').to_h
      rescue Clavisco::ServiceLayer::Client::NotFoundError
        render json: ApiResponse.not_found('El código de actividad no existe.').to_h, status: :not_found
      end

      # PATCH /api/companies/:company_id/activity_codes/:id/deactivate
      #
      # El "eliminar" de la pantalla: nunca `destroy`, un comprobante viejo pudo
      # referenciar el código. La fila desaparece del `index` y vuelve a estar
      # disponible el día que alguien la vuelva a dar de alta (`create`).
      def deactivate
        activity_codes(write: true).deactivate(code: params[:id])

        render json: ApiResponse.success({ Code: params[:id].to_i },
                                         message: 'Código de actividad desactivado con éxito.').to_h
      rescue Clavisco::ServiceLayer::Client::NotFoundError
        render json: ApiResponse.not_found('El código de actividad no existe.').to_h, status: :not_found
      end

      # Los desenlaces que no son "salió bien", compartidos por las cinco
      # acciones. Mismo criterio que `Api::BranchesController`:
      #
      #   - datos del formulario o código repetido → 422, es del llamador;
      #   - falta configuración (conexión, base, credenciales) → 422, tampoco se
      #     llegó a hablar con SAP;
      #   - `UnknownResource` → 422: la consulta no está en el catálogo;
      #   - el Service Layer respondió mal → 502, el problema es el enlace.
      #
      # ⚠️ `NotFoundError` es subclase de `ServiceLayerError` y lo rescatan
      # `show`, `update` y `deactivate` en su propio `rescue` —que corre
      # primero— para devolver 404: un `Code` que no existe es un recurso
      # ausente, no una falla del enlace.
      rescue_from Sap::ActivityCodes::InvalidActivityCode, Sap::ActivityCodes::DuplicateActivityCode,
                  Sap::CompanyClient::MissingConfiguration, Sap::UserClient::MissingConfiguration,
                  Sap::ResourceQuery::UnknownResource do |error|
        render json: ApiResponse.error(error.message).to_h, status: :unprocessable_content
      end

      rescue_from Clavisco::ServiceLayer::Client::ServiceLayerError do |error|
        render json: ApiResponse.error(error.sap_message || error.message).to_h, status: :bad_gateway
      end

      private

      def authorize_action
        require_permission!('Configurations_Companies_Update')
      end

      # El alcance lo comparte con la lectura del formulario
      # (`GET /api/companies/:id`): si no resolvieran el mismo conjunto, el
      # formulario mostraría una sección de una compañía que este endpoint
      # después rechaza (`CLAUDE.md` §28).
      def load_company
        @company = find_visible_company(params[:company_id])
      end

      # @param write [Boolean] las escrituras se atribuyen a la persona; las
      #   lecturas usan la licencia de la conexión (ver la cabecera de la clase).
      def activity_codes(write: false)
        client = if write
                   Sap::UserClient.for(@company, user: Current.user)
                 else
                   Sap::CompanyClient.for(@company)
                 end

        Sap::ActivityCodes.new(client: client, actor: Current.user&.email)
      end

      # Sin `Active`: no es un dato que el cliente pueda mandar, es un efecto de
      # `create`/`update` (siempre activo) o de `deactivate` (siempre inactivo).
      def activity_code_params
        {
          activity_code: text(:ActivityCode),
          description:   text(:Description)
        }
      end

      def filters
        {
          activity_code: params[:activity_code].presence,
          description:   params[:description].presence
        }
      end

      def text(key) = params[key].to_s.strip.presence

      def page = [params[:page].to_i, 1].max

      def per_page
        (params[:per_page].presence || DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
      end

      # `Code` es la llave de la UDT y `ActivityCode` el código de actividad ante
      # Hacienda: son dos cosas distintas y las dos viajan. La pantalla
      # identifica la fila por `Code` y muestra `ActivityCode`. Sin `Active`: el
      # `index` solo devuelve activos, así que el campo no le dice nada nuevo a
      # la pantalla.
      def serialize(item)
        {
          Code:         item.code,
          ActivityCode: item.activity_code,
          Description:  item.description,
          CreatedAt:    item.created_at,
          CreatedBy:    item.created_by,
          UpdatedAt:    item.updated_at,
          UpdatedBy:    item.updated_by
        }
      end
    end
  end
end

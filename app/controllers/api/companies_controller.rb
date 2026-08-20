# frozen_string_literal: true

module Api
  # Compañías de la instalación (pantalla /configurations/companies).
  #
  # Reemplaza `GET /api/Companies/GetCompanies?LegalName=&ComercialName=&
  # Identification=&StartPos=&StepPos=` del API .NET por un recurso REST: el verbo
  # va en el método HTTP y la paginación en la query string (`CLAUDE.md` §28).
  #
  # Los filtros por nombre legal, nombre comercial e identificación no se migran:
  # el listado filtra solo por `name`, que además ES el nombre comercial. El legal
  # y la identificación sí son columnas aparte (`issuer_legal_name`,
  # `issuer_id_number`): filtrar por ellas es sumarlas al scope `search`, no falta
  # el dato.
  #
  # `GET /api/companies` NO son las compañías del usuario de la sesión — esas son
  # `GET /api/profile/companies`.
  #
  # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
  class CompaniesController < AuthorizedController
    include AssignableCompanies

    # El permiso se resuelve ANTES de buscar el registro: si se hiciera al revés,
    # un 404 le confirmaría a quien no tiene permiso qué ids existen.
    before_action :authorize_action
    before_action :load_company, only: %i[show]

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index' => 'Configurations_Companies_ListAccess',
      # `show` alimenta el formulario de edición, así que pide el permiso de
      # edición — el mismo con el que `auth_guard_controller.js` gatea la ruta
      # /configurations/companies/:id/edit.
      'show'  => 'Configurations_Companies_Update'
    }.freeze

    # Permite ver todas las compañías de la instalación, no solo las asignadas al
    # usuario. No es un permiso de acción sino de alcance: se consulta con
    # `permission?`, que no corta la respuesta (`CLAUDE.md` §28).
    SEE_ALL_PERMISSION = 'Configurations_Companies_ViewAllApplicationCompanies'

    # GET /api/companies?name=&page=1&per_page=10
    #
    # Paginación por query string y total en el cuerpo, igual que el resto de los
    # listados migrados (`CLAUDE.md` §17 y §28). El .NET la pedía por los headers
    # `cl-dba-pagination-*` y devolvía el total pegado a cada fila
    # (`MaxQtyRowsFetch`).
    def index
      scope = visible_companies.search(name: params[:name]).order(:name)
      total = scope.count
      items = scope.limit(per_page).offset((page - 1) * per_page)

      render json: ApiResponse.success(
        { Items: items.map { |c| serialize(c) }, Total: total }
      ).to_h
    end

    # GET /api/companies/:id
    #
    # Los datos generales de una compañía, para el formulario de edición. Todo sale
    # de la tabla `companies`: el bloque del emisor ante Hacienda estuvo un tiempo
    # como UDFs de `OADM` y volvió a la base de la aplicación, así que la
    # respuesta ya no necesita hablar con SAP para armarse.
    #
    # Reemplaza `GET /api/companies/:id` del .NET, que devolvía las 42 columnas de
    # las dos tablas del legado.
    def show
      render json: ApiResponse.success(serialize_detail(@company)).to_h
    end

    # GET /api/companies/assignable
    #
    # Las compañías que el usuario de la sesión puede ASIGNARLE a otro: las suyas,
    # o todas si tiene `Configurations_Companies_ViewGroupCompanies` (ver el
    # concern `AssignableCompanies`). Alimenta el sub-tab "Compañías" del panel
    # "Gestionar accesos".
    #
    # Reemplaza `GET /api/Companies/for-assignment?groupId=N`. El `groupId` no se
    # migra ni con valor por defecto: no hay grupos (`CLAUDE.md` §31).
    def assignable
      require_permission!('Configurations_Users_CompanyAssignment')
      return if performed?

      companies = assignable_companies.order(:name)

      render json: ApiResponse.success(
        companies.map { |c| { Id: c.id, Name: c.name } }
      ).to_h
    end

    private

    def authorize_action
      permission = PERMISSIONS[action_name]
      # `assignable` no está en el mapa a propósito: exige el suyo, que es el de
      # la pantalla de usuarios y no el de esta.
      return if permission.nil?

      require_permission!(permission)
    end

    # `unscoped` a propósito: el default_scope de SoftDeletable esconde a las
    # inactivas, y esta pantalla existe justamente para poder verlas y
    # reactivarlas (`CLAUDE.md` §28).
    def visible_companies
      return Company.unscoped if permission?(SEE_ALL_PERMISSION)

      Company.unscoped.assigned_to(Current.user.id)
    end

    def load_company
      @company = visible_companies.find_by(id: params[:id])
      return if @company

      render json: ApiResponse.not_found('La compañía no existe.').to_h, status: :not_found
    end

    def page
      [params[:page].to_i, 1].max
    end

    def per_page
      requested = params[:per_page].to_i
      return DEFAULT_PER_PAGE if requested <= 0

      [requested, MAX_PER_PAGE].min
    end

    # Solo lo que pinta el listado. Nombre legal, nombre comercial e
    # identificación no salen de acá: el listado no los muestra (los devuelve
    # `show`, para el formulario).
    def serialize(company)
      {
        Id:     company.id,
        Name:   company.name,
        Active: company.is_active
      }
    end

    # El detalle para el formulario: lo del listado más las columnas que la
    # pantalla de edición necesita. Por ahora solo las de datos generales — el
    # resto (certificado, ATV, adjuntos, factura a proveedor) se agrega cuando se
    # migre cada sección.
    #
    # `SapDb` reemplaza al `DBSap` del .NET, que además mandaba un `DBMaestraSap`
    # vacío que ninguna columna respalda.
    #
    # Las claves del bloque del emisor conservan el vocabulario del XML de
    # Hacienda (`EmsrNombre`, `CodigoActividad`) aunque las columnas se llamen en
    # inglés: es el contrato que ya consume el formulario, y son los nombres con
    # los que se habla del tema.
    def serialize_detail(company)
      serialize(company).merge(
        ConnectionId:    company.connection_id,
        SapDb:           company.sap_db,
        FreightType:     company.freight_type,
        EmailSenderType: company.email_sender_type,

        EmsrNombre:             company.issuer_legal_name,
        # El nombre comercial ES `name`: no hay columna aparte, a propósito.
        EmsrNombreComercial:    company.name,
        EmsrIdeTipo:            company.issuer_id_type,
        EmsrIdeNumero:          company.issuer_id_number,
        CodigoActividad:        company.economic_activity_code,
        EmsrRegistroFiscal8707: company.tax_registry_8707,
        EmailCC:                company.email_cc,
        PurchInvSeriesNum:      company.purchase_invoice_series,
        DefaultXmlTaxCode:      company.default_xml_tax_code,
        DefaultWarehouse:       company.default_warehouse
      )
    end
  end
end

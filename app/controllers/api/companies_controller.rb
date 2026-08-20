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
    # El alcance lo comparte con los PATCH de cada sección: si no resolvieran el
    # mismo conjunto, el formulario abriría una compañía que el guardado rechaza.
    include VisibleCompanies

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
    # Los datos de una compañía, para el formulario de edición. La lectura es UNA
    # sola aunque el guardado esté partido en un endpoint por sección. Todo sale
    # de la tabla `companies`: el bloque del emisor ante Hacienda estuvo un tiempo
    # como UDFs de `OADM` y volvió a la base de la aplicación, así que la
    # respuesta ya no necesita hablar con SAP para armarse.
    #
    # Los dos secretos de la sección de Hacienda (el PIN del certificado y la
    # contraseña del token) NO viajan: se devuelve solo si hay uno guardado.
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

    def load_company
      @company = find_visible_company(params[:id])
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

    # El detalle para el formulario: la lectura es una sola, aunque el guardado
    # esté partido en un endpoint por sección.
    #
    # `SapDb` reemplaza al `DBSap` del .NET, que además mandaba un `DBMaestraSap`
    # vacío que ninguna columna respalda.
    #
    # Las claves del bloque del emisor conservan el vocabulario del XML de
    # Hacienda (`EmsrNombre`, `CodigoActividad`) aunque las columnas se llamen en
    # inglés: es el contrato que ya consume el formulario.
    #
    # ⚠️ Los campos de cada sección tienen que coincidir con los que acepta el
    # controller de ESA sección (`Api::Companies::GeneralController`,
    # `Api::Companies::TaxAuthorityController`,
    # `Api::Companies::AttachmentsController`). Si uno se agrega acá y no allá,
    # el formulario lo muestra, el usuario lo edita, guarda, y no pasa nada — sin
    # error. `company_general_spec.rb`, `company_tax_authority_spec.rb` y
    # `company_attachments_spec.rb` comparan las dos listas de su sección.
    def serialize_detail(company)
      serialize(company).merge(
        # ── Sección "Datos Generales" ────────────────────────────────────────
        ConnectionId:           company.connection_id,
        SapDb:                  company.sap_db,
        EmailSenderType:        company.email_sender_type,
        FreightType:            company.freight_type,
        EmsrNombre:             company.issuer_legal_name,
        EmsrIdeTipo:            company.issuer_id_type,
        EmsrIdeNumero:          company.issuer_id_number,
        CodigoActividad:        company.economic_activity_code,
        EmsrRegistroFiscal8707: company.tax_registry_8707,

        # El nombre comercial ES `name`: no hay columna aparte, a propósito.
        EmsrNombreComercial: company.name,

        # ── Sección "Datos de Conexión de Hacienda (ATV)" ────────────────────
        # El PIN del certificado y la contraseña del token NO salen de acá: están
        # cifrados y no se le devuelven a nadie. `HasCertPin` / `HasTokenPass` es
        # lo único que el formulario necesita de ellos — con eso distingue "no hay
        # PIN configurado" de "hay uno y no se muestra".
        #
        # Del certificado sale el NOMBRE del archivo, no la ruta: la ruta absoluta
        # en el servidor es infraestructura y el cliente ya no puede escribirla
        # (la deriva `Certificates::Store` a partir de la cédula).
        CertFileName:   Certificates::Store.file_name(company.cert_path),
        CertExpireDate: company.cert_expires_at,
        TokenUsr:       company.token_user,
        HasCertPin:     company.cert_pin_stored?,
        HasTokenPass:   company.token_password_stored?,

        # ── Sección "Adjuntos de la compañía" ────────────────────────────────
        # De los dos adjuntos sale el NOMBRE del archivo y no la ruta, por lo
        # mismo que el certificado: la columna guarda la ruta absoluta que otro
        # proceso abre —el servicio de correo el logo, el generador del PDF el
        # `.rpt`—, es infraestructura, y el cliente ya no puede escribirla.
        LogoFileName:        CompanyFiles::Store.file_name(company.logo_path),
        PrintFormatFileName: CompanyFiles::Store.file_name(company.print_format_path),

        # ── Secciones que todavía no tienen su endpoint ──────────────────────
        # Se devuelven porque la lectura del formulario es una sola; se van a
        # poder editar cuando cada sección se migre (`TODOS.md` → Compañías).
        EmailCC:           company.email_cc,
        PurchInvSeriesNum: company.purchase_invoice_series,
        DefaultXmlTaxCode: company.default_xml_tax_code,
        DefaultWarehouse:  company.default_warehouse
      )
    end
  end
end

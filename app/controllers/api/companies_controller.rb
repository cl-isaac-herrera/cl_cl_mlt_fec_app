# frozen_string_literal: true

module Api
  # Compañías de la instalación (pantalla /configurations/companies).
  #
  # Reemplaza `GET /api/Companies/GetCompanies?LegalName=&ComercialName=&
  # Identification=&StartPos=&StepPos=` del API .NET por un recurso REST: el verbo
  # va en el método HTTP y la paginación en la query string (`CLAUDE.md` §28).
  #
  # El filtro por nombre legal no se migra: el listado filtra por `name` (el
  # comercial) y por `issuer_id_number` (la cédula, columna "Cédula" del
  # listado). El legal sí es una columna aparte (`issuer_legal_name`): filtrar
  # por ella es sumarla al scope `search`, no falta el dato.
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
      'index'  => 'Configurations_Companies_ListAccess',
      # `show` alimenta el formulario de edición, así que pide el permiso de
      # edición — el mismo con el que `auth_guard_controller.js` gatea la ruta
      # /configurations/companies/:id/edit.
      'show'   => 'Configurations_Companies_Update',
      'create' => 'Configurations_Companies_Create'
    }.freeze

    # Los dos adjuntos que acepta el alta, igual que en
    # `Api::Companies::AttachmentsController`.
    ATTACHMENTS = [
      { param: :Logo,        column: :logo_path,         store: ::Attachments::LogoStore },
      { param: :PrintFormat, column: :print_format_path, store: ::Attachments::PrintFormatStore }
    ].freeze

    # GET /api/companies?name=&issuer_id_number=&page=1&per_page=10
    #
    # Paginación por query string y total en el cuerpo, igual que el resto de los
    # listados migrados (`CLAUDE.md` §17 y §28). El .NET la pedía por los headers
    # `cl-dba-pagination-*` y devolvía el total pegado a cada fila
    # (`MaxQtyRowsFetch`).
    def index
      scope = visible_companies.search(name: params[:name], issuer_id_number: params[:issuer_id_number])
                                .order(:name)
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

    # POST /api/companies
    #
    # A diferencia de las secciones de edición (un botón "Actualizar" — y un
    # `PATCH` — por sección), el alta tiene un único botón, así que es una sola
    # petición con TODO lo que el formulario deja llenar en creación: "Datos
    # Generales", "Adicional" (`EmailCC`), "Hacienda (ATV)" (credenciales y
    # certificado) y "Adjuntos" (logo y formato de impresión). El cuerpo es
    # multipart por el certificado y los adjuntos.
    #
    # Quedan fuera "Factura a Proveedor" (el formulario la mantiene deshabilitada
    # hasta que la compañía exista — necesita SAP) y "Códigos de actividad" (UDT
    # que cuelga de un `company_id` que todavía no hay); las dos siguen ocultas
    # en el formulario de alta.
    #
    # Reemplaza `POST /api/Companies` del .NET (`TODOS.md` → Compañías → "Crear
    # compañía"), que mandaba lo mismo en una sola petición multipart.
    #
    # Quien crea la compañía queda asignado a ella (`UsersByCompany`). Sin eso,
    # alguien sin `Configurations_Companies_ViewAllApplicationCompanies` la
    # crearía y la perdería de vista en el mismo instante — ni en `index` ni
    # pudiendo reabrirla para completar el resto de las secciones (`show` y
    # `general` comparten el alcance de `VisibleCompanies`). Mismo criterio que
    # `Api::UsersController#create` con `CompanyId`.
    def create
      company = Company.new(create_params)
      # Antes de tocar el disco: un `Nombre` en blanco, sin conexión de SAP o sin
      # bandeja de correo no ameritan escribir el certificado o los adjuntos para
      # después borrarlos. `:new_company_form` es el único contexto que exige la
      # conexión y la bandeja — ver el comentario de esas dos validaciones en
      # `Company`.
      return render_invalid(company) unless company.valid?(:new_company_form)

      begin
        company.assign_attributes(certificate_attributes(company).merge(attachment_attributes(company)))
      rescue CompanyFiles::Error => e
        # El PIN que no abre el .p12, la cédula todavía sin llenar, la extensión
        # o el tamaño de un archivo: nada de esto tocó la base, pero alguno de
        # los archivos ya pudo haberse escrito en disco antes del que falló.
        discard_written
        return render_error(e.message)
      end

      unless company.save
        # La fila no se creó: ningún archivo recién escrito lo apunta.
        discard_written
        return render_invalid(company)
      end

      UsersByCompany.create!(user: Current.user, company: company)

      render json: ApiResponse.success(serialize_detail(company), code: 201,
                                       message: 'Compañía registrada con éxito.').to_h,
             status: :created
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

    # Los catorce campos de "Datos Generales" (los mismos y con la misma
    # traducción de claves que acepta `Api::Companies::GeneralController`), más
    # `EmailCC` de "Adicional" y las tres credenciales de texto de "Hacienda
    # (ATV)" — el único botón del alta manda las cuatro secciones juntas. Lo que
    # esa sección tiene de ARCHIVOS (certificado, logo, formato de impresión) lo
    # resuelven `certificate_attributes` y `attachment_attributes`, porque
    # necesitan la compañía ya construida (le leen `issuer_id_number` para saber
    # en qué carpeta escribir, `CLAUDE.md` §34).
    #
    # A diferencia de un `PATCH` de sección, acá no importa copiar solo lo que
    # vino en la petición: es un alta, así que lo que no venga simplemente nace
    # en su default de columna (o `NULL`).
    def create_params
      {
        name:                    text(:Name),
        sap_db:                  text(:SapDb),
        issuer_legal_name:       text(:EmsrNombre),
        issuer_id_type:          text(:EmsrIdeTipo),
        issuer_id_number:        text(:EmsrIdeNumero),
        economic_activity_code:  text(:CodigoActividad),
        tax_registry_8707:       text(:EmsrRegistroFiscal8707),
        connection_id:           number(:ConnectionId),
        email_config_id:         number(:EmailConfigId),
        reception_mailbox_id:    number(:ReceptionMailboxId),
        email_sender_type:       number(:EmailSenderType),
        freight_type:            number(:FreightType),
        is_active:               boolean(:Active),
        send_rejected_documents: boolean(:SendRejectedDocuments),
        email_cc:                text(:EmailCC),
        token_user:              text(:TokenUsr),
        cert_pin:                text(:CertPin),
        token_password:          text(:TokenPass)
      }.compact
    end

    # Lo que aporta el certificado, o un hash vacío si no vino ninguno. Mismo
    # criterio que `Api::Companies::TaxAuthorityController#certificate_attributes`:
    # primero se abre el `.p12` con su PIN y recién después se escribe en disco,
    # para que un PIN equivocado no deje un archivo tirado en el servidor.
    #
    # @raise [CompanyFiles::Error] PIN que no abre el archivo, cédula faltante,
    #   extensión inválida, archivo demasiado grande, disco que falla.
    def certificate_attributes(company)
      upload = params[:file]
      return {} if upload.blank?

      pin = params[:CertPin]
      raise Certificates::Error, 'Ingrese el PIN del certificado para poder guardarlo.' if pin.blank?

      result = Certificates::ExpirationReader.new(file: upload, pin: pin).call
      raise Certificates::Error, result.error unless result.ok?

      path = Certificates::Store.new(company).save!(upload)
      (@written ||= []) << [Certificates::Store, company, path]
      { cert_path: path, cert_expires_at: result.expires_at }
    end

    # Lo que aportan el logo y el formato de impresión — cada uno solo si vino
    # en el cuerpo. Mismo criterio que
    # `Api::Companies::AttachmentsController#saved_attributes`.
    def attachment_attributes(company)
      ATTACHMENTS.each_with_object({}) do |attachment, attrs|
        upload = params[attachment[:param]]
        next if upload.blank?

        path = attachment[:store].new(company).save!(upload)
        (@written ||= []) << [attachment[:store], company, path]
        attrs[attachment[:column]] = path
      end
    end

    # Borra los archivos que ya se escribieron en disco cuando el alta no
    # termina de salir bien (otro archivo falló, o el `save` de la compañía
    # rechaza los datos): ninguna fila los apunta, así que no se dejan tirados
    # en el servidor.
    def discard_written
      (@written || []).each { |store_class, company, path| store_class.new(company).remove(path) }
    end

    def text(key)    = params[key].to_s.strip.presence
    def number(key)  = params[key].to_s.strip.presence&.to_i
    def boolean(key) = ActiveModel::Type::Boolean.new.cast(params[key])

    def render_invalid(company)
      render_error(company.errors.full_messages.to_sentence)
    end

    def render_error(message)
      render json: ApiResponse.error(message).to_h, status: :unprocessable_content
    end

    # Solo lo que pinta el listado. Nombre legal y nombre comercial no salen de
    # acá: el listado no los muestra (los devuelve `show`, para el formulario).
    # La identificación (`EmsrIdeNumero`) sí se muestra, como columna "Cédula".
    def serialize(company)
      {
        Id:            company.id,
        Name:          company.name,
        Active:        company.is_active,
        EmsrIdeNumero: company.issuer_id_number
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
        EmailConfigId:          company.email_config_id,
        ReceptionMailboxId:     company.reception_mailbox_id,
        SapDb:                  company.sap_db,
        EmailSenderType:        company.email_sender_type,
        FreightType:            company.freight_type,
        EmsrNombre:             company.issuer_legal_name,
        EmsrIdeTipo:            company.issuer_id_type,
        EmsrIdeNumero:          company.issuer_id_number,
        CodigoActividad:        company.economic_activity_code,
        EmsrRegistroFiscal8707: company.tax_registry_8707,

        # ¿El correo de recepción electrónica sale también para lo que Hacienda
        # RECHAZA? Lo evalúa `Sap::MailDocumentInfo` al armar el `$filter`.
        SendRejectedDocuments:  company.send_rejected_documents,

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

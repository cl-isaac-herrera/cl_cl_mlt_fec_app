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
  # listado, y la única identidad del emisor que sigue viviendo en esta tabla —
  # ver `Sap::CompanyConfig`). El legal no es filtrable porque ya no es una
  # columna de `companies`: filtrar por SAP no es algo que `search` pueda hacer.
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
      # /configurations/companies/:id/edit. Acepta también la variante de
      # instalación (`Configurations_Companies_UpdateInAllCompanies`).
      'show'   => %w[Configurations_Companies_Update Configurations_Companies_UpdateInAllCompanies],
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
    # sola aunque el guardado esté partido en un endpoint por sección.
    #
    # ⚠️ El bloque del emisor ante Hacienda (razón social, tipo de
    # identificación, actividad económica, registro fiscal 8707) vive en la UDT
    # `@CL_FEC_ISSUERCONFIG` (`Sap::CompanyConfig`) y no en `companies` — volvió
    # a depender de SAP para armarse, revirtiendo la decisión que documenta
    # `CLAUDE.md` §32 (caso `company_config_udt`, antes `oadm_company_config`).
    # Si SAP no responde, `show` responde 422/502 (ver `rescue_from` más abajo)
    # en vez de un formulario a medias.
    #
    # Los dos secretos de la sección de Hacienda (el PIN del certificado y la
    # contraseña del token) NO viajan: se devuelve solo si hay uno guardado.
    #
    # Reemplaza `GET /api/companies/:id` del .NET, que devolvía las 42 columnas de
    # las dos tablas del legado.
    def show
      render json: ApiResponse.success(serialize_detail(@company, read_issuer_config(@company))).to_h
    end

    # GET /api/companies/assignable
    #
    # Las compañías que el usuario de la sesión puede ASIGNARLE a otro: las suyas,
    # o todas si tiene `Configurations_Companies_ViewAllApplicationCompanies`
    # (ver el concern `AssignableCompanies`). Alimenta el sub-tab "Compañías" del
    # panel "Gestionar accesos".
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
    # "Datos Generales" y "Hacienda (ATV)" completas —incluido el certificado y
    # el formato de impresión— son obligatorias para poder registrar la
    # compañía: el formulario nace sin las secciones "Factura a Proveedor" ni
    # "Códigos de actividad" (ver más abajo), así que no tiene sentido dejar una
    # compañía a medio configurar en Hacienda o sin cómo imprimir sus
    # comprobantes.
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
    #
    # ── Todo o nada, hasta la UDT ────────────────────────────────────────────
    # Después de que la fila y los archivos ya se escribieron, todavía falta
    # registrar la configuración del emisor en SAP (`Sap::CompanyConfig`). Si
    # eso falla —conexión, base o credenciales incorrectas—, se revierte TODO:
    # se destruye la fila recién creada y se descartan los archivos, y el
    # usuario corrige y reintenta el alta entera. Dejar la compañía a medias
    # (creada en Rails, sin fila en SAP) la mostraría en el listado con una
    # sección del emisor que `show` no puede armar.
    def create
      company = Company.new(create_params)
      # Antes de tocar el disco: un `Nombre` en blanco, sin conexión de SAP, sin
      # bandeja de correo o sin credenciales de Hacienda no ameritan escribir el
      # certificado o los adjuntos para después borrarlos. `:new_company_form` es
      # el único contexto que exige estas cinco — ver el comentario de esas
      # validaciones en `Company`.
      return render_invalid(company) unless company.valid?(:new_company_form)

      # El certificado y el formato de impresión son ARCHIVOS: no son un
      # atributo de `company` todavía en este punto (lo derivan
      # `certificate_attributes`/`attachment_attributes` más abajo, después de
      # escribirlos en disco), así que su presencia se exige acá, sobre el
      # cuerpo de la petición, y no como validación del modelo.
      return render_error('Adjunte el certificado digital para poder registrar la compañía.') if params[:file].blank?
      if params[:PrintFormat].blank?
        return render_error('Adjunte el formato de impresión para poder registrar la compañía.')
      end

      # Se arma temprano, antes de escribir ningún archivo: si a quien crea la
      # compañía le faltan credenciales de SAP, mejor fallar acá que después de
      # haber escrito el certificado y los adjuntos en disco. Atribuido a quien
      # crea la compañía (`Sap::UserClient`), no a la licencia — mismo criterio
      # que toda escritura de `Api::Companies::ActivityCodesController`.
      begin
        client = Sap::UserClient.for(company, user: Current.user)
      rescue Sap::UserClient::MissingConfiguration => e
        return render_error(e.message)
      end

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

      begin
        write_issuer_config!(company, client)
      rescue Sap::CompanyConfig::InvalidConfig => e
        discard_created(company)
        return render_error(e.message)
      rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
        discard_created(company)
        return render_service_layer_error(e)
      end

      # Rol de compañía Administrador para quien la crea: sin esto, el creador
      # queda con acceso a la compañía pero SIN ningún permiso dentro de ella
      # (docs/PLAN-ROLES-POR-ALCANCE.md, Fase 0 decisión 2).
      UsersByCompany.create!(user: Current.user, company: company, role: company_admin_role)

      render json: ApiResponse.success(serialize_detail(company, issuer_config_from_request), code: 201,
                                       message: 'Compañía registrada con éxito.').to_h,
             status: :created
    end

    private

    def authorize_action
      permission = PERMISSIONS[action_name]
      # `assignable` no está en el mapa a propósito: exige el suyo, que es el de
      # la pantalla de usuarios y no el de esta.
      return if permission.nil?

      require_any_permission!(*Array(permission))
    end

    def load_company
      @company = find_visible_company(params[:id])
    end

    # `db/seeds.rb` siempre lo siembra por upsert (nunca `delete_all`) — ver
    # CLAUDE.md §28. `find_by!` para que un catálogo sin sembrar todavía falle
    # con un error claro en vez de un `NoMethodError` sobre `nil`.
    def company_admin_role
      Role.find_by!(name: 'Administrador', scope: 'company')
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
    # necesitan la compañía ya construida y un `client` de SAP para saber en
    # qué carpeta escribir (`CLAUDE.md` §34, `Sap::CompanyConfig`).
    #
    # A diferencia de un `PATCH` de sección, acá no importa copiar solo lo que
    # vino en la petición: es un alta, así que lo que no venga simplemente nace
    # en su default de columna (o `NULL`).
    def create_params
      {
        name:                    text(:Name),
        sap_db:                  text(:SapDb),
        issuer_id_number:        text(:EmsrIdeNumero),
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

    # El bloque del emisor que va a la UDT `@CL_FEC_ISSUERCONFIG`. Sin
    # `.compact`: el alta manda el bloque completo (`Sap::CompanyConfig#create`
    # no hace PATCH parcial), así que un campo en blanco se escribe en blanco a
    # propósito. `Name` y `EmsrIdeNumero` van también a `create_params`: la UDT
    # es la fuente y `companies` el espejo local (ver `Sap::CompanyConfig`).
    def issuer_config_params
      {
        legal_name:              text(:EmsrNombre),
        commercial_name:         text(:Name),
        id_number:               text(:EmsrIdeNumero),
        id_type:                 text(:EmsrIdeTipo),
        economic_activity_code:  text(:CodigoActividad),
        tax_registry_8707:       text(:EmsrRegistroFiscal8707)
      }
    end

    # Escribe la fila única de la UDT, atribuida a quien está creando la
    # compañía (`Sap::UserClient`, no `Sap::CompanyClient`) — mismo criterio que
    # `Api::Companies::ActivityCodesController` para toda escritura: la
    # licencia es para procesos de fondo sin una persona detrás. El `client` lo
    # arma `create` una sola vez, temprano (antes de escribir ningún archivo).
    def write_issuer_config!(company, client)
      Sap::CompanyConfig.new(client: client, actor: Current.user&.email).create(issuer_config_params)
    end

    # El bloque del emisor tal como quedó, sin volver a preguntarle a SAP
    # inmediatamente después de haberlo escrito: `write_issuer_config!` ya
    # confirmó que se guardó, así que lo que se acaba de mandar ES el estado
    # actual.
    def issuer_config_from_request
      Sap::CompanyConfig::Config.new(**issuer_config_params, updated_at: nil, updated_by: nil)
    end

    # La configuración del emisor de una compañía YA EXISTENTE, para `show`.
    # A diferencia del alta, acá sí hay que preguntarle a SAP: es la única
    # fuente de este bloque, y puede haber cambiado desde afuera de esta app.
    #
    # `nil` cuando la fila todavía no existe en SAP (compañía sin backfill
    # todavía, o sin conexión asignada) — `serialize_detail` sabe leer un `nil`.
    def read_issuer_config(company)
      Sap::CompanyConfig.new(client: Sap::CompanyClient.for(company)).read
    end

    # Los desenlaces que no son "salió bien" al hablar con SAP, para `show`
    # (y cualquier acción futura que solo LEA la configuración del emisor).
    # `create` maneja los suyos aparte, en su propio `begin/rescue`, porque
    # además tiene que revertir la fila y los archivos ya escritos.
    #
    # Mismo criterio que `Api::Companies::ActivityCodesController`: falta de
    # configuración → 422 (no se llegó a hablar con SAP); el Service Layer
    # respondió mal → 502 (el problema es el enlace).
    rescue_from Sap::CompanyClient::MissingConfiguration do |error|
      render json: ApiResponse.error(error.message).to_h, status: :unprocessable_content
    end

    rescue_from Clavisco::ServiceLayer::Client::ServiceLayerError do |error|
      render json: ApiResponse.error(error.sap_message || error.message).to_h, status: :bad_gateway
    end

    # Deshace un alta que llegó a crear la fila y los archivos pero falló al
    # registrar la configuración del emisor en SAP (`create`, ver su cabecera).
    # `company.destroy` es un `DELETE` real —`SoftDeletable` no lo redefine,
    # solo agrega `soft_delete!`— así que la cédula queda libre para reintentar
    # el alta: dejarla "dada de baja" la seguiría bloqueando (la unicidad de
    # `issuer_id_number` no excluye a las inactivas, a propósito).
    def discard_created(company)
      discard_written
      company.destroy
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
    #
    # @param issuer_config [Sap::CompanyConfig::Config, nil] el bloque del
    #   emisor, ya leído de SAP (`show`) o recién escrito (`create`) — ver
    #   `read_issuer_config`/`issuer_config_from_request`. `nil` cuando la fila
    #   todavía no existe en SAP: los cuatro campos salen en blanco.
    def serialize_detail(company, issuer_config)
      serialize(company).merge(
        # ── Sección "Datos Generales" ────────────────────────────────────────
        ConnectionId:           company.connection_id,
        EmailConfigId:          company.email_config_id,
        ReceptionMailboxId:     company.reception_mailbox_id,
        SapDb:                  company.sap_db,
        EmailSenderType:        company.email_sender_type,
        FreightType:            company.freight_type,
        EmsrNombre:             issuer_config&.legal_name,
        EmsrIdeTipo:            issuer_config&.id_type,
        EmsrIdeNumero:          company.issuer_id_number,
        CodigoActividad:        issuer_config&.economic_activity_code,
        EmsrRegistroFiscal8707: issuer_config&.tax_registry_8707,

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

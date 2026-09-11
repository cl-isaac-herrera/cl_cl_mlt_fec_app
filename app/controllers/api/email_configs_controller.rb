# frozen_string_literal: true

module Api
  # Bandejas de correo de envío (pantalla /configurations/email-senders).
  #
  # Reemplaza el `EmailConfigController` del servidor de sincronización .NET,
  # cuyos paths llevaban el verbo adentro y el id en el cuerpo
  # (`POST /api/EmailConfig/SearchEmailConfig`, `PATCH /api/EmailConfig/UpdateEmailConfig`).
  # Acá el verbo va en el método HTTP y el id en el path (`CLAUDE.md` §28).
  #
  # Dos cambios de fondo respecto del .NET, además del nombrado:
  #
  #   - **La búsqueda es un GET.** El `SearchEmailConfig` era un POST con los
  #     filtros y la paginación en el cuerpo. Buscar no crea nada: los filtros van
  #     en la query string, y así la URL se puede compartir y cachear.
  #   - **La contraseña no vuelve nunca.** El .NET la devolvía en cada fila del
  #     listado (cifrada, pero devuelta al browser igual). Acá es de solo
  #     escritura, como los ajustes con `is_visible: false` (§36): lo único que
  #     sale es `HasPassword`.
  #
  # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
  class EmailConfigsController < AuthorizedController
    # El permiso se resuelve ANTES de buscar el registro: si se hiciera al revés,
    # un 404 le confirmaría a quien no tiene permiso qué ids existen.
    before_action :authorize_action
    before_action :load_email_config, only: [:update]

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index'  => 'Configurations_EmailInbox_Access',
      'create' => 'Configurations_EmailInbox_Create',
      'update' => 'Configurations_EmailInbox_Update'
    }.freeze

    # GET /api/email_configs?email=&ssl=&page=1&per_page=10
    #
    # Paginación por query string, no por los headers `cl-dba-pagination-*` del
    # .NET, y el total en el cuerpo (`Data.Total`) para que el contador de
    # Tabulator no tenga que inferirlo (`CLAUDE.md` §17).
    #
    # `unscoped`: es la pantalla que ADMINISTRA las bandejas, así que tiene que
    # ver las dadas de baja para poder reactivarlas (§28). El resto de la app
    # (el selector del formulario de compañías, el envío) usa el scope normal.
    def index
      scope = EmailConfig.unscoped.search(email: params[:email], ssl: ssl_filter).order(:email)
      total = scope.count
      items = scope.limit(per_page).offset((page - 1) * per_page).to_a
      counts = companies_counts(items.map(&:id))

      render json: ApiResponse.success(
        { Items: items.map { |c| serialize(c, companies_count: counts.fetch(c.id, 0)) }, Total: total }
      ).to_h
    end

    # GET /api/email_configs/assignable
    #
    # Catálogo mínimo (id + dirección) para el selector "Bandeja de correo" de la
    # sección "Datos Generales" del formulario de compañías. Solo las ACTIVAS: una
    # bandeja dada de baja no se le puede asignar a nadie.
    #
    # Exige los permisos de COMPAÑÍAS y no el de bandejas, a propósito: quien
    # administra compañías necesita el selector aunque no administre bandejas, y
    # al revés no le sirve de nada. Lo que se expone es solo la dirección, nunca
    # el host ni la contraseña.
    #
    # (`Configurations_EmailInbox_Access` va también en la lista para que la
    # pantalla de bandejas pueda usarlo si alguna vez lo necesita sin depender de
    # un permiso de otra pantalla.)
    def assignable
      configs = EmailConfig.order(:email).select(:id, :email, :sender_address)

      render json: ApiResponse.success(
        configs.map { |c| { Id: c.id, Email: c.email, SenderAddress: c.sender_address } }
      ).to_h
    end

    # POST /api/email_configs
    def create
      email_config = EmailConfig.new(email_config_params)
      return render_invalid(email_config) unless email_config.save

      render json: ApiResponse.success(serialize(email_config), code: 201,
                                       message: 'Bandeja registrada con éxito.').to_h,
             status: :created
    end

    # PATCH /api/email_configs/:id
    #
    # El id viaja en el path, no en el cuerpo como en el .NET: un `Id` que llegue
    # en el JSON se ignora, porque `email_config_params` no lo mira.
    def update
      return render_invalid(@email_config) unless @email_config.update(email_config_params)

      render json: ApiResponse.success(serialize(@email_config),
                                       message: 'Bandeja actualizada con éxito.').to_h
    end

    private

    def authorize_action
      permission = PERMISSIONS[action_name]
      # `assignable` no está en el mapa: exige los suyos, que son los de la
      # pantalla de compañías. Ver el comentario de la acción.
      if permission.nil?
        require_any_permission!('Configurations_Companies_Create',
                                'Configurations_Companies_Update',
                                'Configurations_EmailInbox_Access')
      else
        require_permission!(permission)
      end
    end

    # `unscoped`: se puede editar (y reactivar) una bandeja dada de baja — es la
    # única forma de volver a ponerla en servicio.
    def load_email_config
      @email_config = EmailConfig.unscoped.find_by(id: params[:id])
      return if @email_config

      render json: ApiResponse.not_found('La bandeja no existe.').to_h, status: :not_found
    end

    # Se copia únicamente lo que vino en la petición, para que un PATCH parcial
    # no borre lo que no mencionó — mismo criterio que `connection_params`.
    #
    # Los cuatro campos del legacy que no tienen columna
    # (`ActiveMailsService`, `ActiveReceptMailsService` y los dos `LastAttempt*`)
    # no se aceptan: eran del servicio de fondo del .NET, que llevaba una bandeja
    # por TIPO de servicio. Acá la bandeja es de la compañía y el estado de los
    # reintentos lo lleva la cola (`Documents::MailQueue`).
    def email_config_params
      attrs = {}
      attrs[:email]          = text(:Email)         if params.key?(:Email)
      attrs[:host]           = text(:Host)          if params.key?(:Host)
      attrs[:port]           = number(:Port)        if params.key?(:Port)
      attrs[:ssl]            = boolean(:Ssl)        if params.key?(:Ssl)
      attrs[:sender_address] = text(:SenderAddress) if params.key?(:SenderAddress)
      attrs[:is_active]      = boolean(:Active)     if params.key?(:Active)
      attrs.merge(password_param)
    end

    # Contraseña en blanco = "sin cambio", no "borrarla". El servidor nunca la
    # devuelve (ver `serialize`), así que el formulario de edición siempre carga
    # el campo vacío: tomarlo al pie de la letra dejaría a la bandeja sin poder
    # autenticar cada vez que alguien corrige el host.
    #
    # Al CREAR sí es obligatoria, y de eso se encarga la pantalla junto con la
    # prueba de credenciales: una bandeja sin contraseña no pasa la validación de
    # `POST /api/email_credential_validations`, y sin esa prueba el botón de
    # guardar no se habilita.
    #
    # @return [Hash] vacío cuando no hay nada que cambiar.
    def password_param
      return {} if params[:Password].blank?

      { password: params[:Password] }
    end

    def text(key)    = params[key].to_s.strip.presence
    def number(key)  = params[key].to_s.strip.presence&.to_i
    def boolean(key) = ActiveModel::Type::Boolean.new.cast(params[key])

    # El filtro de SSL del .NET era un `2 = Todos / 1 = Activo / 0 = Inactivo`.
    # Acá "todos" es simplemente no mandar el parámetro: un filtro ausente no
    # filtra, y no hace falta un valor centinela para decirlo.
    #
    # @return [Boolean, nil] `nil` = sin filtrar.
    def ssl_filter
      return nil if params[:ssl].blank?

      ActiveModel::Type::Boolean.new.cast(params[:ssl])
    end

    def render_invalid(email_config)
      render json: ApiResponse.error(email_config.errors.full_messages.to_sentence).to_h,
             status: :unprocessable_content
    end

    def page
      [params[:page].to_i, 1].max
    end

    def per_page
      requested = params[:per_page].to_i
      return DEFAULT_PER_PAGE if requested <= 0

      [requested, MAX_PER_PAGE].min
    end

    # ⚠️ `password` NO sale nunca, ni cifrada ni en claro: es un campo de solo
    # escritura, igual que `connections.sap_license_password` y que los ajustes
    # con `is_visible: false` (`CLAUDE.md` §36). Lo que la pantalla necesita saber
    # es si ya hay una guardada —para decir "déjelo en blanco para conservarla"—
    # y eso lo responde un booleano.
    #
    # `CompaniesCount` es lo que hace visible por qué una bandeja no se puede dar
    # de baja: sin ese dato el error del guardado aparecería sin aviso previo.
    def serialize(email_config, companies_count: nil)
      {
        Id:             email_config.id,
        Email:          email_config.email,
        Host:           email_config.host,
        Port:           email_config.port,
        Ssl:            email_config.ssl,
        SenderAddress:  email_config.sender_address,
        Active:         email_config.is_active,
        HasPassword:    email_config.password_stored?,
        CompaniesCount: companies_count || email_config.companies.count
      }
    end

    # Cuántas compañías activas usa cada bandeja, en UNA consulta. Hacerlo con
    # `email_config.companies.count` dentro del `map` serían diez consultas por
    # página, para un dato que la tabla muestra en todas las filas.
    #
    # @return [Hash{Integer => Integer}] id de bandeja → cantidad. Las que no
    #   tienen ninguna no aparecen.
    def companies_counts(ids)
      return {} if ids.empty?

      Company.where(email_config_id: ids).group(:email_config_id).count
    end
  end
end

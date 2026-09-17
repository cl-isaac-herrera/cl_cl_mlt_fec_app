# frozen_string_literal: true

module Api
  # Bandejas de correo de RECEPCIÓN (pantalla /configurations/mail-parser,
  # "Bandejas de recepción"). Reemplaza el catálogo `MailParserConfig` del
  # conector .NET legacy (`legacy/reception/clvsfemailsconector`), que el
  # frontend (`mail_parser_controller.js`) todavía llamaba con el nombrado
  # verbo-en-el-path del servidor de sincronización (`GET/POST/PATCH
  # /api/mail-parser`, con paginación `startPost`/`stepPost` 0-indexada) — acá
  # se renombra a REST (CLAUDE.md §28), igual que `connections`/`email_configs`.
  #
  # Recortado respecto al legacy: sin `CompanyId` ni `IsAutomatic`. La relación
  # con la compañía se invirtió (`companies.reception_mailbox_id`) y
  # "automática" no aplica porque `MailReceptionJob` corre siempre. La sección
  # "Compañías Emisoras" (`InboxProcessingTenant` del legacy) queda pendiente
  # aparte — no se toca en este cambio.
  #
  # Sin `destroy`: una bandeja no se borra —`companies.reception_mailbox_id` la
  # referencia con llave foránea— se da de baja con `Active: false` en el PATCH.
  class ReceptionMailboxesController < AuthorizedController
    before_action :authorize_action
    before_action :load_mailbox, only: [:update]

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index'  => 'Configurations_MailParser_ViewConfigurations',
      'create' => 'Configurations_MailParser_Create',
      'update' => 'Configurations_MailParser_Update'
    }.freeze

    # GET /api/reception_mailboxes?email=&use_token=&status=&page=&per_page=
    #
    # `unscoped`: es la pantalla que ADMINISTRA las bandejas, así que tiene que
    # ver las dadas de baja para poder reactivarlas (§28).
    def index
      scope = ReceptionMailbox.unscoped.search(email: params[:email], use_token: use_token_filter)
      scope = scope.where(is_active: status_filter) unless status_filter.nil?
      scope = scope.order(:email)

      total = scope.count
      items = scope.limit(per_page).offset((page - 1) * per_page).to_a
      counts = companies_counts(items.map(&:id))

      render json: ApiResponse.success(
        { Items: items.map { |m| serialize(m, companies_count: counts.fetch(m.id, 0)) }, Total: total }
      ).to_h
    end

    # GET /api/reception_mailboxes/assignable
    #
    # Catálogo mínimo (id + correo) para el selector "Bandeja de Recepción" de
    # la sección "Datos Generales" del formulario de compañías. Solo las
    # ACTIVAS: una bandeja dada de baja no se le puede asignar a nadie.
    #
    # Exige los permisos de COMPAÑÍAS (además del propio de la pantalla de
    # bandejas): quien administra compañías necesita el selector aunque no
    # administre bandejas de recepción — mismo criterio que
    # `Api::EmailConfigsController#assignable`.
    def assignable
      mailboxes = ReceptionMailbox.where(is_active: true).order(:email).select(:id, :email)

      render json: ApiResponse.success(mailboxes.map { |m| { Id: m.id, Email: m.email } }).to_h
    end

    # POST /api/reception_mailboxes
    def create
      mailbox = ReceptionMailbox.new(mailbox_params)
      return render_invalid(mailbox) unless mailbox.save

      render json: ApiResponse.success(serialize(mailbox), code: 201,
                                       message: 'Bandeja registrada con éxito.').to_h,
             status: :created
    end

    # PATCH /api/reception_mailboxes/:id
    #
    # El id viaja en el path: un `Id` que llegue en el cuerpo se ignora, porque
    # `mailbox_params` no lo mira.
    def update
      return render_invalid(@mailbox) unless @mailbox.update(mailbox_params)

      render json: ApiResponse.success(serialize(@mailbox), message: 'Bandeja actualizada con éxito.').to_h
    end

    private

    def authorize_action
      permission = PERMISSIONS[action_name]
      if permission.nil?
        require_any_permission!('Configurations_Companies_Create',
                                'Configurations_Companies_Update',
                                'Configurations_MailParser_ViewConfigurations')
      else
        require_permission!(permission)
      end
    end

    # `unscoped`: se puede editar (y reactivar) una bandeja dada de baja — es
    # la única forma de volver a ponerla en servicio.
    def load_mailbox
      @mailbox = ReceptionMailbox.unscoped.find_by(id: params[:id])
      return if @mailbox

      render json: ApiResponse.not_found('La bandeja no existe.').to_h, status: :not_found
    end

    # Se copia únicamente lo que vino en la petición, para que un PATCH
    # parcial no borre lo que no mencionó — mismo criterio que
    # `email_config_params`.
    def mailbox_params
      attrs = {}
      attrs[:mail_server] = text(:MailServer)   if params.key?(:MailServer)
      attrs[:email]       = text(:Email)        if params.key?(:Email)
      attrs[:port]        = number(:Port)       if params.key?(:Port)
      attrs[:use_token]   = boolean(:UseToken)  if params.key?(:UseToken)
      attrs[:url]         = text(:Url)          if params.key?(:Url)
      attrs[:grant_type]  = text(:GrantType)    if params.key?(:GrantType)
      attrs[:scope]       = text(:Scope)        if params.key?(:Scope)
      attrs[:client_id]   = text(:ClientId)     if params.key?(:ClientId)
      attrs[:is_active]   = boolean(:Active)    if params.key?(:Active)
      attrs.merge(password_param).merge(client_secret_param)
    end

    # En blanco = "sin cambio", no "borrarla" — el servidor nunca la devuelve
    # (ver `serialize`). Al CREAR sí hace falta alguna de las dos mitades de
    # credenciales, y de eso se encarga `ReceptionMailbox#secret_present_on_create`
    # junto con la prueba de credenciales del formulario.
    def password_param
      return {} if params[:Password].blank?

      { password: params[:Password] }
    end

    def client_secret_param
      return {} if params[:ClientSecret].blank?

      { client_secret: params[:ClientSecret] }
    end

    def text(key)    = params[key].to_s.strip.presence
    def number(key)  = params[key].to_s.strip.presence&.to_i
    def boolean(key) = ActiveModel::Type::Boolean.new.cast(params[key])

    # `use_token`/`status` del filtro: un valor ausente no filtra nada — mismo
    # criterio que `ssl_filter` de `Api::EmailConfigsController`.
    def use_token_filter
      return nil if params[:use_token].blank?

      ActiveModel::Type::Boolean.new.cast(params[:use_token])
    end

    def status_filter
      return nil if params[:status].blank?

      ActiveModel::Type::Boolean.new.cast(params[:status])
    end

    def render_invalid(mailbox)
      render json: ApiResponse.error(mailbox.errors.full_messages.to_sentence).to_h,
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

    # ⚠️ `password`/`client_secret` NUNCA salen, ni cifrados ni en claro: son
    # de solo escritura, igual que `email_configs.password` (§38). Lo que la
    # pantalla necesita saber es si ya hay uno guardado, y eso lo responde un
    # booleano.
    #
    # `CompaniesCount` es lo que hace visible por qué una bandeja no se puede
    # dar de baja, antes de que el guardado lo rechace — mismo motivo que en
    # `Api::EmailConfigsController#serialize`.
    def serialize(mailbox, companies_count: nil)
      {
        Id: mailbox.id,
        MailServer: mailbox.mail_server,
        Email: mailbox.email,
        Port: mailbox.port,
        UseToken: mailbox.use_token,
        Url: mailbox.url,
        GrantType: mailbox.grant_type,
        Scope: mailbox.scope,
        ClientId: mailbox.client_id,
        HasPassword: mailbox.password_stored?,
        HasClientSecret: mailbox.client_secret_stored?,
        Active: mailbox.is_active,
        CompaniesCount: companies_count || mailbox.companies.count
      }
    end

    # Cuántas compañías activas usa cada bandeja, en UNA consulta — mismo
    # motivo que `Api::EmailConfigsController#companies_counts`.
    def companies_counts(ids)
      return {} if ids.empty?

      Company.where(reception_mailbox_id: ids).group(:reception_mailbox_id).count
    end
  end
end

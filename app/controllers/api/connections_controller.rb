# frozen_string_literal: true

module Api
  # Conexiones a servidores SAP (pantalla /configurations/connections).
  #
  # Reemplaza el `ConnectionsController` del .NET, cuyos paths llevaban el verbo
  # adentro (`GET /api/Connections/for-assignment`, `PATCH /api/Connections` con
  # el id en el cuerpo). Acá el verbo va en el método HTTP y el id en el path
  # (`CLAUDE.md` §28).
  #
  # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
  class ConnectionsController < AuthorizedController
    # El permiso se resuelve ANTES de buscar el registro: si se hiciera al revés,
    # un 404 le confirmaría a quien no tiene permiso qué ids existen.
    before_action :authorize_action
    before_action :load_connection, only: %i[show update]

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index'  => 'Configurations_Connections_Access',
      'show'   => 'Configurations_Connections_Access',
      'create' => 'Configurations_Connections_Create',
      'update' => 'Configurations_Connections_Update'
    }.freeze

    # GET /api/connections?name=&sl_url=&page=1&per_page=10
    #
    # Paginación por query string, no por los headers `cl-dba-pagination-*` del
    # .NET: la página es parte de la identificación del recurso, y así la URL se
    # puede compartir y cachear. El total viaja en el cuerpo (`Data.Total`) para
    # que el contador de Tabulator no tenga que inferirlo (`CLAUDE.md` §17).
    def index
      scope = Connection.search(name: params[:name], sl_url: params[:sl_url]).order(:name)
      total = scope.count
      items = scope.limit(per_page).offset((page - 1) * per_page)

      render json: ApiResponse.success(
        { Items: items.map { |c| serialize(c) }, Total: total }
      ).to_h
    end

    # GET /api/connections/assignable
    #
    # Catálogo mínimo (id + nombre) para el selector "Conexión de SAP" del
    # formulario de compañías. No exige `Configurations_Connections_Access`
    # porque el `for-assignment` del .NET tampoco lo exigía, y quien administra
    # compañías no necesariamente administra conexiones: pedirlo acá rompería esa
    # pantalla. Lo que se expone es solo el nombre, nunca la configuración.
    def assignable
      connections = Connection.order(:name).select(:id, :name)

      render json: ApiResponse.success(
        connections.map { |c| { Id: c.id, Name: c.name } }
      ).to_h
    end

    # GET /api/connections/:id
    #
    # Solo acá viaja `SapDbs`: son las bases de SAP de las compañías que ya usan
    # esta conexión, y alimentan las sugerencias del campo "Base de datos de SAP"
    # con el que se prueban las credenciales de licencia. En `index` sería una
    # consulta por fila (N+1) para un dato que la tabla no muestra.
    def show
      render json: ApiResponse.success(serialize(@connection).merge(SapDbs: sap_dbs(@connection))).to_h
    end

    # POST /api/connections
    def create
      connection = Connection.new(connection_params)
      return render_invalid(connection) unless connection.save

      render json: ApiResponse.success(serialize(connection), code: 201,
                                       message: 'Conexión creada con éxito.').to_h,
             status: :created
    end

    # PATCH /api/connections/:id
    #
    # El id viaja en el path, no en el cuerpo como en el .NET: un `Id` que llegue
    # en el JSON se ignora, porque `connection_params` no lo mira.
    def update
      return render_invalid(@connection) unless @connection.update(connection_params)

      render json: ApiResponse.success(serialize(@connection),
                                       message: 'Conexión actualizada con éxito.').to_h
    end

    private

    def authorize_action
      permission = PERMISSIONS[action_name]
      # `assignable` no está en el mapa a propósito: ver el comentario de la acción.
      return skip_permission_check! if permission.nil?

      require_permission!(permission)
    end

    def load_connection
      @connection = Connection.find_by(id: params[:id])
      return if @connection

      render json: ApiResponse.not_found('La conexión no existe.').to_h, status: :not_found
    end

    # Los campos que el formulario administra. Los parámetros de DI-API/ODBC del
    # .NET (ODBCType, ServerType, DBUser, DBPass, …) no se aceptan: este producto
    # llega a SAP únicamente por Service Layer (`CLAUDE.md` §29).
    #
    # `SlType` tampoco: el motor salió del formulario y ya no lo escribe nadie
    # (ver `TODOS.md` → Conexiones para la baja de la columna).
    #
    # Se copia únicamente lo que vino en la petición, para que un PATCH parcial
    # no borre lo que no mencionó.
    def connection_params
      attrs = {}
      attrs[:name]        = params[:Name].to_s.strip     if params.key?(:Name)
      attrs[:sl_url]      = params[:SlUrl].to_s.strip    if params.key?(:SlUrl)
      attrs[:sap_license] = params[:SapLicense].presence if params.key?(:SapLicense)
      attrs.merge(license_password_param)
    end

    # Contraseña en blanco = "sin cambio", no "borrarla". El servidor nunca la
    # devuelve (ver `serialize`), así que el formulario siempre carga el campo
    # vacío: tomarlo al pie de la letra dejaría a la conexión sin credenciales
    # cada vez que alguien corrige el nombre.
    #
    # Para quitarlas se manda `SapLicense` vacío, que sí es explícito: sin
    # usuario, `Connection#sap_license?` ya es falso y el job no intenta entrar —
    # y dejar la contraseña colgando sería guardar un secreto que nadie puede usar.
    #
    # @return [Hash] vacío cuando no hay nada que cambiar.
    def license_password_param
      return { sap_license_password: params[:SapLicensePassword] } if params[:SapLicensePassword].present?
      return { sap_license_password: nil } if params.key?(:SapLicense) && params[:SapLicense].blank?

      {}
    end

    def render_invalid(connection)
      render json: ApiResponse.error(connection.errors.full_messages.to_sentence).to_h,
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

    # Claves en PascalCase, igual que el resto de respuestas que consume el
    # frontend. `SlUrl` reemplaza a `APIUrl` del .NET.
    #
    # ⚠️ `sap_license_password` NO sale nunca, ni cifrada ni en claro: es un campo
    # de solo escritura, igual que los ajustes con `is_visible: false` (`CLAUDE.md`
    # §36). Lo que la pantalla necesita saber es si ya hay una guardada —para
    # decir "déjelo en blanco para conservarla" y para marcar la conexión a la que
    # le falta— y eso lo responde un booleano.
    def serialize(connection)
      {
        Id:                    connection.id,
        Name:                  connection.name,
        SlUrl:                 connection.sl_url,
        SapLicense:            connection.sap_license,
        HasSapLicensePassword: connection.sap_license_password.present?
      }
    end

    # Bases de SAP de las compañías que ya usan esta conexión. Son sugerencias
    # para el campo de la prueba, no configuración de la conexión: el `/Login` del
    # Service Layer exige un CompanyDB y la licencia es del servidor, así que
    # cualquiera de sus bases sirve para comprobarla.
    def sap_dbs(connection)
      connection.companies.where.not(sap_db: [nil, '']).distinct.pluck(:sap_db).sort
    end
  end
end

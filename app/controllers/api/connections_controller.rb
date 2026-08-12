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
    def show
      render json: ApiResponse.success(serialize(@connection)).to_h
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

    # Solo los tres campos que existen en la tabla. Los parámetros de DI-API/ODBC
    # del .NET (ODBCType, ServerType, DBUser, DBPass, …) no se aceptan: este
    # producto llega a SAP únicamente por Service Layer (`CLAUDE.md` §29).
    #
    # Se copia únicamente lo que vino en la petición, para que un PATCH parcial
    # no borre lo que no mencionó.
    def connection_params
      attrs = {}
      attrs[:name]    = params[:Name].to_s.strip  if params.key?(:Name)
      attrs[:sl_url]  = params[:SlUrl].to_s.strip if params.key?(:SlUrl)
      attrs[:sl_type] = params[:SlType].presence  if params.key?(:SlType)
      attrs
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
    # frontend. `SlUrl`/`SlType` reemplazan a `APIUrl`/`DBEngine` del .NET.
    def serialize(connection)
      {
        Id:     connection.id,
        Name:   connection.name,
        SlUrl:  connection.sl_url,
        SlType: connection.sl_type
      }
    end
  end
end

# frozen_string_literal: true

module Api
  # Consultas al Service Layer administrables (pantalla
  # /configurations/sl-resources).
  #
  # No reemplaza a ningún endpoint del .NET: allá estas filas se editaban
  # directamente en la base. Nace con el nombrado REST de `CLAUDE.md` §28 — el
  # verbo en el método HTTP, el recurso en `snake_case` plural, la página por
  # query string y el total en el cuerpo.
  #
  # No expone `create` ni `destroy` a propósito: el catálogo lo define el
  # producto (`db/seeds.rb`) y la pantalla es de mantenimiento, no de alta. Una
  # consulta que la app no sabe consumir no sirve de nada.
  class SlResourcesController < AuthorizedController
    # El permiso se resuelve ANTES de buscar el registro: si se hiciera al revés,
    # un 404 le confirmaría a quien no tiene permiso qué ids existen.
    before_action :authorize_action
    before_action :load_sl_resource, only: %i[show update]

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index'  => 'Configurations_SlResources_Access',
      'show'   => 'Configurations_SlResources_Access',
      'update' => 'Configurations_SlResources_Update'
    }.freeze

    # GET /api/sl_resources?code=&resource=&is_standard=&page=1&per_page=10
    def index
      scope = SlResource.search(code: params[:code], resource: params[:resource],
                                is_standard: standard_filter).order(:code)
      total = scope.count
      items = scope.limit(per_page).offset((page - 1) * per_page)

      render json: ApiResponse.success(
        { Items: items.map { |r| serialize(r) }, Total: total }
      ).to_h
    end

    # GET /api/sl_resources/:id
    def show
      render json: ApiResponse.success(serialize(@sl_resource)).to_h
    end

    # PATCH /api/sl_resources/:id
    #
    # Editar una consulta la vuelve "Personalizado": deja de ser la que trae el
    # producto, así que `db:seed` no la vuelve a escribir. Se marca acá y no en un
    # callback del modelo para que el seed pueda seguir escribiendo
    # `is_standard: true` sin que se lo revierta.
    def update
      @sl_resource.assign_attributes(sl_resource_params)
      @sl_resource.mark_as_customized
      return render_invalid(@sl_resource) unless @sl_resource.save

      render json: ApiResponse.success(serialize(@sl_resource),
                                       message: 'Consulta actualizada con éxito.').to_h
    end

    private

    def authorize_action
      require_permission!(PERMISSIONS.fetch(action_name))
    end

    def load_sl_resource
      # `unscoped`: es una pantalla de administración, así que tiene que poder
      # abrir también una consulta dada de baja (`CLAUDE.md` §28).
      @sl_resource = SlResource.unscoped.find_by(id: params[:id])
      return if @sl_resource

      render json: ApiResponse.not_found('La consulta no existe.').to_h, status: :not_found
    end

    # `code` NO se acepta: es la llave con la que la app pide la consulta, y
    # renombrarla desde la pantalla dejaría al código buscando un código que ya no
    # existe. Por eso el panel lo muestra deshabilitado.
    #
    # Se copia únicamente lo que vino en la petición, para que un PATCH parcial no
    # borre lo que no mencionó.
    def sl_resource_params
      attrs = {}
      attrs[:resource]     = params[:Resource].to_s.strip if params.key?(:Resource)
      # `QueryParams` en blanco se guarda como NULL: es lo que significa "la
      # consulta no lleva query", y así queda igual que las 10 filas del export
      # que vienen sin parámetros.
      attrs[:query_params] = params[:QueryParams].presence if params.key?(:QueryParams)
      attrs
    end

    # Terciario, y por eso NO se llama `standard_filter?`: devuelve true / false /
    # nil, donde nil es "sin filtro" — que no es lo mismo que filtrar por `false`.
    # Cualquier otro valor se ignora en vez de tratarse como `false`, para que un
    # parámetro mal escrito no devuelva silenciosamente el subconjunto equivocado.
    def standard_filter
      case params[:is_standard].to_s
      when 'true'  then true
      when 'false' then false
      end
    end

    def render_invalid(sl_resource)
      render json: ApiResponse.error(sl_resource.errors.full_messages.to_sentence).to_h,
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
    # frontend (§28.7).
    #
    # `UpdatedAt` va en ISO 8601 y el formato final lo pone el cliente (§5).
    # `UpdatedBy` puede ser nil: `Auditable` solo lo llena en un UPDATE, así que
    # una consulta recién sembrada no tiene autor de modificación todavía.
    def serialize(sl_resource)
      {
        Id:          sl_resource.id,
        Code:        sl_resource.code,
        Description: sl_resource.description,
        Resource:    sl_resource.resource,
        QueryParams: sl_resource.query_params,
        PageSize:    sl_resource.page_size,
        IsStandard:  sl_resource.is_standard,
        UpdatedAt:   sl_resource.updated_at&.iso8601,
        UpdatedBy:   sl_resource.updated_by
      }
    end
  end
end

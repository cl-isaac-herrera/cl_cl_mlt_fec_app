# frozen_string_literal: true

module Api
  # Roles del producto (pantalla /configurations/security).
  #
  # Reemplaza `GET /api/Rol/GetRoles?companyId=N`, `POST /api/Rol` y
  # `PATCH /api/Rol` (que mandaba el id en el cuerpo). El verbo va en el método
  # HTTP y el id en el path (`CLAUDE.md` §28).
  #
  # ⚠️ El listado ya NO se filtra por compañía: en el esquema propio `roles` no
  # tiene `company_id` — la compañía vive en `user_roles`, como manda
  # CLAVISCO-PLATFORM-STANDARDS §4.1. Ver `TODOS.md`.
  class RolesController < AuthorizedController
    before_action :authorize_action
    before_action :load_role, only: [:update]

    PERMISSION = 'Configurations_Security_Access'

    # GET /api/roles
    def index
      roles = Role.order(:name)

      render json: ApiResponse.success(roles.map { |r| serialize(r) }).to_h
    end

    # POST /api/roles
    #
    # El `GroupId` que mandaba el .NET no se acepta: no existe la columna ni la
    # tabla `groups` en la base propia.
    def create
      role = Role.new(name: role_name, is_active: true)
      return render_invalid(role) unless role.save

      render json: ApiResponse.success(serialize(role), code: 201,
                                       message: 'Rol creado con éxito.').to_h,
             status: :created
    end

    # PATCH /api/roles/:id
    def update
      if @role.protected_name?
        return render json: ApiResponse.forbidden('Este rol no permite su edición.').to_h,
                      status: :forbidden
      end

      return render_invalid(@role) unless @role.update(name: role_name)

      render json: ApiResponse.success(serialize(@role),
                                       message: 'Rol actualizado con éxito.').to_h
    end

    private

    def authorize_action
      require_permission!(PERMISSION)
    end

    def load_role
      @role = Role.find_by(id: params[:id])
      return if @role

      render json: ApiResponse.not_found('El rol no existe.').to_h, status: :not_found
    end

    # El .NET anidaba el rol dentro de `{ role: {...}, companyId: N }`. Acá el
    # recurso es el rol y lo único editable es su nombre: `Active` no se toca
    # desde esta pantalla y `companyId` no aplica (ver la nota de la clase).
    def role_name
      (params[:Name] || params.dig(:role, :Name)).to_s.strip
    end

    def render_invalid(role)
      render json: ApiResponse.error(role.errors.full_messages.to_sentence).to_h,
             status: :unprocessable_content
    end

    # `Active` en PascalCase mapea `is_active`: es el contrato que ya consume la
    # tabla de la pantalla.
    def serialize(role)
      { Id: role.id, Name: role.name, Active: role.is_active }
    end
  end
end

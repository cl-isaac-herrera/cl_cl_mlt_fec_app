# frozen_string_literal: true

module Api
  # Usuarios del producto (tab "Lista de usuarios" de /configurations/users).
  #
  # Reemplaza `GET /api/User/accessible`, `GET /api/User/information?userId=N`,
  # `POST /api/User` y `PATCH /api/User` (que mandaba el id en el cuerpo). El
  # verbo va en el método HTTP y el id en el path (`CLAUDE.md` §28).
  #
  # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
  class UsersController < AuthorizedController
    # El permiso se resuelve ANTES de buscar el registro: si se hiciera al revés,
    # un 404 le confirmaría a quien no tiene permiso qué ids existen.
    before_action :authorize_action
    before_action :load_user, only: %i[show update]

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index'  => 'Configurations_Users_ListAccess',
      'show'   => 'Configurations_Users_ListAccess',
      'create' => 'Configurations_Users_Create',
      'update' => 'Configurations_Users_Update'
    }.freeze

    # Permite ver a todos los usuarios del producto, no solo a los de la compañía
    # activa. No es un permiso de acción sino de alcance: se consulta con
    # `permission?`, que no corta la respuesta.
    SEE_ALL_PERMISSION = 'Configurations_Users_ViewAllApplicationUsers'

    # GET /api/users?name=&email=&page=1&per_page=10
    #
    # Paginación por query string y total en el cuerpo, igual que el resto de los
    # listados migrados (`CLAUDE.md` §17 y §28). El .NET traía la tabla entera y
    # paginaba en el navegador.
    def index
      scope = visible_users.search(name: params[:name], email: params[:email])
                           .order(:name, :email)
      total = scope.count
      items = scope.limit(per_page).offset((page - 1) * per_page)

      render json: ApiResponse.success(
        { Items: items.map { |u| serialize(u) }, Total: total }
      ).to_h
    end

    # GET /api/users/:id
    def show
      render json: ApiResponse.success(serialize(@user)).to_h
    end

    # POST /api/users
    #
    # Nace ACTIVO, al revés que el .NET, que lo creaba inactivo a la espera de que
    # confirmara su correo. Ese paso lo reemplazó el IdP: la cuenta la provisiona
    # el administrador y quien autentica es el proveedor OIDC. Además, un usuario
    # inactivo desaparece del listado por el default_scope de SoftDeletable, así
    # que crearlo así lo volvería invisible apenas se guarda.
    #
    # `CompanyId` es obligatorio: sin una fila en `users_by_companies` el usuario
    # entra pero no puede elegir compañía, y ninguna pantalla le funciona.
    def create
      company = assignable_company
      return if performed?

      user = User.new(user_params.merge(is_active: true))
      return render_invalid(user) unless user.save

      UsersByCompany.create!(user: user, company: company)

      render json: ApiResponse.success(serialize(user), code: 201,
                                       message: 'Usuario registrado con éxito.').to_h,
             status: :created
    end

    # PATCH /api/users/:id
    def update
      return render_invalid(@user) unless @user.update(user_params)

      render json: ApiResponse.success(serialize(@user),
                                       message: 'Usuario actualizado con éxito.').to_h
    end

    private

    def authorize_action
      require_permission!(PERMISSIONS.fetch(action_name))
    end

    # `unscoped` a propósito: el default_scope de SoftDeletable esconde a los
    # inactivos, y esta pantalla existe justamente para poder verlos y
    # reactivarlos — es lo que el .NET pedía con `activeOnly=false`.
    def visible_users
      return User.unscoped if permission?(SEE_ALL_PERMISSION)

      User.unscoped.in_company(Current.company_id)
    end

    def load_user
      @user = visible_users.find_by(id: params[:id])
      return if @user

      render json: ApiResponse.not_found('El usuario no existe.').to_h, status: :not_found
    end

    # La compañía a la que se asigna el usuario nuevo. Se valida contra las del
    # administrador que lo está creando: no puede sembrar usuarios en compañías a
    # las que él mismo no llega.
    def assignable_company
      company = Company.assigned_to(Current.user.id).find_by(id: params[:CompanyId])
      return company if company

      render json: ApiResponse.error('Seleccione una compañía asignada a su usuario.').to_h,
             status: :unprocessable_content
      nil
    end

    # Se copia únicamente lo que vino en la petición, para que un PATCH parcial no
    # borre lo que no mencionó.
    #
    # `SapPass` en blanco significa "no la cambies", no "borrala": es lo que manda
    # el panel de edición cada vez que se guarda sin tocar la contraseña.
    #
    # No se aceptan `EmailConfirmed`, `PasswordHash`, `UserName`, `Owner` ni
    # `Identification`: no existen como columna (ver la nota del modelo).
    def user_params
      attrs = {}
      attrs[:name]                  = params[:FullName].to_s.strip           if params.key?(:FullName)
      attrs[:email]                 = params[:Email].to_s.strip.downcase     if params.key?(:Email)
      attrs[:sap_user]              = params[:SapUser].to_s.strip            if params.key?(:SapUser)
      attrs[:sap_password]          = params[:SapPass]                       if params[:SapPass].present?
      attrs[:doc_number_preference] = params[:DocNumberPreference].presence  if params.key?(:DocNumberPreference)
      attrs[:is_active]             = ActiveModel::Type::Boolean.new.cast(params[:Active]) if params.key?(:Active)
      attrs
    end

    def render_invalid(user)
      render json: ApiResponse.error(user.errors.full_messages.to_sentence).to_h,
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

    # `FullName` mapea `name` y `Active` mapea `is_active`: es el contrato que ya
    # consume la tabla de la pantalla. La contraseña de SAP nunca sale: se puede
    # descifrar, así que exponerla sería regalarla.
    def serialize(user)
      {
        Id:                  user.id,
        FullName:            user.name,
        Email:               user.email,
        SapUser:             user.sap_user,
        DocNumberPreference: user.doc_number_preference,
        CreateDate:          user.created_at,
        Active:              user.is_active
      }
    end
  end
end

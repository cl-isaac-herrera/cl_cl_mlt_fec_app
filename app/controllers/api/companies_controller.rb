# frozen_string_literal: true

module Api
  # Compañías de la instalación (pantalla /configurations/companies).
  #
  # Reemplaza `GET /api/Companies/GetCompanies?LegalName=&ComercialName=&
  # Identification=&StartPos=&StepPos=` del API .NET por un recurso REST: el verbo
  # va en el método HTTP y la paginación en la query string (`CLAUDE.md` §28).
  #
  # Los filtros por nombre legal, nombre comercial e identificación no se migran:
  # esos datos viven en SAP (UDFs `U_CL_FEC_Emsr*` sobre `OADM`) y esta tabla solo
  # guarda el nombre con el que la compañía se identifica dentro del producto. El
  # único filtro es `name`, contra `companies.name`.
  #
  # `GET /api/companies` NO son las compañías del usuario de la sesión — esas son
  # `GET /api/profile/companies`.
  #
  # El cuerpo y la respuesta siguen en PascalCase: es contrato con el frontend.
  class CompaniesController < AuthorizedController
    include AssignableCompanies

    before_action :authorize_action

    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index' => 'Configurations_Companies_ListAccess'
    }.freeze

    # Permite ver todas las compañías de la instalación, no solo las asignadas al
    # usuario. No es un permiso de acción sino de alcance: se consulta con
    # `permission?`, que no corta la respuesta (`CLAUDE.md` §28).
    SEE_ALL_PERMISSION = 'Configurations_Companies_ViewAllApplicationCompanies'

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

    # `unscoped` a propósito: el default_scope de SoftDeletable esconde a las
    # inactivas, y esta pantalla existe justamente para poder verlas y
    # reactivarlas (`CLAUDE.md` §28).
    def visible_companies
      return Company.unscoped if permission?(SEE_ALL_PERMISSION)

      Company.unscoped.assigned_to(Current.user.id)
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
    # identificación ya no salen de acá: son UDFs de `OADM` en SAP.
    def serialize(company)
      {
        Id:     company.id,
        Name:   company.name,
        Active: company.is_active
      }
    end
  end
end

# frozen_string_literal: true

module Api
  # Compañías del usuario autenticado.
  #
  # Reemplaza `GET /api/Companies/GetCompanies?ComercialName=&LegalName=&...` del
  # API .NET por un recurso REST: el verbo va en el método HTTP, no en el path.
  class CompaniesController < AuthorizedController
    include AssignableCompanies
    # GET /api/companies
    def index
      # skip_permission_check! — no lleva permiso: son las compañías del propio
      # usuario y sin poder elegir una no puede usar ninguna pantalla. El filtro de
      # acceso es la asignación misma (users_by_companies), no un permiso aparte.
      skip_permission_check!

      companies = Company.assigned_to(Current.user.id).order(:name)

      render json: ApiResponse.success(companies.map { |c| serialize(c) }).to_h
    end

    # GET /api/companies/assignable
    #
    # Las compañías que el usuario de la sesión puede ASIGNARLE a otro: las suyas,
    # o todas si tiene `Configurations_Companies_ViewGroupCompanies` (ver el
    # concern `AssignableCompanies`). Alimenta el sub-tab "Compañías" del panel
    # "Gestionar accesos".
    #
    # Es otro conjunto que `index`, que son las compañías propias para el selector
    # del toolbar y no lleva permiso.
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

    # Claves en PascalCase, igual que el contrato ApiResponse (`Data`/`Code`/`Message`)
    # y que el resto de respuestas que consume el frontend.
    #
    # Se expone el `Uuid` como identificador estable y el `Id` interno porque es el
    # que reciben los demás endpoints. No hay datos de negocio de la compañía: esos
    # viven en SAP, y esta tabla solo dice contra qué base se opera.
    def serialize(company)
      {
        Id:           company.id,
        Uuid:         company.uuid,
        Name:         company.name,
        ConnectionId: company.connection_id,
        SapDbCode:    company.sap_db_code
      }
    end
  end
end

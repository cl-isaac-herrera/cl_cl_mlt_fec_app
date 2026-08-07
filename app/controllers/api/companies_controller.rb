# frozen_string_literal: true

module Api
  # Compañías del usuario autenticado.
  #
  # Reemplaza `GET /api/Companies/GetCompanies?ComercialName=&LegalName=&...` del
  # API .NET por un recurso REST: el verbo va en el método HTTP, no en el path.
  class CompaniesController < AuthorizedController
    # GET /api/companies
    def index
      # skip_permission_check! — no lleva permiso: son las compañías del propio
      # usuario y sin poder elegir una no puede usar ninguna pantalla. El filtro de
      # acceso es la asignación misma (users_by_companies), no un permiso aparte.
      skip_permission_check!

      companies = Company.assigned_to(Current.user.id).order(:name)

      render json: ApiResponse.success(companies.map { |c| serialize(c) }).to_h
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

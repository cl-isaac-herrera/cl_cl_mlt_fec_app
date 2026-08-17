# frozen_string_literal: true

module Api
  module Profile
    # Las compañías asignadas al usuario de la sesión.
    #
    # Alimenta el selector de compañía del toolbar, el select del panel de perfil
    # y el del alta de usuarios: los tres necesitan "las mías", no las de la
    # instalación.
    #
    # Vive bajo `profile` y no bajo `companies` porque el conjunto lo define la
    # sesión, no un filtro: es el mismo criterio de `GET /api/profile`
    # (`CLAUDE.md` §28, regla 3 — recurso singular, el id no viaja). Eso deja
    # libre `GET /api/companies` para lo que su nombre promete: las compañías de
    # la instalación, que es lo que administra /configurations/companies.
    class CompaniesController < AuthorizedController
      # GET /api/profile/companies
      def index
        # No lleva permiso: son las compañías del propio usuario y sin poder
        # elegir una no puede usar ninguna pantalla. El filtro de acceso es la
        # asignación misma (`users_by_companies`), no un permiso aparte.
        skip_permission_check!

        companies = Company.assigned_to(Current.user.id).order(:name)

        render json: ApiResponse.success(companies.map { |c| serialize(c) }).to_h
      end

      private

      # Claves en PascalCase, igual que el contrato ApiResponse (`Data`/`Code`/
      # `Message`) y que el resto de respuestas que consume el frontend.
      #
      # Se expone el `Uuid` como identificador estable y el `Id` interno porque es
      # el que reciben los demás endpoints. No hay datos de negocio de la
      # compañía: esos viven en SAP, y esta tabla solo dice contra qué base se
      # opera.
      #
      # `SapDbCode` conserva el nombre del contrato aunque la columna pasó a
      # llamarse `sap_db`: lo consume `company_selector_controller.js`.
      def serialize(company)
        {
          Id:           company.id,
          Uuid:         company.uuid,
          Name:         company.name,
          ConnectionId: company.connection_id,
          SapDbCode:    company.sap_db
        }
      end
    end
  end
end

# frozen_string_literal: true

module Api
  # Prueba la conexión a una base de datos externa con los ajustes que están
  # guardados (botón "Probar conexión" de /configurations/general).
  #
  # Es un `create` porque cada llamado produce una verificación nueva: el verbo
  # va en el método HTTP y el path nombra el recurso que se produce, no la acción
  # (`CLAUDE.md` §28, regla 4). Mismo criterio que
  # `Api::SapCredentialValidationsController`.
  #
  # ⚠️ Esto NO toca SAP. La base de documentos es propia; el acceso a SAP
  # Business One sigue siendo 100% Service Layer (`CLAUDE.md` §29).
  class ExternalDbHealthChecksController < AuthorizedController
    before_action -> { require_permission!(PERMISSION) }

    PERMISSION = 'Configurations_General_Access'

    # Grupos de `settings` que se pueden sondear desde la pantalla, en blanco.
    # El `group_code` viene del cliente y termina en una consulta a la base y en
    # una conexión ODBC: sin esta lista, cualquier grupo de ajustes se podría
    # usar como destino.
    GROUPS = %w[DOCS_DB_ODBC].freeze

    DEFAULT_GROUP = 'DOCS_DB_ODBC'

    # POST /api/external_db_health_checks
    #
    # Cuerpo opcional: `{ "GroupCode": "DOCS_DB_ODBC" }`.
    def create
      group_code = params[:GroupCode].presence || DEFAULT_GROUP

      unless GROUPS.include?(group_code)
        return render json: ApiResponse.error("El destino #{group_code.inspect} no existe.").to_h,
                      status: :unprocessable_content
      end

      result = ExternalDb::HealthCheck.call(group_code)

      # Que la conexión falle no es un error de la petición: la verificación se
      # hizo y su resultado ES la respuesta. 200 con `Ok: false` y el motivo en
      # `Message`, para que la pantalla lo muestre en vez de tratarlo como una
      # caída del endpoint.
      render json: ApiResponse.success(
        {
          Ok:        result.ok?,
          GroupCode: group_code,
          Engine:    result.engine,
          Version:   result.version,
          LatencyMs: result.latency_ms
        },
        message: result.message
      ).to_h
    end
  end
end

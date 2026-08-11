# frozen_string_literal: true

module Sap
  # Comprueba que un par usuario/contraseña de SAP sirva para entrar al Service
  # Layer de una compañía. Equivale a `SAPConnectionService.ValidateUserSAPCredentialsAsync`
  # del API .NET: arma el contexto con la conexión de la compañía y hace un `/Login`.
  #
  # No usa `vendor/clavisco/service_layer` porque ese submódulo no está montado en
  # este producto (ver config/initializers/clavisco_submodules.rb): es el único
  # llamado a SAP que hace la app y no justifica traerlo. Si algún día se monta,
  # esta clase se reemplaza por su cliente — el resto del código solo conoce
  # `#call` y el `Result`.
  #
  # Nunca levanta: cualquier fallo (conexión mal configurada, red caída, 401 de
  # SAP) sale como un Result inválido con el motivo, porque para la pantalla todos
  # significan lo mismo — esas credenciales no sirven.
  class CredentialValidator
    Result = Struct.new(:valid, :message, keyword_init: true) do
      def valid? = valid
    end

    def initialize(company:, sap_user:, sap_password:)
      @company      = company
      @sap_user     = sap_user.to_s
      @sap_password = sap_password.to_s
    end

    # @return [Result]
    def call
      missing = missing_prerequisite
      return failure(missing) if missing

      response = login
      return failure(error_message(response)) unless response.success?

      logout(response)
      Result.new(valid: true, message: 'Credenciales válidas.')
    rescue Faraday::Error => e
      failure("No se pudo contactar al Service Layer de SAP: #{e.message}")
    end

    private

    attr_reader :company, :sap_user, :sap_password

    # @return [String, nil] motivo por el que ni vale la pena llamar a SAP.
    def missing_prerequisite
      return 'Ingrese el usuario y la contraseña de SAP.' if sap_user.blank? || sap_password.blank?
      return 'La compañía no tiene una conexión SAP configurada.' if base_url.blank?
      return 'La compañía no tiene una base de datos de SAP asignada.' if company.sap_db_code.blank?

      nil
    end

    def base_url = company.sap_connection&.service_layer_url.to_s.chomp('/')

    def login
      http.post("#{base_url}/Login") do |req|
        req.body = { CompanyDB: company.sap_db_code, UserName: sap_user, Password: sap_password }.to_json
      end
    end

    # Best-effort: SAP limita las sesiones concurrentes por licencia, así que una
    # validación no puede dejar la suya abierta hasta que expire. Si el logout
    # falla, la validación siguió siendo exitosa — no se propaga.
    def logout(login_response)
      cookie = login_response.headers['set-cookie']
      return if cookie.blank?

      http.post("#{base_url}/Logout") { |req| req.headers['Cookie'] = cookie }
    rescue Faraday::Error
      nil
    end

    # El Service Layer responde los errores como OData:
    # { "error": { "code": -304, "message": { "lang": "en-us", "value": "..." } } }
    def error_message(response)
      value = JSON.parse(response.body.to_s).dig('error', 'message', 'value')
      value.presence || default_error(response)
    rescue JSON::ParserError
      default_error(response)
    end

    def default_error(response)
      "Las credenciales no son válidas (HTTP #{response.status})."
    end

    def failure(message) = Result.new(valid: false, message: message)

    def http
      @http ||= Faraday.new(
        headers: { 'Content-Type' => 'application/json' },
        ssl:     { verify: Rails.application.config.sap_sl_verify_ssl },
        request: {
          open_timeout: Rails.application.config.sap_sl_open_timeout,
          timeout:      Rails.application.config.sap_sl_timeout
        }
      )
    end
  end
end

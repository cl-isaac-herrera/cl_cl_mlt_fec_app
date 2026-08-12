# frozen_string_literal: true

module Sap
  # Comprueba que un par usuario/contraseña de SAP sirva para entrar al Service
  # Layer de una compañía. Equivale a `SAPConnectionService.ValidateUserSAPCredentialsAsync`
  # del API .NET: arma el contexto con la conexión de la compañía y se autentica.
  #
  # Usa `Clavisco::ServiceLayer::Client` (CLAVISCO-PLATFORM-STANDARDS §2.7) — nunca
  # HTTP a mano contra SAP. El Client no expone un `login` suelto: se autentica solo
  # en el primer request, contra el pool de sesiones singleton, tal como exige la
  # regla «Nunca crear sesiones SAP por request».
  #
  # Por eso la validación es un GET cualquiera. **El recurso da igual**: lo que se
  # está probando es el `/Login` que el Client hace antes, y ese falla con
  # `AuthenticationError` mucho antes de tocar el recurso. Si el login sí funcionó,
  # las credenciales son válidas aunque el GET falle después por permisos de ese
  # usuario dentro de SAP — de ahí que solo `AuthenticationError` cuente como
  # credenciales inválidas.
  #
  # La sesión NO se cierra al terminar: queda en el pool con la llave
  # `session_owner_id|company_db|username`, así que si el usuario guarda estas
  # credenciales, el trabajo real las reutiliza en vez de volver a autenticarse.
  # Cerrarla sería volver a "una sesión por request", justo lo que §2.7 prohíbe.
  #
  # Nunca levanta: cualquier fallo (conexión mal configurada, red caída, rechazo de
  # SAP) sale como un Result inválido con el motivo, porque para la pantalla todos
  # significan lo mismo — esas credenciales no sirven.
  class CredentialValidator
    # Recurso barato solo para forzar el login. Ver el comentario de la clase: no
    # se lee la respuesta, solo importa si la autenticación previa funcionó.
    PROBE_RESOURCE = 'BusinessPartners'
    PROBE_PARAMS   = { '$top' => 1, '$select' => 'CardCode' }.freeze

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

      client.get(PROBE_RESOURCE, params: PROBE_PARAMS)
      success
    rescue Clavisco::ServiceLayer::Client::AuthenticationError => e
      # SAP rechazó el /Login: es el caso que prueba que las credenciales están mal.
      failure(sap_reason(e) || 'Las credenciales no son válidas.')
    rescue Clavisco::ServiceLayer::Client::ServiceLayerError, StandardError => e
      # Todo lo demás es ambiguo: el error puede venir del recurso de prueba (con el
      # login ya hecho) o del login mismo caído por red/timeout, que el Client
      # envuelve en un ServiceLayerError genérico. El pool es lo único que lo sabe.
      session_established? ? success : failure("No se pudo contactar al Service Layer de SAP: #{e.message}")
    end

    private

    attr_reader :company, :sap_user, :sap_password

    # El Client valida sus argumentos con ArgumentError; se chequea antes para poder
    # devolver un motivo que le sirva a quien está llenando el formulario.
    #
    # @return [String, nil] motivo por el que ni vale la pena llamar a SAP.
    def missing_prerequisite
      return 'Ingrese el usuario y la contraseña de SAP.' if sap_user.blank? || sap_password.blank?
      return 'La compañía no tiene una conexión SAP configurada.' if base_url.blank?
      return 'La compañía no tiene una base de datos de SAP asignada.' if company_db.blank?

      nil
    end

    # La URL sale de `connections` y no de SAP_SL_URL porque el producto es
    # multi-compañía (§8, nota de nomenclatura de `connections`).
    def base_url   = company.sap_connection&.sl_url.to_s
    def company_db = company.sap_db_code.to_s

    def client
      @client ||= Clavisco::ServiceLayer::Client.new(
        base_url:         base_url,
        company_db:       company_db,
        username:         sap_user,
        password:         sap_password,
        # Quién consume la sesión. Con la misma llave, el trabajo posterior de este
        # usuario reutiliza la sesión que abrió esta validación.
        session_owner_id: Current.user&.id || 'credential-validation'
      )
    end

    # ¿Quedó una sesión viva en el pool para estas credenciales? Si la hay, el
    # `/Login` funcionó — que es exactamente lo que esta clase quiere saber.
    # `session_key` y `get_existing_node` son API pública del Client y del pool.
    def session_established?
      Clavisco::ServiceLayer::LoadBalancer.instance.get_existing_node(client.session_key)&.valid?
    end

    # SAP manda el detalle del rechazo en el cuerpo OData y el Client ya lo extrajo,
    # pero le antepone su propio prefijo. Se quita: al usuario le sirve el motivo de
    # SAP, no en qué capa del cliente se detectó.
    def sap_reason(error)
      (error.sap_message.presence || error.message.to_s.sub(/\ASL Login failed:\s*/, '')).presence
    end

    def success = Result.new(valid: true, message: 'Credenciales válidas.')
    def failure(message) = Result.new(valid: false, message: message)
  end
end

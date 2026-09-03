# frozen_string_literal: true

module Sap
  # Comprueba que un par usuario/contraseña de SAP sirva para entrar a un Service
  # Layer. Equivale a `SAPConnectionService.ValidateUserSAPCredentialsAsync`
  # del API .NET: arma el contexto y se autentica.
  #
  # Recibe el destino ya resuelto (`base_url` + `company_db`) porque los dos
  # consumidores lo obtienen de lugares distintos:
  #
  #   - `.for_company` — las credenciales personales de alguien contra la conexión
  #     de una compañía ya guardada (pantalla de perfil y de usuarios).
  #   - `.new` directo — las credenciales de licencia de una conexión que puede no
  #     estar guardada todavía, porque se prueban desde el formulario de conexiones
  #     antes de crearla. Ahí no hay compañía de la que derivar nada: la URL sale
  #     del campo que se está llenando y la base la escribe quien configura.
  #
  # La lógica delicada —el sondeo, la llave desechable del pool y la
  # desambiguación por sesión— vive UNA sola vez acá a propósito: es de donde
  # salió el falso positivo que se describe más abajo, y una segunda copia para el
  # caso de la licencia lo habría revivido en silencio.
  #
  # Usa `Clavisco::ServiceLayer::Client` (CLAVISCO-PLATFORM-STANDARDS §2.7) — nunca
  # HTTP a mano contra SAP. El Client no expone un `login` suelto: se autentica solo
  # en el primer request, contra el pool de sesiones singleton, tal como exige la
  # regla «Nunca crear sesiones SAP por request».
  #
  # Por eso la validación es un GET de sondeo. **El recurso da igual**: lo que se
  # está probando es el `/Login` que el Client hace antes, y ese falla con
  # `AuthenticationError` mucho antes de tocar el recurso. Si el login sí funcionó,
  # las credenciales son válidas aunque el GET falle después por permisos de ese
  # usuario dentro de SAP — de ahí que solo `AuthenticationError` cuente como
  # credenciales inválidas.
  #
  # Cuál es ese GET lo dice el catálogo (`sl_resources`), no esta clase: la fila
  # `qsValidateSapCredentials` ya existía en el producto .NET para esto mismo. Se
  # resuelve con `Sap::ResourceQuery`, que es el único lugar que traduce código
  # funcional → path de SAP.
  #
  # ⚠️ La sesión de esta validación es DESECHABLE, y es lo único que hace que la
  # respuesta sea confiable. El pool del Client indexa por
  # `session_owner_id|company_db|username` — **sin la contraseña** — y
  # `LoadBalancer#get_node` tiene un fast path que devuelve la sesión existente sin
  # pasar por `/Login`. Con una llave compartida, una sesión viva de ese usuario
  # (dejada por el trabajo real o por una validación anterior correcta) hacía que el
  # sondeo pasara con **cualquier** contraseña: reportaba "credenciales válidas" sin
  # haberlas probado. Reproducido antes de arreglarlo.
  #
  # Por eso `session_owner_id` es único por intento (`#session_owner_id`) y la
  # sesión se cierra al terminar (`#discard_session!`). Es la excepción deliberada a
  # «nunca cerrar la sesión» de §2.7: esa regla existe para que las operaciones
  # normales reutilicen sesión, y acá reutilizar es justamente el defecto. Dejarla
  # abierta sería además retener una licencia de SAP 20 minutos por cada click.
  #
  # Lo que se pierde: la sesión de la validación ya no la hereda el trabajo
  # posterior. Era una optimización menor y era el origen del falso positivo.
  #
  # Nunca levanta: cualquier fallo (conexión mal configurada, red caída, rechazo de
  # SAP) sale como un Result inválido con el motivo, porque para la pantalla todos
  # significan lo mismo — esas credenciales no sirven.
  class CredentialValidator
    # Consulta del catálogo que existe para esto (viene del producto .NET). No se
    # lee la respuesta: solo importa si la autenticación previa funcionó.
    PROBE_CODE = 'qsValidateSapCredentials'

    # Motivos por defecto cuando falta el destino. Los sobreescribe el llamador con
    # `missing_messages:`, que sí puede nombrar de quién es la configuración que
    # falta: "la compañía no tiene conexión" es accionable, "no hay URL" no dice
    # dónde ponerla.
    MISSING_MESSAGES = {
      base_url:   'No hay una URL de Service Layer contra la que probar.',
      company_db: 'Indique la base de datos de SAP contra la que probar.'
    }.freeze

    Result = Struct.new(:valid, :message, keyword_init: true) do
      def valid? = valid
    end

    # Credenciales personales contra la conexión de una compañía ya guardada.
    #
    # @param company [Company]
    def self.for_company(company:, sap_user:, sap_password:)
      new(
        # La URL sale de `connections` y no de SAP_SL_URL porque el producto es
        # multi-compañía (§8, nota de nomenclatura de `connections`).
        base_url:         company.sap_connection&.sl_url,
        company_db:       company.sap_db,
        sap_user:         sap_user,
        sap_password:     sap_password,
        missing_messages: {
          base_url:   'La compañía no tiene una conexión SAP configurada.',
          company_db: 'La compañía no tiene una base de datos de SAP asignada.'
        }
      )
    end

    # @param missing_messages [Hash] motivos a mostrar cuando falta el destino,
    #   por clave (`:base_url`, `:company_db`). Lo que no venga usa el default.
    def initialize(base_url:, company_db:, sap_user:, sap_password:, missing_messages: {})
      @base_url         = base_url.to_s
      @company_db       = company_db.to_s
      @sap_user         = sap_user.to_s
      @sap_password     = sap_password.to_s
      @missing_messages = MISSING_MESSAGES.merge(missing_messages)
    end

    # @return [Result]
    def call
      missing = missing_prerequisite
      return failure(missing) if missing

      probe!
      success
    rescue Clavisco::ServiceLayer::Client::AuthenticationError => e
      # SAP rechazó el /Login: es el caso que prueba que las credenciales están mal.
      failure(sap_reason(e) || 'Las credenciales no son válidas.')
    rescue Sap::ResourceQuery::Error => e
      # El catálogo está mal: no se llegó a hablar con SAP, así que esto no dice
      # nada sobre las credenciales.
      #
      # ⚠️ Va ANTES del rescue genérico y no puede caer en él: ese consulta el pool
      # de sesiones para desambiguar, y una sesión vieja de este mismo usuario lo
      # haría reportar "credenciales válidas" sin haber sondeado nunca.
      failure("No se pudo preparar la consulta de validación: #{e.message}")
    rescue Clavisco::ServiceLayer::Client::ServiceLayerError, StandardError => e
      # Todo lo demás es ambiguo: el error puede venir del recurso de prueba (con el
      # login ya hecho) o del login mismo caído por red/timeout, que el Client
      # envuelve en un ServiceLayerError genérico. El pool es lo único que lo sabe.
      #
      # Preguntarle al pool solo es concluyente porque la llave es única por intento:
      # si hay sesión, la abrió ESTE `/Login`. Con una llave compartida podía ser de
      # antes y la respuesta era un falso positivo.
      session_established? ? success : failure("No se pudo contactar al Service Layer de SAP: #{e.message}")
    ensure
      discard_session!
    end

    private

    attr_reader :base_url, :company_db, :sap_user, :sap_password, :missing_messages

    # Fuerza el `/Login` con la consulta que el catálogo define para esto.
    #
    # El verbo lo elige el llamador: `ResourceQuery` solo arma el path (acá es una
    # lectura; `Drafts` o los `/Close` del catálogo son POST).
    #
    # Se loguea el path en `info`, no en `debug`: validar credenciales lo dispara
    # una persona desde una pantalla, no es tráfico de fondo, y cuando falla lo
    # primero que hay que saber es contra qué endpoint se probó. Esta consulta no
    # lleva marcadores, así que el path no contiene datos de negocio.
    def probe!
      path = Sap::ResourceQuery.path_for(PROBE_CODE)
      Rails.logger.info("[Sap::CredentialValidator] sondeo de login: GET #{path}")
      client.get(path)
    end

    # El Client valida sus argumentos con ArgumentError; se chequea antes para poder
    # devolver un motivo que le sirva a quien está llenando el formulario.
    #
    # @return [String, nil] motivo por el que ni vale la pena llamar a SAP.
    def missing_prerequisite
      return 'Ingrese el usuario y la contraseña de SAP.' if sap_user.blank? || sap_password.blank?
      return missing_messages[:base_url]   if base_url.blank?
      return missing_messages[:company_db] if company_db.blank?

      nil
    end

    def client
      @client ||= Clavisco::ServiceLayer::Client.new(
        base_url:         base_url,
        company_db:       company_db,
        username:         sap_user,
        password:         sap_password,
        session_owner_id: session_owner_id
      )
    end

    # Único por intento, y esa unicidad ES la validación: la llave del pool no
    # incluye la contraseña, así que compartirla con otra sesión del mismo usuario
    # deja que `get_node` devuelva la sesión existente sin hacer `/Login` — y
    # cualquier contraseña pasaría. Con un UUID, la llave no puede colisionar y el
    # `/Login` se ejecuta siempre.
    #
    # No usa `Current.user.id`: dos validaciones del mismo usuario ya colisionaban
    # entre sí, y con `Current.user` nil (jobs, consola) TODAS compartían la llave
    # `credential-validation|...`.
    def session_owner_id
      @session_owner_id ||= "credential-validation:#{SecureRandom.uuid}"
    end

    # Cierra la sesión que abrió este intento. Se llama en el `ensure` de `#call`,
    # después de que el Result ya se calculó (`#session_established?` necesita el
    # pool intacto para desambiguar).
    #
    # Acá cerrar SÍ corresponde, al contrario de lo que pide §2.7 para las
    # operaciones normales: la llave es desechable, nadie va a reutilizar esta
    # sesión, y dejarla abierta retiene una licencia de SAP hasta que expire.
    #
    # Nunca levanta: el Result ya está decidido y un fallo al cerrar no lo cambia.
    def discard_session!
      @client&.logout
    rescue StandardError => e
      Rails.logger.warn("[Sap::CredentialValidator] no se pudo cerrar la sesión de sondeo: #{e.message}")
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

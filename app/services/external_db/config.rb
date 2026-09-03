# frozen_string_literal: true

module ExternalDb
  # Destino ODBC armado desde un grupo de `settings`.
  #
  #   ExternalDb::Config.load('DOCS_DB_ODBC')
  #
  # Lee el grupo una sola vez y valida todo junto, para que un destino a medio
  # configurar falle nombrando TODOS los ajustes que faltan en un mensaje, y no
  # de a uno por intento.
  #
  # ---------------------------------------------------------------------------
  # Los campos NO significan lo mismo en los dos motores
  #
  # Es la razón por la que existe `Dialect` y por la que esta clase no arma la
  # cadena de conexión:
  #
  #   SQL Server │ Server=CLSQL01;Database=CL_DOCS
  #              │   · el puerto es opcional (1433 implícito) y va con COMA
  #              │   · `database` es un parámetro del DSN
  #
  #   HANA       │ SERVERNODE=clhna721:30015
  #              │   · el puerto es OBLIGATORIO y va con DOS PUNTOS
  #              │   · `database` NO va en el DSN: califica cada objeto de cada
  #              │     consulta (`CALL <db>.SP1`), que es como se hace hoy en
  #              │     las instalaciones vivas
  #
  # Por eso `port` se valida como obligatorio solo en HANA, y `database` se
  # guarda igual en los dos casos aunque solo uno lo ponga en el DSN.
  class Config
    ENGINES = %w[SQL HANA].freeze

    # Ajustes que tienen que tener valor siempre.
    REQUIRED = %w[ENGINE DRIVER SERVER].freeze

    # Y estos dos, solo cuando la conexión se autentica con usuario y contraseña.
    # Con autenticación integrada de Windows no hay ninguno que pedir: la
    # identidad es la de la cuenta que corre el proceso.
    CREDENTIAL_FIELDS = %w[USER PASSWORD].freeze

    # Qué se acepta como "sí" en `TRUSTED`. Lista explícita y no
    # `ActiveModel::Type::Boolean`, que trata como verdadero todo lo que no esté
    # en su lista de falsos: un `"no"` escrito a mano activaría la autenticación
    # integrada, que es exactamente el error que no puede pasar desapercibido.
    TRUE_VALUES = %w[true 1 yes y si sí on].freeze

    # Segundos. Un tope acotado en vez de esperar indefinido: una consulta que se
    # cuelga con el mutex del pool tomado bloquea a los demás hilos.
    DEFAULT_QUERY_TIMEOUT = 30

    # Tope de filas que el driver trae de un solo resultado. No es paginación: es
    # el freno para que un `SELECT` sin `WHERE` contra una tabla de millones de
    # filas no se traiga todo a la memoria del proceso Ruby.
    MAX_ROWS = 10_000

    # Separador de los tramos del fingerprint. Se usa `\0` —escrito como escape,
    # nunca como byte crudo en el fuente— porque no puede aparecer dentro de un
    # nombre de servidor ni de una contraseña. Con un espacio,
    # `['ab', 'c']` y `['a', 'bc']` producirían el mismo hash y dos
    # configuraciones distintas compartirían el pool.
    FINGERPRINT_SEPARATOR = "\0"

    attr_reader :group_code, :engine, :driver, :server, :port,
                :database, :schema, :user, :password, :query_timeout, :extra_params,
                :trusted

    class << self
      # Construye el destino desde la base. Levanta `ConfigurationError` si falta
      # algo — nunca devuelve un objeto a medias.
      def load(group_code)
        new(group_code: group_code, values: Setting.group(group_code))
      end
    end

    def initialize(group_code:, values:)
      @group_code = group_code

      @engine   = values['ENGINE'].to_s.strip.upcase
      @driver   = values['DRIVER'].to_s.strip
      @server   = values['SERVER'].to_s.strip
      @port     = values['PORT'].to_s.strip.presence
      @database = values['DATABASE'].to_s.strip.presence
      @schema   = values['SCHEMA'].to_s.strip.presence
      @user     = values['USER'].to_s.strip
      @password = values['PASSWORD'].to_s
      @trusted  = TRUE_VALUES.include?(values['TRUSTED'].to_s.strip.downcase)

      @query_timeout = (values['QUERY_TIMEOUT'].presence || DEFAULT_QUERY_TIMEOUT).to_i
      @extra_params  = values['EXTRA_PARAMS'].to_s.strip.presence

      validate!(values)
    end

    # ¿Se autentica con la identidad de Windows del proceso en vez de con usuario
    # y contraseña?
    #
    # ── Lo que implica, y que no se ve desde la pantalla ─────────────────────
    # La identidad deja de ser un dato de la configuración y pasa a ser **la
    # cuenta que corre el proceso Rails**: en desarrollo la del programador, en
    # el servidor la del servicio. Dos consecuencias:
    #
    #   · El permiso de solo lectura del que depende `CLAUDE.md` §37 hay que
    #     concedérselo a ESA cuenta, no al usuario que alguien escribió acá.
    #   · Cambiar la cuenta del servicio cambia con qué credenciales se conecta
    #     la aplicación, sin que nada en la pantalla se vea distinto.
    def trusted?
      trusted
    end

    def hana?
      engine == 'HANA'
    end

    def sql_server?
      engine == 'SQL'
    end

    # Identidad del destino, para que el pool sepa que la configuración cambió y
    # tenga que descartar las conexiones abiertas.
    #
    # Se hashea en vez de guardar los valores: esta cadena termina como llave de
    # un hash en memoria y en mensajes de log, y no tiene por qué llevar la
    # contraseña adentro. Que el hash incluya la contraseña sí importa — si no,
    # cambiarla desde la pantalla dejaría vivas las conexiones con la anterior.
    def fingerprint
      material = [engine, driver, server, port, database, schema, user, password,
                  trusted, query_timeout, extra_params].join(FINGERPRINT_SEPARATOR)

      "#{group_code}:#{Digest::SHA256.hexdigest(material)[0, 16]}"
    end

    # Descripción del destino apta para un log o un mensaje de error. Sin
    # credenciales: se registra a dónde se intentó llegar, no con qué.
    def to_s
      "#{engine} #{server}#{port ? ":#{port}" : ''}#{database ? "/#{database}" : ''}"
    end
    alias inspect to_s

    private

    # Un solo mensaje con todo lo que falta. Junta los ajustes ausentes en vez de
    # cortar en el primero: el operador que abre la pantalla por primera vez tiene
    # que llenar diez campos, y enterarse de a uno por intento es inútil.
    def validate!(values)
      missing = REQUIRED.reject { |field| values[field].present? }

      # Usuario y contraseña dejan de ser obligatorios con autenticación
      # integrada: no hay credenciales que escribir, y exigirlas obligaría a
      # inventar un valor de relleno que después nadie sabe si se usa.
      missing.concat(CREDENTIAL_FIELDS.reject { |field| values[field].present? }) unless trusted?

      # El puerto es obligatorio en HANA y no en SQL Server: `SERVERNODE` exige
      # `host:puerto` (el puerto de instancia es 3<NN>15 — 30015 para la
      # instancia 00), mientras que el driver de SQL Server asume 1433.
      missing << 'PORT' if hana? && port.blank?

      if missing.any?
        raise ConfigurationError,
              'Faltan ajustes de la conexión a la base de documentos: ' \
              "#{missing.map { |f| "#{group_code}_#{f}" }.join(', ')}. " \
              'Complételos en Configuraciones → Generales.'
      end

      unless ENGINES.include?(engine)
        raise ConfigurationError,
              "El motor #{engine.inspect} no es válido (#{group_code}_ENGINE). " \
              "Valores admitidos: #{ENGINES.join(' | ')}."
      end

      validate_trusted!
      validate_port!
      validate_driver!
    end

    # La autenticación integrada es de SQL Server: la habilita el
    # `Trusted_Connection` de su driver ODBC. El de SAP HANA no tiene esa
    # palabra clave —su equivalente es Kerberos/SSO y se configura aparte—, así
    # que activarla ahí no haría nada: la conexión intentaría autenticarse sin
    # usuario y fallaría con un error del driver que no menciona este ajuste.
    def validate_trusted!
      return unless trusted? && hana?

      raise ConfigurationError,
            "La autenticación integrada de Windows (#{group_code}_TRUSTED) es de " \
            'SQL Server: el driver de SAP HANA no la admite. Desactívela y ' \
            "configure #{group_code}_USER y #{group_code}_PASSWORD."
    end

    def validate_port!
      return if port.blank?
      return if port.match?(/\A\d{1,5}\z/) && port.to_i.between?(1, 65_535)

      raise ConfigurationError,
            "El puerto #{port.inspect} no es válido (#{group_code}_PORT). " \
            'Debe ser un número entre 1 y 65535.'
    end

    # El driver se valida contra los que el sistema tiene registrados, porque es
    # el error más difícil de diagnosticar por su cuenta: un nombre mal escrito
    # produce "Data source name not found and no default driver specified", que no
    # dice cuál es el nombre correcto ni cuáles hay disponibles.
    #
    # No levanta si no se pudo consultar el driver manager: la validación es una
    # ayuda, no una barrera, y en un entorno sin ODBC instalado el error correcto
    # es el de la conexión, no este.
    def validate_driver!
      installed = begin
        ExternalDb::Client.installed_drivers
      rescue StandardError
        return
      end

      return if installed.empty?
      return if installed.any? { |name| name.casecmp?(driver) }

      raise ConfigurationError,
            "El driver ODBC #{driver.inspect} no está instalado en el servidor " \
            "(#{group_code}_DRIVER). Instalados: #{installed.join(' | ')}."
    end
  end
end

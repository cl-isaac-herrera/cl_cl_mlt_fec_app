# frozen_string_literal: true

module ExternalDb
  # Conexión ODBC a la base externa, con la consulta parametrizada.
  #
  #   client = ExternalDb::Client.new(config)
  #   client.select('SELECT Id, Nombre FROM Docs WHERE Estado = ?', ['abierto'])
  #   client.call('SP_DOCS_POR_FECHA', [desde, hasta])
  #   client.close
  #
  # Normalmente no se instancia a mano: `ExternalDb::Pool.with(grupo)` entrega uno
  # ya conectado y lo devuelve al pool al terminar.
  #
  # ---------------------------------------------------------------------------
  # Los valores van como parámetros, SIEMPRE
  #
  # `#select` y `#call` reciben la sentencia con `?` y los valores aparte. El
  # driver los manda tipados y fuera del texto de la consulta, así que no hay
  # forma de que un valor se interprete como SQL. Interpolar en la cadena
  # (`"… WHERE id = #{params[:id]}"`) es una inyección, y acá no hay ninguna API
  # que lo permita: no existe un método que reciba solo un string y lo ejecute
  # sin pasar por el guard.
  #
  # `?` es el placeholder de ODBC y funciona igual en los dos drivers — no hay
  # que traducirlo por motor.
  # ---------------------------------------------------------------------------
  class Client
    attr_reader :config, :dialect

    class << self
      # Nombres de los drivers ODBC registrados en el sistema. Lo usa
      # `Config#validate_driver!` para dar un error que diga qué hay instalado.
      def installed_drivers
        require_odbc!

        ODBC.drivers.map(&:name)
      end

      # Carga la extensión nativa. Está declarada `require: false` en el Gemfile
      # (ver el comentario de ahí): una instalación de ODBC rota tiene que fallar
      # en el módulo de documentos, no en el boot de la app.
      def require_odbc!
        require 'odbc'
      rescue LoadError => e
        raise ConnectionError,
              'No se pudo cargar el conector ODBC en este servidor ' \
              "(#{e.message}). Verifique que la gema ruby-odbc esté instalada."
      end
    end

    def initialize(config)
      @config  = config
      @dialect = Dialect.for(config)
    end

    # ----------------------------------------------------------------
    # Ciclo de vida
    # ----------------------------------------------------------------

    def connect
      return self if connected?

      self.class.require_odbc!

      @db = ODBC::Database.new
      @db.drvconnect(dialect.connection_string)
      apply_session_options!

      Rails.logger.info("[ExternalDb] conectado a #{config}")
      self
    rescue ODBC::Error => e
      # El mensaje del driver se limpia antes de propagarlo: trae el SQLSTATE y
      # el nombre del driver por delante, y la parte útil para el operador está
      # al final. Ver `#sanitize`.
      @db = nil
      raise ConnectionError,
            "No se pudo conectar a la base de documentos (#{config}): #{sanitize(e.message)}"
    end

    def connected?
      @db&.connected? || false
    end

    def close
      return unless @db

      @db.disconnect
    rescue ODBC::Error => e
      # Cerrar una conexión que el servidor ya cerró no es un problema del
      # llamador y no tiene que tumbar su request.
      Rails.logger.warn("[ExternalDb] no se pudo cerrar la conexión: #{sanitize(e.message)}")
    ensure
      @db = nil
    end

    # ----------------------------------------------------------------
    # Lectura
    # ----------------------------------------------------------------

    # Ejecuta un `SELECT` parametrizado y devuelve un arreglo de hashes con las
    # columnas como llaves (tal como las nombra la base).
    #
    #   select('SELECT Id, Total FROM Docs WHERE Fecha >= ?', [fecha])
    #   # => [{ 'Id' => 1, 'Total' => 1500.0 }, …]
    def select(sql, binds = [])
      StatementGuard.assert_read_only!(sql)

      run(sql, binds)
    end

    # Igual que `#select`, pero paginado por el dialecto.
    def select_page(sql, binds = [], limit:, offset: 0)
      StatementGuard.assert_read_only!(sql)

      run(dialect.paginate(sql, limit: limit, offset: offset), binds)
    end

    # La primera fila, o `nil`.
    def select_one(sql, binds = [])
      select(sql, binds).first
    end

    # El primer valor de la primera fila, o `nil`. Para los `SELECT` de un solo
    # dato (un conteo, la versión del motor).
    def select_value(sql, binds = [])
      select_one(sql, binds)&.values&.first
    end

    # Invoca un procedimiento almacenado con la sintaxis de escape ODBC
    # (`{CALL …}`), que el driver traduce a lo que entienda cada motor.
    #
    #   call('SP_DOCS_POR_FECHA', [desde, hasta])
    #
    # El nombre lo califica el dialecto con la base y el esquema configurados, así
    # que acá se pasa pelado — es lo que hace que la misma llamada sirva contra
    # `[CL_DOCS].[dbo].[SP]` y contra `CL_DOCS.SP`.
    #
    # ⚠️ El guard de solo-lectura NO aplica: desde acá no hay forma de saber si el
    # procedimiento lee o escribe. Que sea de lectura lo tienen que garantizar los
    # permisos del usuario de base de datos (ver `StatementGuard`).
    def call(procedure, binds = [])
      unless procedure.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        # El nombre se intercala en el texto de la sentencia —un identificador no
        # puede ir como parámetro—, así que se acota a lo que un identificador
        # puede ser. Sin esto, un nombre armado con datos de entrada sería una
        # inyección por la puerta de atrás.
        raise QueryError,
              "El nombre de procedimiento #{procedure.inspect} no es un " \
              'identificador válido.'
      end

      run(dialect.call_statement(procedure, binds.size), binds)
    end

    private

    # Ejecuta y materializa el resultado. La sentencia se cierra siempre y la
    # transacción se revierte siempre — ver el comentario del `ensure`.
    def run(sql, binds)
      connect unless connected?

      statement = nil
      started   = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        statement = @db.prepare(sql)
        statement.execute(*binds)

        rows = collect(statement)
        log_query(sql, binds, rows.size, started)
        rows
      rescue ODBC::Error => e
        raise QueryError,
              "La base de documentos rechazó la consulta: #{sanitize(e.message)}"
      ensure
        begin
          statement&.drop
        rescue ODBC::Error => e
          Rails.logger.warn("[ExternalDb] no se pudo liberar la sentencia: #{sanitize(e.message)}")
        end

        # `autocommit` está en `false` y acá NUNCA se hace commit: si una
        # sentencia llegó a modificar algo —un procedimiento con un UPDATE
        # adentro, un `WITH … DELETE` que el guard no atrapó— el rollback lo
        # deshace. Es la única defensa técnica real que queda del lado de la app,
        # y no cubre a un procedimiento que haga su propio commit.
        rollback_quietly
      end
    end

    # `fetch_hash` devuelve la fila con las columnas como llaves. Se materializa
    # acá y no se devuelve el cursor, para que la conexión pueda volver al pool
    # sin que nadie siga leyendo de ella.
    def collect(statement)
      rows = []

      while (row = statement.fetch_hash)
        rows << row
        break if rows.size >= Config::MAX_ROWS
      end

      if rows.size >= Config::MAX_ROWS
        # Se avisa en vez de levantar: el tope existe para proteger la memoria del
        # proceso, y cortar el resultado sin decir nada haría que un reporte
        # incompleto pase por completo.
        Rails.logger.warn(
          "[ExternalDb] la consulta alcanzó el tope de #{Config::MAX_ROWS} filas; " \
          'el resultado está truncado. Use select_page para paginar.'
        )
      end

      rows
    end

    def apply_session_options!
      # Sin autocommit: habilita el rollback del `ensure` de `#run`.
      @db.autocommit = false

      # Tope de tiempo de la consulta. Sin esto, una consulta colgada retiene la
      # conexión del pool indefinidamente y termina bloqueando a los demás hilos.
      @db.timeout = config.query_timeout

      # Tope de filas del lado del driver, como segundo freno además del de
      # `#collect`.
      @db.maxrows = Config::MAX_ROWS
    rescue ODBC::Error => e
      # Ninguna de las tres es indispensable para consultar, y hay drivers que
      # rechazan alguna. Se registra y se sigue: quedarse sin conexión por no
      # poder fijar un timeout sería peor.
      Rails.logger.warn("[ExternalDb] no se pudieron fijar las opciones de sesión: #{sanitize(e.message)}")
    end

    def rollback_quietly
      @db&.rollback
    rescue ODBC::Error
      # Un driver sin transacciones (o una conexión ya cerrada) levanta acá. No
      # hay nada que hacer y no es un error del llamador.
      nil
    end

    # ⚠️ La consulta se loguea SIN los valores. Los parámetros son datos del
    # negocio y pueden ser identificaciones o montos: el log no es el lugar. Se
    # registra cuántos hubo, que es lo que sirve para diagnosticar.
    def log_query(sql, binds, row_count, started)
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      Rails.logger.info(
        "[ExternalDb] #{config.engine} #{elapsed}ms #{row_count} filas " \
        "#{binds.size} parámetros — #{StatementGuard.preview(sql, limit: 120)}"
      )
    end

    # Deja del mensaje del driver la parte que le sirve al operador.
    #
    # Un error de ODBC viene como
    # `[unixODBC][Microsoft][ODBC Driver 17 for SQL Server]Login failed for user 'x'.`
    # — los corchetes son la cadena de capas que lo reportó y no aportan nada.
    # Se recorta también el largo porque estos mensajes terminan en respuestas
    # HTTP.
    def sanitize(message)
      cleaned = message.to_s.gsub(/\[[^\]]+\]/, '').squeeze(' ').strip

      # Última red por si la contraseña se filtró en el texto del error: si el
      # driver hizo eco de la cadena de conexión, se tapa.
      cleaned = cleaned.gsub(config.password, '***') if config.password.present?

      cleaned.length > 300 ? "#{cleaned[0, 300]}…" : cleaned
    end
  end
end

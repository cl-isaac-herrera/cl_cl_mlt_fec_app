# frozen_string_literal: true

module ExternalDb
  module Dialect
    # SQL Server vía "ODBC Driver 17/18 for SQL Server".
    #
    # Cadena de conexión, tal como se arma en las instalaciones:
    #
    #   Driver={ODBC Driver 17 for SQL Server};Server=CLSQL01;Database=CL_DOCS;UID=…;PWD=…
    #
    # Dos detalles que NO son los de HANA:
    #
    #   · El puerto va con COMA (`Server=CLSQL01,1433`), no con dos puntos. Con
    #     dos puntos el driver lo interpreta como parte del nombre de instancia y
    #     falla con "server not found". Casi nunca hace falta: sin puerto el
    #     driver usa 1433, y una instancia nombrada se escribe `CLSQL01\INSTANCIA`
    #     en el ajuste SERVER.
    #
    #   · `Database` SÍ va en la cadena y fija el catálogo por defecto de la
    #     sesión, así que las consultas pueden ir sin calificar.
    class SqlServer < Base
      # Esquema por defecto. En SQL Server los objetos viven en un esquema y el de
      # SAP y el de la mayoría de las bases es `dbo`; sin él, `[CL_DOCS].[SP]`
      # es una calificación inválida (base + objeto, sin esquema en medio).
      DEFAULT_SCHEMA = 'dbo'

      # ── Autenticación integrada ─────────────────────────────────────────────
      # Con `Trusted_Connection=Yes` el driver se autentica con la identidad de
      # Windows del proceso e **ignora `UID`/`PWD`**. Se omiten en vez de
      # mandarlos igual: dejarlos daba una cadena que dice una cosa y hace otra,
      # y era lo que hacía creer que un `Login failed` era la contraseña cuando
      # en realidad esas credenciales nunca se usaron.
      def connection_string
        with_extra(
          build_dsn(
            'Driver'             => config.driver,
            'Server'             => server_with_port,
            'Database'           => config.database,
            'Trusted_Connection' => (config.trusted? ? 'Yes' : nil),
            'UID'                => (config.trusted? ? nil : config.user),
            'PWD'                => (config.trusted? ? nil : config.password)
          )
        )
      end

      # SQL Server invoca procedimientos con `EXEC`, y los parámetros van
      # separados por coma y SIN paréntesis:
      #
      #   EXEC [CL_DOCS].[dbo].[SP_DOCS] ?, ?
      #   EXEC [CL_DOCS].[dbo].[SP_DOCS]        ← sin parámetros
      #
      # `CALL` es de SAP HANA y acá no compila. El escape ODBC `{CALL …}` que
      # había antes es traducible por el driver, pero su lista de argumentos se
      # comporta distinto según la versión: con `()` vacío el driver `SQL Server`
      # la interpreta como una lista presente y rechaza la llamada con
      # "Procedure … has no parameters and arguments were supplied" — un mensaje
      # que miente, porque no se envió ninguno. Con la sintaxis nativa de cada
      # motor no hay traducción de por medio ni ese margen de interpretación.
      def call_statement(procedure, arity)
        statement = "EXEC #{qualify(procedure)}"
        return statement if arity.to_i.zero?

        "#{statement} #{Array.new(arity, '?').join(', ')}"
      end

      # Corchetes, y se duplica el `]` de cierre — es el escape de SQL Server.
      def quote_ident(name)
        "[#{name.to_s.gsub(']', ']]')}]"
      end

      # `SELECT 1` a secas es válido acá: SQL Server no exige un `FROM`.
      def probe_sql
        'SELECT 1'
      end

      def version_sql
        'SELECT @@VERSION'
      end

      # `OFFSET … FETCH NEXT` (SQL Server 2012+). Exige `ORDER BY`: sin él la
      # sintaxis no compila, y además una página sin orden determinista puede
      # repetir o saltarse filas entre llamadas. Por eso el `ORDER BY` es
      # responsabilidad de quien escribe el `SELECT` y acá solo se verifica.
      def paginate(sql, limit:, offset:)
        unless sql.match?(/\bORDER\s+BY\b/i)
          raise QueryError,
                'La consulta paginada necesita ORDER BY: en SQL Server, ' \
                'OFFSET/FETCH no compila sin él, y sin un orden determinista ' \
                'las páginas pueden repetir u omitir filas.'
        end

        "#{sql.strip.chomp(';')} OFFSET #{offset.to_i} ROWS " \
          "FETCH NEXT #{limit.to_i} ROWS ONLY"
      end

      private

      # Base y esquema. El esquema cae en `dbo` cuando no está configurado, que
      # es lo que resuelve el 99% de los casos.
      def qualifier_parts
        [config.database, config.schema || DEFAULT_SCHEMA].compact
      end

      # Coma, no dos puntos. Ver el encabezado de la clase.
      def server_with_port
        config.port ? "#{config.server},#{config.port}" : config.server
      end
    end
  end
end

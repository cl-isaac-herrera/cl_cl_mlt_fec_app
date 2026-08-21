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

      def connection_string
        with_extra(
          build_dsn(
            'Driver'   => config.driver,
            'Server'   => server_with_port,
            'Database' => config.database,
            'UID'      => config.user,
            'PWD'      => config.password
          )
        )
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

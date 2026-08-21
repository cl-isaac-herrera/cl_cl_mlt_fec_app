# frozen_string_literal: true

module ExternalDb
  module Dialect
    # SAP HANA vía "HDBODBC" (el driver que instala el cliente de SAP).
    #
    # Cadena de conexión, tal como se arma en las instalaciones:
    #
    #   Driver={HDBODBC};SERVERNODE=clhna721:30015;UID=…;PWD=…
    #
    # Tres diferencias con SQL Server, y las tres importan:
    #
    #   · `SERVERNODE=host:puerto`, con DOS PUNTOS, y el puerto es OBLIGATORIO —
    #     no hay un valor implícito como el 1433. Es el puerto SQL de la
    #     instancia: `3<NN>15`, o sea 30015 para la instancia 00, 30115 para la
    #     01. `Config` lo exige justamente por esto.
    #
    #   · La base NO va en la cadena de conexión. Es la práctica de las
    #     instalaciones vivas: el código de base califica cada objeto de cada
    #     consulta (`CALL <db-code>.SP1`), y la sesión se abre sin catálogo por
    #     defecto. Un `DATABASENAME=` solo hace falta en un HANA multi-tenant
    #     (MDC) para elegir el tenant, y para ese caso está EXTRA_PARAMS.
    #
    #   · El código de base ES el esquema. En SQL Server hay base y esquema
    #     (`[CL_DOCS].[dbo].[SP]`); en HANA la calificación es de un solo tramo
    #     (`CL_DOCS.SP`), y ese tramo es el que en SAP se llama "código de base".
    class Hana < Base
      # Identificador que HANA resuelve bien SIN comillas. Acepta minúsculas a
      # propósito: al emitirlo desnudo, HANA lo pasa a mayúsculas y termina
      # apuntando al mismo objeto, que es exactamente el comportamiento que hoy
      # tienen las consultas escritas a mano.
      SAFE_IDENT_UNQUOTED = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def connection_string
        with_extra(
          build_dsn(
            'Driver'     => config.driver,
            'SERVERNODE' => "#{config.server}:#{config.port}",
            'UID'        => config.user,
            'PWD'        => config.password
          )
        )
      end

      # Entrecomillado deliberadamente conservador, para no romper lo que hoy
      # funciona.
      #
      # HANA pasa a MAYÚSCULAS todo identificador sin comillas, y respeta la caja
      # exacta de uno entrecomillado. Como las instalaciones escriben
      # `CALL <db-code>.SP1` SIN comillas, el objeto real en la base tiene el
      # nombre en mayúsculas. Entrecomillar tal cual lo que escribió el operador
      # rompería la consulta el día que teclee el código de base en minúscula:
      # `"cl_docs"` no existe, `CL_DOCS` sí.
      #
      # Entonces: si el nombre ya es seguro sin comillas se emite DESNUDO y HANA
      # lo normaliza como siempre; solo se entrecomilla —y ahí sí con la caja
      # exacta— cuando el nombre tiene algo que lo exige (espacios, guiones,
      # minúsculas que hay que preservar a propósito).
      def quote_ident(name)
        str = name.to_s

        # Nombre corriente: se emite DESNUDO y en mayúsculas. HANA lo pasaría a
        # mayúsculas igual; hacerlo explícito deja el SQL generado legible y
        # coincidiendo con el nombre real del objeto en el catálogo.
        return str.upcase if str.match?(SAFE_IDENT_UNQUOTED)

        # Cualquier otra cosa (espacios, guiones, minúsculas a preservar) exige
        # comillas, y ahí la caja se respeta tal como la escribió el operador.
        %("#{str.gsub('"', '""')}")
      end

      # HANA exige un `FROM` en todo `SELECT`. `DUMMY` es la tabla de una sola
      # fila que existe para esto — el equivalente de `dual` en Oracle. Un
      # `SELECT 1` a secas, que en SQL Server es válido, acá es un error de
      # sintaxis.
      def probe_sql
        'SELECT 1 FROM DUMMY'
      end

      def version_sql
        'SELECT VERSION FROM M_DATABASE'
      end

      # `LIMIT … OFFSET …`, como PostgreSQL y MySQL. Sin la exigencia de
      # `ORDER BY` que tiene SQL Server: acá la sintaxis compila sin él.
      #
      # Se advierte igual en el log, porque el otro motivo del `ORDER BY` sigue
      # vigente en los dos motores — sin orden determinista, dos páginas
      # consecutivas pueden repetir u omitir filas.
      def paginate(sql, limit:, offset:)
        unless sql.match?(/\bORDER\s+BY\b/i)
          Rails.logger.warn(
            '[ExternalDb::Dialect::Hana] consulta paginada sin ORDER BY: las ' \
            'páginas pueden repetir u omitir filas.'
          )
        end

        "#{sql.strip.chomp(';')} LIMIT #{limit.to_i} OFFSET #{offset.to_i}"
      end

      private

      # Un solo tramo: el código de base ES el esquema. `SCHEMA` gana si está
      # configurado, para el caso en que los objetos vivan en un esquema distinto
      # del que da nombre a la base.
      def qualifier_parts
        [config.schema || config.database].compact
      end
    end
  end
end

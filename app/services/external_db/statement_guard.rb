# frozen_string_literal: true

module ExternalDb
  # Rechaza sentencias que no sean de lectura antes de mandarlas al driver.
  #
  # ---------------------------------------------------------------------------
  # ⚠️ ESTO NO ES LA GARANTÍA DE SOLO-LECTURA. Es una red, no una barrera.
  #
  # Hay que decirlo claro porque es fácil confiar de más en este archivo:
  #
  #   1. `ruby-odbc` NO expone `SQL_ATTR_ACCESS_MODE` (verificado: la gema define
  #      `SQL_AUTOCOMMIT` pero ninguna constante de access mode), así que la
  #      conexión no se puede abrir en modo lectura. Y aunque se pudiera, el
  #      atributo es una sugerencia que la mayoría de los drivers ignora.
  #
  #   2. `WITH` puede llevar DML. En SQL Server,
  #      `WITH c AS (SELECT…) DELETE FROM c` es válido, y empieza con `WITH`.
  #
  #   3. Un procedimiento almacenado hace lo que quiera. `#call` invoca
  #      procedimientos —es el patrón de estas instalaciones (`CALL <db>.SP1`)— y
  #      desde acá no hay forma de saber si el procedimiento lee o escribe.
  #
  # LA GARANTÍA REAL ES EL USUARIO DE BASE DE DATOS. El que se configure en
  # `DOCS_DB_ODBC_USER` tiene que tener permisos de LECTURA Y NADA MÁS
  # (`db_datareader` en SQL Server; `SELECT` sobre el esquema en HANA). Eso es lo
  # que hay que verificar al desplegar, y está en `docs/CONSULTA-BASE-EXTERNA.md`.
  #
  # Lo que este guard sí aporta: agarra el error honesto —alguien que escribe un
  # `UPDATE` en donde va un `SELECT`— en el momento en que se escribe y no en
  # producción, y deja el intento en el log.
  # ---------------------------------------------------------------------------
  module StatementGuard
    # Solo `SELECT` y `WITH` pueden abrir una sentencia ad hoc.
    READ_PREFIX = /\A(SELECT|WITH)\b/i

    # Verbos que no tienen nada que hacer en una consulta de lectura. Se buscan
    # como palabra completa en cualquier posición, para agarrar el `WITH … DELETE`
    # del punto 2 de arriba.
    WRITE_VERBS = /\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|DROP|CREATE|ALTER|
                      GRANT|REVOKE|EXEC|EXECUTE|BACKUP|RESTORE|SHUTDOWN)\b/ix

    module_function

    # Levanta `ReadOnlyViolation` si la sentencia no es de lectura.
    def assert_read_only!(sql)
      statement = sql.to_s

      if statement.strip.empty?
        raise ReadOnlyViolation, 'La consulta está vacía.'
      end

      unless statement.strip.match?(READ_PREFIX)
        raise ReadOnlyViolation,
              'El conector es de solo lectura: la consulta tiene que empezar ' \
              "con SELECT o WITH. Recibido: #{preview(statement)}"
      end

      assert_single_statement!(statement)
      assert_no_write_verbs!(statement)
    end

    # Un solo `;` final se tolera; cualquier otro es una segunda sentencia.
    #
    # Chequeo textual, con su falso positivo asumido: un `;` dentro de un literal
    # de cadena (`WHERE nombre = 'a;b'`) se rechaza aunque sea legítimo. Se
    # prefiere así porque los valores viajan como parámetros (`?`) y no como
    # literales — un literal con `;` en una consulta de este conector es más
    # probable que sea un intento de inyección que un dato.
    def assert_single_statement!(statement)
      return unless statement.strip.chomp(';').include?(';')

      raise ReadOnlyViolation,
            'La consulta no puede llevar más de una sentencia (se encontró un ' \
            '";" en medio). Los valores van como parámetros, no interpolados.'
    end

    def assert_no_write_verbs!(statement)
      # Se buscan los verbos sobre la consulta SIN comentarios ni literales: un
      # `-- borrar despues` o una columna que se llame `UPDATED_BY` no son
      # escrituras, y sin esta limpieza los dos darían falso positivo.
      found = strip_noise(statement).scan(WRITE_VERBS).flatten.uniq

      return if found.empty?

      raise ReadOnlyViolation,
            "El conector es de solo lectura y la consulta contiene " \
            "#{found.map(&:upcase).join(', ')}. Para invocar un procedimiento " \
            'almacenado se usa #call, no #select.'
    end

    # Quita comentarios de línea, comentarios de bloque y literales de cadena.
    # Lo que queda es la estructura de la consulta, que es lo único que se
    # inspecciona.
    def strip_noise(statement)
      statement
        .gsub(/--[^\n]*/, ' ')      # -- comentario de línea
        .gsub(%r{/\*.*?\*/}m, ' ')  # /* comentario de bloque */
        .gsub(/'(?:[^']|'')*'/, "''") # 'literal' y 'lite''ral'
    end

    # Recorte para el mensaje de error. Acotado a propósito: el mensaje va al log
    # y puede terminar en una respuesta HTTP, y una consulta completa ahí es
    # ruido —o una filtración, si trae literales.
    def preview(statement, limit: 60)
      flat = statement.to_s.strip.gsub(/\s+/, ' ')
      return flat if flat.length <= limit

      # `rstrip` antes de los puntos suspensivos: si el corte cae justo en un
      # espacio, sin esto queda "SELECT a, b …".
      "#{flat[0, limit].rstrip}…"
    end
  end
end

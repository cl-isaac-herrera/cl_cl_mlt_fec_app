# frozen_string_literal: true

module ExternalDb
  module Dialect
    # Contrato del dialecto. Cada subclase resuelve lo que difiere entre motores:
    # la cadena de conexión, el entrecomillado de identificadores, la
    # calificación de objetos, la paginación y la consulta de sondeo.
    #
    # Los métodos que levantan `NotImplementedError` son el contrato; el resto es
    # comportamiento compartido de verdad.
    class Base
      attr_reader :config

      def initialize(config)
        @config = config
      end

      # ----------------------------------------------------------------
      # Contrato
      # ----------------------------------------------------------------

      # Cadena de conexión ODBC completa, con credenciales.
      #
      # ⚠️ El valor que devuelve lleva la contraseña: no se loguea, no se mete en
      # un mensaje de error y no se guarda en ningún atributo que se serialice.
      def connection_string
        raise NotImplementedError, "#{self.class}#connection_string"
      end

      # Identificador entrecomillado según las reglas del motor.
      def quote_ident(_name)
        raise NotImplementedError, "#{self.class}#quote_ident"
      end

      # Consulta de sondeo — la más barata que confirme que la sesión responde.
      def probe_sql
        raise NotImplementedError, "#{self.class}#probe_sql"
      end

      # `SELECT` que devuelve la versión del motor, para el health check.
      def version_sql
        raise NotImplementedError, "#{self.class}#version_sql"
      end

      # Envuelve un `SELECT` con su límite y desplazamiento.
      def paginate(_sql, limit:, offset:)
        raise NotImplementedError, "#{self.class}#paginate"
      end

      # Llamado a un procedimiento almacenado, con un `?` por parámetro.
      #
      #   SQL Server │ EXEC [CL_DOCS].[dbo].[SP_DOCS] ?, ?
      #   HANA       │ CALL CL_DOCS.SP_DOCS(?, ?)
      #
      # Cada motor tiene su palabra clave y su forma de escribir la lista de
      # argumentos, así que esto es contrato y no comportamiento compartido.
      #
      # ── Por qué ya no se usa el escape ODBC `{CALL …}` ───────────────────────
      # El escape es portable en teoría —el driver manager lo traduce a `EXEC` o
      # a `CALL`— y por eso estaba acá, en la clase base. En la práctica la
      # traducción no es transparente: el driver `SQL Server` lee un `()` vacío
      # como una lista de argumentos presente y rechaza la llamada con
      # "Procedure … has no parameters and arguments were supplied", un mensaje
      # que miente porque no se envió ninguno. Emitir la sintaxis nativa de cada
      # motor quita esa capa de interpretación, y es además lo que `CLAUDE.md`
      # §37 pide: toda diferencia entre motores vive en `dialect/`.
      def call_statement(_procedure, _arity)
        raise NotImplementedError, "#{self.class}#call_statement"
      end

      # ----------------------------------------------------------------
      # Compartido
      # ----------------------------------------------------------------

      # Nombre de objeto calificado con su base y esquema, listo para intercalar
      # en una consulta.
      #
      #   SQL Server │ [CL_DOCS].[dbo].[SP_DOCS]
      #   HANA       │ "CL_DOCS"."SP_DOCS"
      #
      # Los tramos ausentes se omiten: sin `database` configurado, el objeto sale
      # sin calificar y resuelve contra el catálogo/esquema por defecto de la
      # sesión.
      def qualify(object_name)
        qualifier_parts.push(object_name).compact.map { |part| quote_ident(part) }.join('.')
      end

      # Clave cuyo valor va SIEMPRE entre llaves.
      DRIVER_KEY = 'Driver'

      # Cadena ODBC a partir de pares `clave=valor`.
      #
      # Los pares con valor `nil` se omiten (`Hash#compact`): así el dialecto
      # declara `'Database' => config.database` sin preguntar si está configurado.
      #
      # El entrecomillado no es uniforme, y confundirlo cuesta una conexión que no
      # se establece:
      #
      #   · `Driver` va siempre entre llaves. Todos los nombres reales llevan
      #     espacios ("ODBC Driver 17 for SQL Server") y así es como lo documenta
      #     ODBC. El dialecto pasa el nombre PELADO — poner las llaves también allá
      #     produce `Driver={{…}}}`, que el driver manager no resuelve.
      #
      #   · El resto se encierra solo si lo necesita. Importa sobre todo para la
      #     contraseña: una que tenga `;` parte la cadena y los parámetros que
      #     siguen se pierden sin ningún error.
      def build_dsn(pairs)
        pairs.compact.map do |key, value|
          encoded = key == DRIVER_KEY ? brace(value) : escape_dsn_value(value)

          "#{key}=#{encoded}"
        end.join(';')
      end

      private

      # Dentro de las llaves, ODBC solo exige duplicar el `}` de cierre.
      #
      # Concatenación explícita y no interpolación a propósito: la versión
      # interpolada (`"{#{v.gsub('}', '}}')}}"`) necesita DOS `}` finales —uno
      # cierra la interpolación y el otro es el literal— y con uno solo la llave
      # de cierre desaparece sin que nada falle hasta que el driver no resuelve
      # la cadena. Ya pasó una vez.
      def brace(value)
        '{' + value.to_s.gsub('}', '}}') + '}'
      end

      # Tramos que preceden al nombre del objeto. Cada motor decide cuáles.
      def qualifier_parts
        raise NotImplementedError, "#{self.class}#qualifier_parts"
      end

      def escape_dsn_value(value)
        str = value.to_s

        str.match?(/[;{}=]/) ? brace(str) : str
      end

      # Parámetros extra tal como los escribió el operador, para pegarlos al
      # final de la cadena. Sirven para lo que este builder no modela
      # (`Encrypt=yes`, `TrustServerCertificate=yes`, `sslValidateCertificate=false`)
      # sin tener que agregar un ajuste por cada opción de cada driver.
      def extra_pairs
        config.extra_params
      end

      # Une la cadena armada con los parámetros extra.
      def with_extra(dsn)
        extra_pairs.present? ? "#{dsn};#{extra_pairs.delete_prefix(';').chomp(';')}" : dsn
      end
    end
  end
end

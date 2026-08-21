# frozen_string_literal: true

module ExternalDb
  # Pool de conexiones ODBC por grupo de settings.
  #
  #   ExternalDb::Pool.with('DOCS_DB_ODBC') do |client|
  #     client.select('SELECT … FROM … WHERE … = ?', [valor])
  #   end
  #
  # Abrir una conexión ODBC no es gratis —hay handshake, autenticación y, en
  # HANA, negociación de la sesión—, y Puma corre varios hilos: sin pool, cada
  # request pagaría eso de nuevo. El pool las reutiliza y las devuelve al bloque
  # siguiente.
  #
  # ---------------------------------------------------------------------------
  # La configuración puede cambiar mientras la app corre
  #
  # Es la diferencia con un pool de config estática. El operador edita
  # `DOCS_DB_ODBC_SERVER` desde la pantalla y las conexiones que ya están abiertas
  # apuntan al servidor anterior — seguirían funcionando y nadie notaría que el
  # cambio no tuvo efecto hasta reiniciar.
  #
  # Por eso el pool se indexa por `Config#fingerprint` (que incluye la
  # contraseña): cuando cambia cualquier ajuste del grupo, el fingerprint cambia,
  # se arma un pool nuevo y el viejo se cierra con `shutdown` — que desconecta
  # cada conexión en vez de dejarlas colgadas del lado del servidor de base.
  # ---------------------------------------------------------------------------
  module Pool
    # Conexiones simultáneas por destino. Cinco es el default de `RAILS_MAX_THREADS`
    # en `config/database.yml`: más que hilos no aporta, y cada conexión ODBC
    # ocupa una sesión (y en SAP, potencialmente una licencia) del lado del
    # servidor.
    DEFAULT_SIZE = 5

    # Segundos que un hilo espera por una conexión libre antes de levantar. Corto
    # a propósito: si todas están ocupadas, es mejor devolver un error que dejar
    # el request colgado.
    CHECKOUT_TIMEOUT = 10

    @pools = {}
    @mutex = Mutex.new

    class << self
      # Entrega un cliente conectado al bloque y lo devuelve al pool al salir.
      #
      # El `Config` se resuelve en cada llamada: es un SELECT sobre un índice
      # único y es lo que permite notar que la configuración cambió. Lo que NO se
      # rearma en cada llamada es la conexión.
      def with(group_code, &block)
        config = Config.load(group_code)

        pool_for(config).with(&block)
      rescue ConnectionPool::TimeoutError
        raise ConnectionError,
              'Todas las conexiones a la base de documentos están ocupadas. ' \
              'Intente de nuevo en unos segundos.'
      end

      # Cierra todas las conexiones de todos los destinos. La llama el
      # `at_exit`/`before_fork` del servidor y los tests.
      def shutdown!
        @mutex.synchronize do
          @pools.each_value { |pool| discard(pool) }
          @pools.clear
        end
      end

      # Estado del pool, para diagnóstico. Sin credenciales: el fingerprint es un
      # hash y `Config#to_s` no incluye usuario ni contraseña.
      def stats
        @mutex.synchronize do
          @pools.transform_values do |pool|
            { size: pool.size, available: pool.available }
          end
        end
      end

      private

      # Un pool por fingerprint. Si el grupo ya tenía uno con otro fingerprint,
      # se cierra antes de reemplazarlo — es el caso "el operador cambió el
      # servidor".
      def pool_for(config)
        fingerprint = config.fingerprint

        @mutex.synchronize do
          existing = @pools[config.group_code]
          return existing[:pool] if existing && existing[:fingerprint] == fingerprint

          if existing
            Rails.logger.info(
              "[ExternalDb::Pool] la configuración de #{config.group_code} cambió; " \
              'se cierran las conexiones anteriores.'
            )
            discard(existing[:pool])
          end

          pool = build_pool(config)
          @pools[config.group_code] = { fingerprint: fingerprint, pool: pool }
          pool
        end
      end

      def build_pool(config)
        ConnectionPool.new(size: DEFAULT_SIZE, timeout: CHECKOUT_TIMEOUT) do
          # El bloque corre perezosamente, la primera vez que un hilo pide una
          # conexión — no al armar el pool. Así crear el pool no falla si el
          # servidor de base está caído; falla la consulta, que es donde el error
          # tiene contexto.
          Client.new(config).connect
        end
      end

      def discard(entry)
        pool = entry.is_a?(Hash) ? entry[:pool] : entry

        pool.shutdown(&:close)
      rescue StandardError => e
        Rails.logger.warn("[ExternalDb::Pool] error al cerrar el pool: #{e.message}")
      end
    end
  end
end

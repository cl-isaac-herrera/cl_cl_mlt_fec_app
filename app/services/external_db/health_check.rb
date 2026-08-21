# frozen_string_literal: true

module ExternalDb
  # Verifica que el destino ODBC responda, y devuelve por qué no cuando no.
  #
  #   ExternalDb::HealthCheck.call('DOCS_DB_ODBC')
  #   # => #<Result ok=true engine="HANA" version="2.00.075…" latency_ms=42>
  #
  # Es lo primero que hay que correr después de configurar el grupo de settings, y
  # es lo que va a alimentar el botón "Probar conexión" de la pantalla cuando se
  # migre la UI.
  #
  # NUNCA levanta: los cuatro modos de falla —falta un ajuste, el driver no está,
  # el servidor no responde, las credenciales son malas— terminan en un `Result`
  # con `ok: false` y un mensaje en español, porque para el operador todos
  # significan lo mismo ("no se pudo") y lo que necesita es el motivo. Mismo
  # criterio que `Sap::CredentialValidator`.
  class HealthCheck
    Result = Struct.new(:ok, :engine, :version, :latency_ms, :message, keyword_init: true) do
      def ok? = ok
    end

    class << self
      def call(group_code)
        new(group_code).call
      end
    end

    def initialize(group_code)
      @group_code = group_code
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Pool.with(@group_code) do |client|
        # Dos sentencias: la de sondeo confirma que la sesión responde, la de
        # versión confirma que además se puede leer del catálogo del sistema. La
        # segunda es la que falla cuando el usuario conectó pero no tiene
        # permisos, que es un caso que el sondeo solo no distingue.
        client.select(client.dialect.probe_sql)
        version = client.select_value(client.dialect.version_sql)

        Result.new(
          ok:         true,
          engine:     client.config.engine,
          version:    version.to_s.lines.first.to_s.strip.presence,
          latency_ms: elapsed_ms(started),
          message:    'La conexión a la base de documentos responde.'
        )
      end
    rescue Error => e
      # `ExternalDb::Error` cubre los cuatro modos de falla del conector, y su
      # mensaje ya está redactado para el operador.
      failure(e.message, started)
    rescue StandardError => e
      # Cualquier otra cosa es inesperada: al operador se le da un mensaje
      # genérico y el detalle queda en el log, que es donde sirve.
      Rails.logger.error("[ExternalDb::HealthCheck] #{e.class}: #{e.message}")
      failure('No se pudo verificar la conexión a la base de documentos.', started)
    end

    private

    def failure(message, started)
      Result.new(ok: false, engine: nil, version: nil,
                 latency_ms: elapsed_ms(started), message: message)
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
  end
end

# frozen_string_literal: true

module ExternalDb
  # Resolución del dialecto según el motor.
  #
  # Todo lo que difiere entre SQL Server y HANA vive en una subclase de
  # `Dialect::Base` y en ningún otro lado. Si aparece un `if config.hana?` fuera
  # de `app/services/external_db/dialect/`, es que la diferencia se escapó de
  # acá y hay que moverla.
  module Dialect
    module_function

    def for(config)
      case config.engine
      when 'SQL'  then SqlServer.new(config)
      when 'HANA' then Hana.new(config)
      else
        # Inalcanzable vía `Config`, que ya valida el motor. Está para que un
        # `Dialect.for` con un config armado a mano en un test falle diciendo qué
        # pasa, en vez de devolver `nil` y estallar tres capas más arriba.
        raise ConfigurationError, "No hay dialecto para el motor #{config.engine.inspect}."
      end
    end
  end
end

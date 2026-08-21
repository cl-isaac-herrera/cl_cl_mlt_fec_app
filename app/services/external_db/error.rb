# frozen_string_literal: true

module ExternalDb
  # Base de los errores del conector ODBC. Se rescata de una sola vez para
  # cubrir los cuatro modos de falla; las subclases viven cada una en su archivo
  # —lo exige Zeitwerk, que resuelve una constante por archivo— y distinguen de
  # quién es la culpa, que es lo que decide el status HTTP y si el mensaje se le
  # puede mostrar al usuario.
  #
  #   ConfigurationError │ falta o está mal un ajuste  → 422, mensaje al usuario
  #   ConnectionError    │ no se pudo llegar al server → 502, mensaje al usuario
  #   QueryError         │ la base rechazó la consulta → 502, mensaje al usuario
  #   ReadOnlyViolation  │ error de programación       → 500, NO se muestra
  Error = Class.new(StandardError)
end

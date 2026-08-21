# frozen_string_literal: true

module ExternalDb
  # Falta un ajuste del grupo, o tiene un valor que no sirve (motor desconocido,
  # puerto fuera de rango, driver no instalado).
  #
  # Lo puede corregir el operador desde Configuraciones → Generales, así que el
  # mensaje se le muestra y nombra el `code` exacto que hay que llenar.
  ConfigurationError = Class.new(Error)
end

# frozen_string_literal: true

module ExternalDb
  # No se pudo establecer la conexión: el servidor no responde, las credenciales
  # son malas, el driver no cargó, o el pool está saturado.
  #
  # No es culpa de quien consulta, así que el mensaje se le muestra —ya limpio de
  # los corchetes que agrega el driver manager (`Client#sanitize`)— para que sepa
  # si tiene que avisar a infraestructura o revisar la configuración.
  ConnectionError = Class.new(Error)
end

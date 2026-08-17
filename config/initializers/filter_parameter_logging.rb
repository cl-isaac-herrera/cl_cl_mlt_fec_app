# frozen_string_literal: true

# Parámetros que NUNCA deben aparecer en los logs.
#
# Sin este archivo el log escribía la contraseña de SAP en claro en cada request:
#
#   Parameters: {"SapUser"=>"CLAVISCO\\cl.isaac.herrera", "SapPass"=>"@Moises2390h76", ...}
#
# De poco sirve cifrar la columna si el mismo valor queda en texto plano en
# `log/development.log` y en el agregador de logs de producción.
#
# El match es por substring y sin distinguir mayúsculas, así que `sappass` cubre
# tanto `SapPass` (el cuerpo que manda la pantalla) como `sap_password` (el
# atributo del modelo) y su copia anidada que agrega ParamsWrapper.
Rails.application.config.filter_parameters += %i[
  passw secret token _key crypt salt certificate otp ssn
  sappass sap_password cert_pin
]

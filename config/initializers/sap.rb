# frozen_string_literal: true

# ---------------------------------------------------------------
# SAP Service Layer
#
# La app no integra SAP para operar documentos: el único llamado que hace es
# `POST /Login` para validar las credenciales que el usuario guarda en su perfil
# (ver Sap::CredentialValidator). La URL del Service Layer no vive acá — es por
# compañía y sale de `connections.service_layer_url`.
# ---------------------------------------------------------------

# Muchas instalaciones de Service Layer usan certificados autofirmados. Poner
# SAP_SL_VERIFY_SSL=false solo cuando el certificado del servidor no sea verificable.
Rails.application.config.sap_sl_verify_ssl = ENV.fetch('SAP_SL_VERIFY_SSL', 'true') != 'false'

# Segundos. El /Login del Service Layer es lento cuando la licencia está saturada;
# aun así la pantalla espera la respuesta, así que no conviene subirlo mucho.
Rails.application.config.sap_sl_open_timeout = ENV.fetch('SAP_SL_OPEN_TIMEOUT', '10').to_i
Rails.application.config.sap_sl_timeout      = ENV.fetch('SAP_SL_TIMEOUT', '30').to_i

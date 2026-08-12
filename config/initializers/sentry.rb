# frozen_string_literal: true

# Error tracking (CLAVISCO-PLATFORM-STANDARDS §10).
#
# El DSN sale del entorno y NO tiene valor por defecto: §1.5 prohíbe el fallback
# hardcodeado ("si la variable falta, debe fallar explícitamente, nunca caer en
# un secreto de repuesto"). Acá venía un DSN real embebido, que además violaba la
# regla de §10 de un DSN por deployment/cliente — todos los ambientes reportaban
# al mismo proyecto de Sentry.
#
# Sin `SENTRY_DSN`, el SDK queda inerte: no envía nada y no rompe el arranque.
# El middleware `ErrorHandler` de `cl-common` (registrado en config/application.rb)
# llama `Sentry.capture_exception` solo si hay DSN configurado.
Sentry.init do |config|
  config.dsn         = ENV['SENTRY_DSN']
  config.environment = Rails.env
  config.release     = "#{Rails.application.class.module_parent_name.underscore.dasherize}@#{Rails.env}"

  config.breadcrumbs_logger = %i[active_support_logger http_logger]

  config.sample_rate        = 1.0  # errores: enviar el 100%
  config.traces_sample_rate = 0.1  # APM: 10% de transacciones (ajustar por volumen)

  # send_default_pii quedaba en true: mandaba a Sentry cabeceras, cookies y cuerpo
  # de cada request con error. Es justo lo que `filter_parameter_logging.rb` evita
  # en los logs propios — no tiene sentido cerrarlo de un lado y abrirlo del otro.
  config.send_default_pii = false
end

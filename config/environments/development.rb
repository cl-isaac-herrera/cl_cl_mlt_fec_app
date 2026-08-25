# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true

  # Caché en memoria en desarrollo
  config.cache_store = :memory_store

  # Mismo adaptador de jobs que producción, a propósito. El default de Rails en
  # desarrollo (`:async`) corre el job en un thread del propio Puma: ve las mismas
  # variables de proceso y la misma conexión, así que esconde justo la clase de bug
  # que solo aparece cuando el job corre aparte — típicamente algo que dependía de
  # `Current.user` / `Current.company_id`, que en el worker no existen.
  #
  # `connects_to` tiene que estar acá y no en un initializer: `SolidQueue::Record` lo
  # lee al DEFINIR la clase, y para entonces los initializers todavía no corrieron.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
  config.public_file_server.headers = { 'cache-control' => "public, max-age=#{2.days.to_i}" }

  # Logs detallados
  config.log_level = :debug
  config.log_tags = [:request_id]

  # Assets
  config.assets.debug = true
  config.assets.quiet = true

  # Raises en lugar de 404 para rutas faltantes
  config.action_controller.raise_on_missing_callback_actions = true

  # Detección de N+1 en tiempo real (CLAVISCO-PLATFORM-STANDARDS §1.6). Avisa en
  # el log y en la consola del navegador dónde ocurre; no rompe la request.
  # `raise` queda en false a propósito: el objetivo es enterarse mientras se
  # desarrolla, no frenar a quien está probando otra cosa.
  config.after_initialize do
    Bullet.enable        = true
    Bullet.rails_logger  = true
    Bullet.console       = true
    Bullet.add_footer    = true
    Bullet.raise         = false
  end
end

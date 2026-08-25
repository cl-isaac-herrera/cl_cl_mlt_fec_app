# frozen_string_literal: true

# Ajustes del runtime de Solid Queue.
#
# Ojo con el reparto: lo que se puede configurar acá es el COMPORTAMIENTO
# (retención, manejo de errores). La conexión a la base (`connects_to`) NO puede vivir
# en un initializer: `SolidQueue::Record` la lee al definir la clase, antes de que esto
# corra. Por eso está en cada `config/environments/*.rb`.
Rails.application.configure do
  # Cuánto sobrevive un job terminado antes de que la tarea de limpieza de
  # `config/recurring.yml` lo borre. Un día alcanza para revisar qué pasó ayer sin dejar
  # la tabla creciendo para siempre.
  config.solid_queue.clear_finished_jobs_after = 1.day

  # Una excepción dentro de un thread del worker no pasa por el middleware `ErrorHandler`
  # que registra `config/application.rb`: ese middleware es de la pila HTTP y en un job
  # no hay request. Sin este hook el error se quedaría solo en el log del worker.
  #
  # El default de la gema es `Rails.error.report`; se reemplaza por la llamada directa a
  # Sentry para que quede explícito de dónde sale el reporte. Si `SENTRY_DSN` no está
  # configurado el SDK queda inerte y esto no hace nada, igual que en el resto de la app.
  config.solid_queue.on_thread_error = ->(exception) { Sentry.capture_exception(exception) }
end

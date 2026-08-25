# frozen_string_literal: true

# Este archivo no existía: Puma venía corriendo con sus propios defaults. Se crea porque
# el plugin de Solid Queue solo se puede declarar acá.

threads_count = ENV.fetch('RAILS_MAX_THREADS') { 3 }.to_i
threads threads_count, threads_count

port         ENV.fetch('PORT') { 3000 }
environment  ENV.fetch('RAILS_ENV') { 'development' }

plugin :tmp_restart

# ── Solid Queue dentro del proceso de Puma ──────────────────────────────────────
#
# En Windows esta es la ÚNICA forma de correr el worker, y no es una preferencia:
#
#   1. `bin/jobs` arranca el Supervisor en modo *standalone*, que registra handlers para
#      QUIT, INT y TERM (`SolidQueue::Supervisor::Signals::SIGNALS`). Ruby en Windows no
#      conoce SIGQUIT — `Signal.list` devuelve solo ABRT, EXIT, FPE, ILL, INT, KILL,
#      SEGV, TERM — así que el `trap(:QUIT)` levanta `ArgumentError: unsupported signal`
#      y el proceso muere antes de procesar un solo job. Verificado con solid_queue 1.4.0.
#      `standalone` es la bandera que salta ese registro, y la CLI no la expone.
#
#   2. El modo por defecto del Supervisor es `fork`, y `Process.fork` tampoco existe en
#      Windows.
#
# El plugin en modo `:async` esquiva las dos cosas: arranca el Supervisor con
# `standalone: false` (sin señales) y corre workers, dispatcher y scheduler como THREADS
# de este mismo proceso, sin forkear.
#
# El precio de que vaya adentro de Puma: los jobs comparten memoria y GVL con las
# requests, y reiniciar el web reinicia la cola. Es aceptable para una instalación por
# cliente, no para un servidor con carga alta de jobs.
#
# En Linux esto NO hace falta: ahí `bin/jobs` corre como proceso aparte, que es lo
# preferible. Por eso el interruptor se enciende solo en Windows y se puede forzar en
# cualquier plataforma con SOLID_QUEUE_IN_PUMA.
run_jobs_in_puma = ENV.fetch('SOLID_QUEUE_IN_PUMA') { Gem.win_platform? ? 'true' : 'false' } == 'true'

if run_jobs_in_puma
  plugin :solid_queue
  solid_queue_mode :async
end

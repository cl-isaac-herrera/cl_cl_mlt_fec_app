# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

# Este archivo no existía. Rails no se queja cuando falta —solo carga los archivos de
# entorno que encuentra— así que los specs venían corriendo con los defaults de
# `load_defaults 8.0` y sin ningún lugar donde fijar configuración de test.
#
# Se crea con lo mínimo: el adaptador de jobs. Nada más, para no cambiar en silencio el
# comportamiento de los specs que ya pasaban.
Rails.application.configure do
  # Llaves de ActiveRecord::Encryption con valores LITERALES y sin valor real
  # (CLAVISCO-PLATFORM-STANDARDS.md §8.1, excepción para test): la suite no
  # puede depender de tener RAILS_MASTER_KEY disponible, porque el job de CI
  # que corre los tests no lo recibe (§11.5). No son secretos y no cifran
  # nada real — no hay que rotarlas ni sacarlas del repo.
  config.active_record.encryption.primary_key = "test_ar_encryption_primary_key__"
  config.active_record.encryption.deterministic_key = "test_ar_encryption_determinist__"
  config.active_record.encryption.key_derivation_salt = "test_ar_encryption_key_salt_____"

  # Rails venía avisando en cada corrida de specs que esto quedaba en `nil` ("config.eager_load
  # is set to nil. Please update your config/environments/*.rb files accordingly"). No había
  # dónde ponerlo porque el archivo no existía; `false` es el valor que la propia advertencia
  # recomienda para test.
  config.eager_load = false

  # `:test` acumula los jobs en un arreglo en memoria en vez de ejecutarlos. Es lo que
  # hace que `have_enqueued_job` funcione y, sobre todo, lo que evita que un spec dispare
  # trabajo real de fondo. Sin esta línea el default de ActiveJob es `:async`, que SÍ los
  # ejecuta, en otro thread y a destiempo respecto del ejemplo que los encoló.
  config.active_job.queue_adapter = :test

  # Se declara igual que en los otros ambientes para que un spec que necesite el
  # adaptador real (`perform_enqueued_jobs` contra Solid Queue) encuentre las tablas en
  # `db/test_queue.sqlite3` y no en la base principal.
  config.solid_queue.connects_to = { database: { writing: :queue } }
end

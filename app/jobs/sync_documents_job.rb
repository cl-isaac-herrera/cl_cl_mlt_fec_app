# frozen_string_literal: true

# Sincronización periódica de documentos.
#
# Por ahora es un esqueleto: solo deja constancia de que el planificador lo despertó.
# El horario NO se decide acá — vive en `config/recurring.yml`, que es lo que lee el
# Scheduler de Solid Queue al arrancar `bin/jobs`. Cambiar la frecuencia es cambiar ese
# archivo y reiniciar el worker; este archivo no se toca.
class SyncDocumentsJob < ApplicationJob
  queue_as :sync_documents

  def perform
    Rails.logger.info('Hola mundo')
  end
end

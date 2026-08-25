# frozen_string_literal: true

# Clase base de todo job de la aplicación. Acá viven las políticas de reintento
# transversales, para no repetirlas job por job.
class ApplicationJob < ActiveJob::Base
  # Un reinicio del servicio o un deploy deja jobs a medias; SQLite además puede
  # devolver `SQLite3::BusyException` (que Rails mapea a `StatementInvalid`) si el
  # escritor está tomado. Los dos casos se resuelven volviendo a intentar.
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3

  # El job guarda el id del registro, no el registro. Si para cuando le toca correr ese
  # registro ya no está, no hay nada que reintentar: reintentarlo fallaría igual las
  # tres veces y terminaría en `failed_executions` haciendo ruido.
  discard_on ActiveJob::DeserializationError
end

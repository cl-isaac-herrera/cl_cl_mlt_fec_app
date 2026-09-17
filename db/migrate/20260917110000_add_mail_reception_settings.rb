# frozen_string_literal: true

# Agrega el grupo de ajustes `MAIL_RECEPTION` al catálogo de `settings`: los
# dos límites de `MailReceptionJob` (lectura de bandejas de recepción cada 5
# minutos, `config/recurring.yml`).
#
# Reemplazan las constantes fijas `MaxEmailsToReadPerInbox` (20, límite
# BLANDO por bandeja) y `MaxEmailsToReadPerExecution` (350, límite DURO por
# corrida) del conector .NET legacy
# (`legacy/reception/clvsfemailsconector`), pensadas para un scheduler externo
# cada 15 minutos. Este job corre cada 5 (un tercio de ese intervalo), así que
# los valores de arranque son esos mismos números divididos entre 3 y
# redondeados hacia arriba: 20 × 5/15 = 6.67 → 7, y 350 × 5/15 = 116.67 → 117
# (`MailReceptionJob::DEFAULT_MAX_MESSAGES_PER_MAILBOX`/
# `DEFAULT_MAX_MESSAGES_PER_EXECUTION`).
#
# ── Por qué una migración y no `db:seed` ─────────────────────────────────────
# El mismo motivo que `20260907120000_add_azure_storage_settings.rb`: el
# catálogo se declara en `db/seeds.rb` (§36), que hace upsert sin tocar los
# valores, pero correrlo entero contra una base viva arranca con
# `Permission.unscoped.delete_all` y se lleva las asignaciones de roles. Con
# esta migración, una base migrada termina idéntica a una sembrada de cero.
#
# ── `default_value`, no `fixed_value` ────────────────────────────────────────
# Son un punto de partida razonable, no un dato del producto: una instalación
# con buzones muy activos puede necesitar subirlos desde Configuraciones →
# Generales, y esta migración solo escribe el valor cuando NO hay uno
# guardado — correrla dos veces no puede devolver un ajuste ya ajustado por el
# operador a su default.
class AddMailReceptionSettings < ActiveRecord::Migration[8.1]
  GROUP = 'MAIL_RECEPTION'

  # code                                          description                                                                            is_visible  default
  SETTINGS = [
    ['MAIL_RECEPTION_MAX_MESSAGES_PER_MAILBOX',
     'Límite blando: tope de correos sin leer que se procesan de UNA bandeja en cada corrida', true, '7'],
    ['MAIL_RECEPTION_MAX_MESSAGES_PER_EXECUTION',
     'Límite duro: tope total de correos que se procesan en TODA la corrida, sumando todas las bandejas', true, '117']
  ].freeze

  # Modelo propio y mínimo, no `Setting`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería la fila si
  # estuviera dada de baja — que es justo la que habría que reactivar.
  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information

    SETTINGS.each do |code, description, is_visible, default_value|
      record = MigrationSetting.unscoped.find_or_initialize_by(code: code)
      record.group_code  = GROUP
      record.description = description
      record.is_visible  = is_visible
      record.is_active   = true
      # Solo si no hay ninguno: correr esta migración dos veces no puede
      # devolver el límite a su default después de que alguien lo ajustó.
      record.value = default_value if record.value.blank?
      record.save!
    end
  end

  def down
    MigrationSetting.unscoped.where(code: SETTINGS.map(&:first)).delete_all
  end
end

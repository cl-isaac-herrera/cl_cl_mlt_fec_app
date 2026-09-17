# frozen_string_literal: true

# Cuándo `MailReceptionJob` terminó su último intento sobre esta bandeja
# (con éxito, con error de conexión, o con cualquier otro desenlace) — no
# cuándo se creó ni cuándo se editó, que ya cubren `Auditable`/`timestamps`.
#
# Sirve para repartir el trabajo de forma justa entre corridas: con el límite
# duro (`MAIL_RECEPTION_MAX_MESSAGES_PER_EXECUTION`, §CLAUDE.md) una corrida
# puede terminar antes de llegar a todas las bandejas activas. Sin esta
# columna, `ReceptionMailbox.where(is_active: true)` siempre las devolvía en
# el mismo orden (por `id`), así que las últimas de la lista podían quedar sin
# procesarse corrida tras corrida si las primeras nunca dejaban margen.
#
# `null` a propósito: una bandeja recién creada NUNCA se ha procesado, y ese
# estado tiene que ganarle a cualquier fecha real al ordenar (`ORDER BY
# last_processed_at ASC` ya pone los `NULL` primero en SQLite) — es la bandeja
# con más prioridad de todas.
class AddLastProcessedAtToReceptionMailboxes < ActiveRecord::Migration[8.1]
  def change
    add_column :reception_mailboxes, :last_processed_at, :datetime
  end
end

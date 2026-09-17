# frozen_string_literal: true

# La bandeja de recepción que usa esta compañía (`Company#reception_mailbox`),
# para archivar los .eml de sus documentos en su propia carpeta
# (`Documents::EmailArchive`). Opcional, mismo criterio que `email_config_id`
# (CLAUDE.md §38): sin asignar, la compañía simplemente no tiene todavía una
# bandeja de la que `MailReceptionJob` le lea nada.
class AddReceptionMailboxToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_reference :companies, :reception_mailbox, foreign_key: true
  end
end

# frozen_string_literal: true

# Qué bandeja de correo usa cada compañía para enviar notificaciones. Opcional:
# una compañía sin bandeja asignada simplemente no puede enviar todavía
# (`Documents::ReceiptMailer::MissingConfiguration`), no es un error de datos.
class AddEmailConfigToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_reference :companies, :email_config, foreign_key: true
  end
end

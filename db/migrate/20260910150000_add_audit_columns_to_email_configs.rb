# frozen_string_literal: true

# `email_configs` nació como tabla de soporte del envío (la creó
# `CreateEmailConfigs` para que `Documents::ReceiptMailer` tuviera de dónde sacar
# el SMTP) y por eso le faltan las tres columnas que el estándar de Clavisco pide
# en TODA tabla: `is_active`, `created_by` y `updated_by`
# (`Clavisco::DataAccess::Auditable`).
#
# Ahora la administra una pantalla (`/configurations/email-senders`), así que las
# necesita de verdad:
#
#   - `is_active` — una bandeja no se puede borrar: `companies.email_config_id`
#     la referencia con llave foránea, y el borrado físico está prohibido (§2.2).
#     Retirar una bandeja que ya no se usa es bajarla, no eliminarla.
#   - `created_by` / `updated_by` — quién tocó las credenciales de un remitente es
#     justamente lo que se quiere saber cuando los correos dejan de salir.
class AddAuditColumnsToEmailConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :email_configs, :is_active,   :boolean, null: false, default: true
    add_column :email_configs, :created_by,  :string
    add_column :email_configs, :updated_by,  :string
  end
end

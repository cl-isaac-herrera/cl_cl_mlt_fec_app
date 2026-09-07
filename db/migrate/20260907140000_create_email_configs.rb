# frozen_string_literal: true

# Bandeja de correo SMTP para el envío de notificaciones (por ahora, el correo
# de recepción electrónica de `SendElectronicReceiptJob`). Una compañía usa la
# que tenga asignada en `companies.email_config_id` (ver la migración
# `AddEmailConfigToCompanies`).
class CreateEmailConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :email_configs do |t|
      t.string  :email, limit: 160, null: false

      # Cifrada con ActiveRecord Encryption (`encrypts` en el modelo). Reversible
      # y no un digest: el SMTP necesita la contraseña en claro para autenticar
      # (CLAUDE.md §29). Sin `limit:` — lo que se guarda es el sobre del cifrado,
      # más largo que la contraseña en claro, no la contraseña en sí.
      t.text    :password

      t.string  :host, limit: 50, null: false
      t.integer :port, null: false

      t.boolean :ssl, null: false, default: true

      # Nombre/dirección con la que el destinatario VE el remitente. El correo
      # real —el que autentica contra el SMTP— es `email`; este es solo el
      # "From" visible, igual que `EmailConfig.SenderAddress` del legacy
      # (`legacy/apis/clvsfesync4.3/CLVS_FE.Mails/Common.cs`).
      t.string  :sender_address, limit: 160

      t.timestamps
    end
  end
end

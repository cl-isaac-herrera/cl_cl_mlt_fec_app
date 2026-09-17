# frozen_string_literal: true

# Bandejas de correo de RECEPCIÓN: de dónde `MailReceptionJob` lee los
# documentos electrónicos que envían los proveedores. Es la contraparte de
# lectura de `email_configs` (que es de envío, CLAUDE.md §38) y reemplaza la
# tabla `MailParserConfig` del conector .NET legacy
# (`legacy/reception/clvsfemailsconector`).
#
# Se recorta a la conexión con el servidor de correo: a diferencia del legacy,
# NO lleva `CompanyId` ni `IsAutomatic` — la relación con la compañía se
# invierte (`companies.reception_mailbox_id`, ver la migración siguiente) y
# "automática" no aplica porque el job corre siempre por `config/recurring.yml`,
# no hay un modo manual.
#
# Dos formas de autenticar contra el IMAP, igual que el legacy:
#   - Usuario/contraseña (`use_token: false`): `mail_server`/`port`/`email`/
#     `password`.
#   - OAuth2 client credentials (`use_token: true`), vía XOAUTH2, contra
#     cualquier proveedor compatible (Microsoft Entra ID/Exchange Online,
#     Google Workspace, u otro) — no es algo propio de un solo proveedor:
#     además de lo anterior, `url` (el endpoint de token)/`grant_type`/
#     `scope`/`client_id`/`client_secret`. El servidor y el puerto IMAP se
#     usan en los DOS casos — el token solo cambia CÓMO se autentica la
#     sesión IMAP, no adónde se conecta.
#
# ── Sin `tenant_id` ───────────────────────────────────────────────────────
# El "OAuth 2.0 token endpoint (v2)" que muestra el registro de la app en
# Azure/Entra ID YA trae el tenant real incrustado
# (`https://login.microsoftonline.com/<tenant-guid>/oauth2/v2.0/token`) — quien
# configura la bandeja lo copia tal cual. Un campo `tenant_id` aparte no tiene
# con qué armar nada (`url` ya está completa) ni viaja en el POST del token
# (Microsoft identity platform no lo pide por separado en client credentials),
# así que sería un campo obligatorio sin ningún consumidor.
class CreateReceptionMailboxes < ActiveRecord::Migration[8.1]
  def change
    create_table :reception_mailboxes do |t|
      t.string  :mail_server, limit: 255
      t.string  :email,       limit: 160
      t.text    :password # `encrypts` en el modelo — sin `limit:` (CLAUDE.md §29 regla 4)
      t.integer :port

      t.boolean :use_token, null: false, default: false

      t.string :url,        limit: 255
      t.string :grant_type, limit: 50,  default: 'client_credentials'
      t.string :scope,      limit: 255, default: 'https://outlook.office365.com/.default'
      t.string :client_id,  limit: 100
      t.text   :client_secret

      t.boolean :is_active, null: false, default: true
      t.string  :created_by
      t.string  :updated_by
      t.timestamps
    end
  end
end

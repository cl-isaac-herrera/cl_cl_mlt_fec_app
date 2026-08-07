# frozen_string_literal: true

# Credenciales de SAP del usuario.
#
# Nombres en snake_case por la convención de columnas del estándar (§2.2/§4.1):
# SapUser → sap_user, SapPassword → sap_password.
class AddSapCredentialsToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string :sap_user
      t.string :sap_password
    end
  end
end

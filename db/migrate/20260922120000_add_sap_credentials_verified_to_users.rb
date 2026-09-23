# frozen_string_literal: true

# Guardar el perfil ya no exige probar las credenciales de SAP antes. Esta columna
# dice si las que quedaron guardadas pasaron la prueba: la pantalla lo muestra con
# un ícono en el campo "Usuario de SAP". Ver `User#sap_credentials_just_verified`.
class AddSapCredentialsVerifiedToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sap_credentials_verified, :boolean, default: false, null: false
  end
end

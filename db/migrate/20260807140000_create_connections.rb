# frozen_string_literal: true

# Conexión a un servidor SAP vía Service Layer.
#
# Acceso 100% por Service Layer (REST/OData): no hay ODBC, así que la conexión NO
# lleva motor de base de datos, tipo de servidor, DSN ni credenciales de BD — todo
# eso pertenece al modelo de acceso directo que la organización está eliminando.
# Queda únicamente el endpoint del Service Layer.
#
# Las credenciales son por usuario (users.sap_user / users.sap_password) y la base
# destino por compañía (companies.sap_db_code), tal como los recibe
# Clavisco::ServiceLayer::Client (§2.7): base_url + company_db + username + password.
class CreateConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :connections do |t|
      t.string :name, null: false
      # Base del Service Layer, ej. https://sap.empresa.com:50000/b1s/v1
      t.string :service_layer_url, null: false

      t.boolean :is_active, default: true, null: false
      t.string  :created_by
      t.string  :updated_by

      t.timestamps
    end

    add_foreign_key :companies, :connections
  end
end

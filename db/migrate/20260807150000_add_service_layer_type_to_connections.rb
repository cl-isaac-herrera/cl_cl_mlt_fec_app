# frozen_string_literal: true

# Motor sobre el que corre SAP (SQL Server o HANA). No es un dato de ODBC: aun
# hablando 100% por Service Layer, hay semántica que difiere entre ambos motores
# (funciones de fecha y sintaxis de SQLQueries, por ejemplo).
class AddServiceLayerTypeToConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :connections, :service_layer_type, :string
  end
end

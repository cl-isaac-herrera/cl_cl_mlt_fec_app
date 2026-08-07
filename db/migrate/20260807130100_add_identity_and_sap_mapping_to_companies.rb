# frozen_string_literal: true

# La compañía queda como tabla de identidad y mapeo a SAP: el id interno para las
# llaves foráneas, un uuid como identificador estable hacia afuera, y los dos datos
# que dicen contra qué base de SAP opera. El resto de la información de negocio vive
# en SAP, no acá.
#
# El uuid se genera en Ruby (Company#ensure_uuid), no con una función de la base:
# el estándar prohíbe SQL específico de SQLite para no atar la portabilidad.
class AddIdentityAndSapMappingToCompanies < ActiveRecord::Migration[8.1]
  def change
    change_table :companies, bulk: true do |t|
      t.string  :uuid
      t.integer :connection_id
      t.string  :sap_db_code
    end

    add_index :companies, :uuid, unique: true
  end
end

# frozen_string_literal: true

# Servidor SAP alcanzable por Service Layer. Varias compañías pueden vivir en el
# mismo servidor y distinguirse por su `sap_db_code`.
class Connection < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # La asociación inversa se llama `sap_connection` en Company para no pisar
  # `ActiveRecord::Base#connection`.
  has_many :companies, foreign_key: :connection_id, inverse_of: :sap_connection, dependent: :nullify

  validates :name, :service_layer_url, presence: true
end

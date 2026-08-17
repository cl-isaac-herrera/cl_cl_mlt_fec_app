# frozen_string_literal: true

# Ambiente de emisión de Hacienda: pruebas o producción. Agrupa los tres endpoints
# y el número de resolución, que no varían por compañía sino por ambiente.
#
# Es un catálogo, no algo que el usuario administre: los valores son de Hacienda y
# son iguales en toda instalación. Se siembra desde `db/seeds.rb`.
class Environment < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  has_many :companies, dependent: nil, inverse_of: :environment

  validates :uri_token, :uri_send, :uri_check, presence: true

  scope :production, -> { where(is_prod: true) }

  def name = is_prod? ? 'Producción' : 'Pruebas'
end

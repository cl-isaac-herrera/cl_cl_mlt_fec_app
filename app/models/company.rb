class Company < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  has_many :users_by_companies, dependent: :destroy
  has_many :users, through: :users_by_companies

  # Nombrada `sap_connection` y no `connection` para no pisar
  # ActiveRecord::Base#connection en las instancias.
  belongs_to :sap_connection, class_name: 'Connection', foreign_key: :connection_id,
                              inverse_of: :companies, optional: true

  before_create :ensure_uuid

  # Compañías asignadas a un usuario. Es el filtro que define qué puede ver en el
  # selector: nunca se listan todas las compañías del sistema.
  scope :assigned_to, lambda { |user_id|
    joins(:users_by_companies).where(users_by_companies: { user_id: user_id, is_active: true })
  }

  private

  # Generado en Ruby y no en la base: el estándar prohíbe SQL específico de SQLite.
  def ensure_uuid
    self.uuid ||= SecureRandom.uuid
  end
end

class Company < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  has_many :users_by_companies, dependent: :destroy
  has_many :users, through: :users_by_companies

  # Nombrada `sap_connection` y no `connection` para no pisar
  # ActiveRecord::Base#connection en las instancias.
  belongs_to :sap_connection, class_name: 'Connection', foreign_key: :connection_id,
                              inverse_of: :companies, optional: true

  # Ambiente de Hacienda contra el que emite. Opcional porque una compañía puede
  # existir configurada a medias hasta que se le asigne.
  belongs_to :environment, inverse_of: :companies, optional: true

  # Cifrado reversible, no digest: el PIN se necesita en claro para abrir el .p12 y
  # la contraseña del ATV para pedirle el token a Hacienda. Ver `CLAUDE.md` §29 —
  # `encrypts` solo actúa al escribir el atributo, así que una fila insertada por
  # fuera del modelo queda en texto plano y nadie avisa.
  encrypts :cert_pin
  encrypts :token_password

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

# frozen_string_literal: true

class Role < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  PROTECTED_NAMES = %w[OWNER].freeze

  # Mismo alcance que `Permission::SCOPES` (docs/PLAN-ROLES-POR-ALCANCE.md): un
  # rol solo puede contener permisos de su propio alcance (`RolePermission`).
  SCOPES = %w[installation company].freeze

  has_many :role_permissions, dependent: :destroy
  has_many :permissions, through: :role_permissions

  validates :name, presence: true, length: { maximum: 100 }
  # El mismo nombre puede existir una vez por alcance ("Administrador" de
  # instalación y "Administrador" de compañía son roles distintos a propósito).
  validates :name, uniqueness: { scope: %i[is_active scope], case_sensitive: false }, if: :name?
  validates :scope, presence: true, inclusion: { in: SCOPES, message: "debe ser 'installation' o 'company'" }

  scope :installation, -> { where(scope: 'installation') }
  scope :company,      -> { where(scope: 'company') }

  def protected_name?
    PROTECTED_NAMES.include?(name.to_s.upcase)
  end

  def permission_ids_assigned
    role_permissions.pluck(:permission_id)
  end
end

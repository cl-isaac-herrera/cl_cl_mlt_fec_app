class RolePermission < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  belongs_to :role
  belongs_to :permission
end

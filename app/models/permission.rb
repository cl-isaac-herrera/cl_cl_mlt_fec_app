class Permission < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable
end

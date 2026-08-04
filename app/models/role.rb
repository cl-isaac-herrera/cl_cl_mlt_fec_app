class Role < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable
end

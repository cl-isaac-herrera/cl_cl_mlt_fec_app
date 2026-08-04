class User < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable
end

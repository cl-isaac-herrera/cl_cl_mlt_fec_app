class UserRole < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable
  include Clavisco::DataAccess::CompanyScoped

  belongs_to :user
  belongs_to :role
end

class Company < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable
end

class User < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  has_many :users_by_companies, dependent: :destroy
  has_many :companies, through: :users_by_companies
end

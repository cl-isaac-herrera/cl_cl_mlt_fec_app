# frozen_string_literal: true

# Asignación de una compañía a un usuario. Determina qué compañías puede seleccionar
# en el toolbar y, por lo tanto, sobre cuáles puede operar.
class UsersByCompany < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  belongs_to :user
  belongs_to :company

  validates :company_id, uniqueness: { scope: :user_id }
end

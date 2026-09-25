# frozen_string_literal: true

# Asignación de una compañía a un usuario. Determina qué compañías puede
# seleccionar en el toolbar y, por lo tanto, sobre cuáles puede operar — y con
# `role`, con qué rol de COMPAÑÍA opera en ella
# (docs/PLAN-ROLES-POR-ALCANCE.md). Una fila da el acceso y el rol a la vez: no
# existe un acceso sin rol.
class UsersByCompany < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  belongs_to :user
  belongs_to :company
  belongs_to :role

  validates :company_id, uniqueness: { scope: :user_id }
  validate :role_must_be_company_scoped

  private

  def role_must_be_company_scoped
    return if role.nil? || role.scope == 'company'

    errors.add(:role, "es de alcance #{role.scope} y esta asignación necesita un rol de compañía")
  end
end

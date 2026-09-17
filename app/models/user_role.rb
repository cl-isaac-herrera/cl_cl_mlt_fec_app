class UserRole < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable
  include Clavisco::DataAccess::CompanyScoped

  # `CompanyScoped` declara `belongs_to :company, optional: true` — acá se
  # redeclara sin `optional: true` porque la columna es `null: false`
  # (`db/migrate/20260803211351_create_user_roles.rb`). Sin esto, `.valid?`
  # devuelve `true` sin compañía y el guardado revienta con
  # `ActiveRecord::NotNullViolation` en vez de un error de validación
  # (`TODOS.md` → Roles).
  belongs_to :company

  belongs_to :user
  belongs_to :role
end

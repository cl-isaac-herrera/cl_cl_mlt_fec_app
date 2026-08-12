# frozen_string_literal: true

# Rol del producto: un nombre al que se le cuelgan permisos (`role_permissions`)
# y que se le asigna a un usuario EN UNA COMPAÑÍA (`user_roles.company_id`).
#
# El rol en sí es **global**, no pertenece a ninguna compañía —
# CLAVISCO-PLATFORM-STANDARDS §4.1 define `roles (id, name, description,
# is_active)` sin `company_id`. El API .NET lo modelaba distinto
# (`spGetRoles(companyId)`, `spCreateRole(RoleWithCompany)`); ver `TODOS.md`.
class Role < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Rol reservado del .NET: administra todos los permisos y no se edita. La UI ya
  # lo bloquea; acá se bloquea de nuevo porque la UI se puede manipular (§26).
  PROTECTED_NAMES = %w[OWNER].freeze

  has_many :role_permissions, dependent: :destroy
  has_many :permissions, through: :role_permissions
  has_many :user_roles, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }
  # Único entre los activos: un rol dado de baja no debe bloquear el nombre.
  validates :name, uniqueness: { scope: :is_active, case_sensitive: false }, if: :name?

  # @return [Boolean] true si es un rol reservado que no admite cambios.
  def protected_name?
    PROTECTED_NAMES.include?(name.to_s.upcase)
  end

  # Ids de los permisos vigentes del rol. `role_permissions` tiene soft delete,
  # así que las asignaciones revocadas quedan fuera por el default_scope.
  def permission_ids_assigned
    role_permissions.pluck(:permission_id)
  end
end

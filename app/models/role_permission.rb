# frozen_string_literal: true

class RolePermission < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  belongs_to :role
  belongs_to :permission

  validate :scope_matches_role

  private

  # Un rol solo puede contener permisos de su propio alcance — sin esto, un
  # permiso de instalación puesto en un rol de compañía terminaría
  # concediéndose por compañía (y viceversa). No cubre `insert_all`/`update_all`
  # (no disparan validaciones): esos escritores en lote validan el alcance por
  # su cuenta antes de escribir (ver `Api::Roles::PermissionsController#update`).
  def scope_matches_role
    return if role.nil? || permission.nil?
    return if role.scope == permission.scope

    errors.add(:permission, "es de alcance #{permission.scope} y el rol es de alcance #{role.scope}")
  end
end

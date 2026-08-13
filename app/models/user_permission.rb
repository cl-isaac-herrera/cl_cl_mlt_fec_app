# frozen_string_literal: true

# Permiso concedido DIRECTAMENTE a un usuario, sin rol de por medio.
#
# Solo vale para permisos `global` — los que no dependen de la compañía activa.
# Un `normal` se concede únicamente por rol, y esa restricción se valida acá para
# que no dependa de que el controller se acuerde: es la diferencia entre una
# tabla que abre una vía de concesión acotada y una que abre un portillo.
class UserPermission < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  belongs_to :user
  belongs_to :permission

  validates :permission_id, uniqueness: {
    scope:      :user_id,
    conditions: -> { unscope(where: :is_active) }
  }
  validate :permission_must_be_global

  # ¿El usuario tiene este permiso concedido directamente? Es el EXISTS que
  # complementa al de `user_roles` en `Api::AuthorizedController#permission?`.
  # Nunca cargar la lista y filtrar en Ruby (§4.2 del estándar).
  def self.granting?(user_id:, name:)
    joins(:permission)
      .where(user_id: user_id,
             permissions: { name: name, is_active: true, type: 'global' })
      .exists?
  end

  # Nombres de los permisos globales vigentes de un usuario. Alimenta la lista de
  # permisos efectivos que consumen el menú y el auth-guard.
  def self.global_names_for(user_id)
    joins(:permission)
      .where(user_id: user_id, permissions: { is_active: true, type: 'global' })
      .distinct
      .pluck('permissions.name')
  end

  private

  def permission_must_be_global
    return if permission.nil? || permission.type == 'global'

    errors.add(:permission, 'no es global: los permisos por compañía se conceden con un rol')
  end
end

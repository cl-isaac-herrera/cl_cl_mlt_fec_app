# frozen_string_literal: true

class Permission < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # installation → se concede con el rol de instalación del usuario, sin
  #                depender de la compañía activa (`users.installation_role_id`).
  # company      → se concede con el rol de compañía de la asignación
  #                (`users_by_companies.role_id`), y solo aplica ahí.
  SCOPES = %w[installation company].freeze

  # Mensaje explícito: el proyecto declara `default_locale = :es` pero no tiene
  # `config/locales`, así que un mensaje por i18n saldría como "translation missing".
  validates :scope, inclusion: { in: SCOPES, message: "debe ser 'installation' o 'company'" }

  scope :installation, -> { where(scope: 'installation') }
  scope :company,      -> { where(scope: 'company') }
end

# frozen_string_literal: true

class Permission < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # ⚠️ `type` acá NO es Single Table Inheritance: es el tipo de permiso del negocio.
  # ActiveRecord toma por convención una columna llamada `type` como discriminador
  # de STI, así que sin esta línea cualquier lectura falla con
  # `ActiveRecord::SubclassNotFound` al no encontrar una clase `normal`/`global`.
  self.inheritance_column = nil

  # normal → se concede por compañía (user_roles lleva company_id).
  # global → aplica a nivel de aplicación, no depende de la compañía activa.
  TYPES = %w[normal global].freeze

  # Mensaje explícito: el proyecto declara `default_locale = :es` pero no tiene
  # `config/locales`, así que un mensaje por i18n saldría como "translation missing".
  validates :type, inclusion: { in: TYPES, message: "debe ser 'normal' o 'global'" }

  scope :normal, -> { where(type: 'normal') }
  scope :global, -> { where(type: 'global') }
end

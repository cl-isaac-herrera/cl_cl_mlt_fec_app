# frozen_string_literal: true

require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'action_cable/engine'

# Autoload libs
Bundler.require(*Rails.groups)

module FecApp
  class Application < Rails::Application
    config.load_defaults 8.0

    # Zona horaria Costa Rica (UTC-6, sin DST)
    config.time_zone = 'America/Costa_Rica'

    # Locale español por defecto
    config.i18n.default_locale = :es

    # No generar helpers, assets ni specs al crear controllers/models
    config.generators do |g|
      g.helper        false
      g.assets        false
      g.test_framework :rspec
    end

    # ── Cifrado en reposo (ActiveRecord Encryption) ─────────────────────────
    #
    # Lo exige `users.sap_password`: la contraseña de SAP tiene que poder
    # descifrarse para hacer `/Login` contra el Service Layer, así que no puede ser
    # un digest. El API .NET la guardaba cifrada con AES; acá el equivalente nativo
    # es ActiveRecord Encryption.
    #
    # Las llaves se toman del entorno. Si no están —desarrollo y test— se derivan de
    # SECRET_KEY_BASE para que la app arranque sin configuración extra; en producción
    # se fijan explícitamente (ver .env.example). El .env ya está cargado acá:
    # dotenv-rails corre en `before_configuration`, antes del cuerpo de esta clase.
    encryption_seed = ENV['SECRET_KEY_BASE'].presence || 'fec-development-encryption-seed'
    derive_key = ->(label) { OpenSSL::Digest::SHA256.hexdigest("#{encryption_seed}:#{label}") }

    config.active_record.encryption.primary_key =
      ENV['AR_ENCRYPTION_PRIMARY_KEY'].presence || derive_key.call('primary')
    config.active_record.encryption.deterministic_key =
      ENV['AR_ENCRYPTION_DETERMINISTIC_KEY'].presence || derive_key.call('deterministic')
    config.active_record.encryption.key_derivation_salt =
      ENV['AR_ENCRYPTION_KEY_DERIVATION_SALT'].presence || derive_key.call('salt')

    # Las filas que ya existan con la contraseña en claro se siguen leyendo; se
    # vuelven a guardar cifradas la próxima vez que el usuario actualice su perfil.
    config.active_record.encryption.support_unencrypted_data = true
  end
end

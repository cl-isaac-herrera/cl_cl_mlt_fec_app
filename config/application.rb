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
  end
end

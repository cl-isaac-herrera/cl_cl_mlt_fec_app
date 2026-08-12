# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.3.11'

gem 'rails', '~> 8.0'

# Servidor web
gem 'puma', '>= 5.0'

# Hotwire
gem 'turbo-rails'
gem 'stimulus-rails'

# Importmap para JavaScript (sin bundler)
gem 'importmap-rails'

# Tailwind CSS
gem 'tailwindcss-rails'

# Base de datos
gem 'sqlite3', '>= 2.1'

# Solid stack (cache, jobs, websockets)
gem 'solid_cache'
gem 'solid_queue'
gem 'solid_cable'

# Proxy HTTP hacia API externo
gem 'faraday', '~> 2.0'

# Submodules de plataforma (auth OIDC, structures, common, data_access)
gem 'bcrypt', '~> 3.1.7'
gem 'httparty'
gem 'jwt'
gem 'openid_connect', '~> 2.5'

# Variables de entorno
gem 'dotenv-rails', groups: [:development, :test]

# Zona horaria en Windows (no tiene zoneinfo del sistema)
gem 'tzinfo-data', platforms: %i[windows jruby]

# Assets
gem 'propshaft'

# Sentry
gem "sentry-ruby"
gem "sentry-rails"

group :development, :test do
  gem 'debug', platforms: %i[mri windows], require: 'debug/prelude'
  gem 'brakeman', require: false
  gem 'factory_bot_rails'
  gem 'rspec-rails'
  gem 'rubocop-rails-omakase', require: false
end

group :development do
  # Detecta N+1 en tiempo real (CLAVISCO-PLATFORM-STANDARDS §1.6: "usar la gema
  # bullet en desarrollo... no depender solo de revisión manual").
  gem 'bullet'
end

group :test do
  # Stub de las llamadas HTTP salientes de ProxyController (Net::HTTP), sin red real.
  gem 'webmock'
end

group :development do
  gem 'web-console'
end

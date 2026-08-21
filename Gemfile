# frozen_string_literal: true

source 'https://rubygems.org'

ruby '~> 3.3.11'

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

# Consulta a la base externa de documentos (SQL Server o SAP HANA).
#
# ODBC es el único conector que habla con los dos motores con una sola gema: el
# driver manager del sistema resuelve el destino y la app solo cambia la cadena
# de conexión. La alternativa era `tiny_tds` + un cliente de HANA, o sea dos
# dependencias nativas con dos APIs distintas.
#
# `require: false` a propósito: es una extensión nativa que se enlaza contra el
# driver manager del sistema, y una instalación de ODBC rota no tiene por qué
# tumbar el boot de toda la app. Lo carga `ExternalDb::Client` cuando se va a
# usar, y ahí el fallo sale como un error del módulo de documentos y no como una
# pantalla en blanco.
gem 'ruby-odbc', '~> 0.99999', require: false

# Pool de conexiones ODBC (`ExternalDb::Pool`). Ya estaba instalada como
# dependencia transitiva de `solid_cache`, pero se declara acá porque la app la
# usa directo: si mañana esa gema deja de traerla, el fallo aparecería como un
# `NameError` en la primera consulta a la base de documentos.
gem 'connection_pool', '~> 3.0'

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

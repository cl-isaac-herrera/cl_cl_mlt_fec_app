# frozen_string_literal: true

source 'https://rubygems.org'

ruby '~> 3.3.11'

gem 'rails', '~> 8.0'

# Pin explícito a la serie 2.x: la 3.0 elimina la firma de dos argumentos
# posicionales de `JSON.parse(source, options)` que
# `ActiveSupport::JSON.decode`/`ActiveRecord::Coders::JSON.load` todavía usan
# en Rails 8.1.3.1 — un `bundle update json` sin este pin salta a la 3.x y
# revienta con `ArgumentError: wrong number of arguments (given 2, expected 1)`
# en cualquier columna serializada (confirmado 2026-09-16: Solid Queue
# entraba en crash-loop al deserializar `arguments`). 2.21.2 ya trae el fix
# de CVE-2026-54696 (heap buffer overflow) sin el breaking change.
gem 'json', '~> 2.21'

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

# Envío de correo por SMTP (`Documents::ReceiptMailer`). Esta app carga Rails a
# la carta (`config/application.rb` no requiere `action_mailer/railtie`), así
# que no hay ActionMailer — un mensaje puntual con credenciales SMTP DISTINTAS
# por compañía no necesita esa capa completa (vistas, layouts, config global de
# entrega). Ya estaba instalada como dependencia transitiva, pero se declara
# acá porque la app la usa directo — mismo criterio que `connection_pool`.
gem 'mail', '~> 2.8'

# Lectura de bandejas IMAP para la recepción de documentos electrónicos de
# proveedores (`MailReceptionJob`). Dejó de empaquetarse por defecto con Ruby a
# partir de la 3.5; se declara explícita para no depender de qué gemas trae el
# intérprete instalado. `require: false`: `Mail::ImapSession` la requiere ella
# misma (`require 'net/imap'`).
gem 'net-imap', require: false

# Algunos proveedores adjuntan el XML del comprobante dentro de un .zip
# (`Mail::IncomingDocument`) — mismo comportamiento que aceptaba el conector
# .NET legacy (`ExtractAttachmentsFromZip`).
gem 'rubyzip', require: false

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

# Reduce boot times cacheando el resultado de requires/loads costosos. El
# Dockerfile estándar (§Deploy) corre `bundle exec bootsnap precompile` en el
# build stage — sin esta gema esa capa del build falla.
gem 'bootsnap', require: false

# Deploy vía Kamal + GHCR (CLAUDE.md, sección CI/CD). `require: false`: es una
# herramienta de línea de comandos para la máquina que despliega, no algo que
# la app cargue en runtime.
gem 'kamal', require: false

# Cache/compresión HTTP + X-Sendfile delante de Puma dentro del contenedor
# (`bin/thrust`, el CMD del Dockerfile). A diferencia de kamal, esta SÍ corre
# en producción — por eso va fuera de cualquier `group` (BUNDLE_WITHOUT en el
# Dockerfile excluye `development`, no el grupo default).
gem 'thruster', require: false

group :development, :test do
  gem 'debug', platforms: %i[mri windows], require: 'debug/prelude'
  gem 'brakeman', require: false
  gem 'bundler-audit', require: false
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

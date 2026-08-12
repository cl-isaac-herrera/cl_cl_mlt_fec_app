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

# Los middlewares de `common` se registran en el cuerpo de la clase de abajo, que
# corre ANTES de config/initializers/clavisco_submodules.rb. Se cargan acá para
# poder referenciar las constantes reales: `insert_before`/`insert_after` no
# aceptan el nombre en string como referencia de posición.
# Orden según CLAVISCO-PLATFORM-STANDARDS §3: structures → common.
require_relative '../vendor/clavisco/structures/lib/clavisco/structures'
require_relative '../vendor/clavisco/common/lib/clavisco/common'

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

    # ── Middleware de plataforma (CLAVISCO-PLATFORM-STANDARDS §2.4) ──────────
    #
    # ErrorHandler captura cualquier excepción no manejada en /api/*, la convierte
    # a `ApiResponse.error` y la reporta a Sentry. Sin él, la excepción sale como
    # la página de error de Rails: `text/html` en un endpoint JSON, y el riesgo de
    # filtrar el mensaje de la excepción, que es lo que prohíbe §1.5.
    #
    # ⚠️ La posición NO es la del snippet de §2.4 (`insert_before
    # Rails::Rack::Logger`), y es a propósito. Ahí el ErrorHandler queda POR FUERA
    # de `ActionDispatch::ShowExceptions`, que es quien realmente rescata las
    # excepciones del controller y renderiza la página de error SIN re-lanzarlas
    # (`show_exceptions = :all`, el default en los tres ambientes). Resultado: el
    # ErrorHandler nunca corre y el cliente recibe HTML vacío con 500.
    # Verificado: con el snippet literal, `GET /api/roles` con una excepción
    # adentro devuelve `text/html` y cuerpo vacío.
    #
    # Va DESPUÉS de DebugExceptions para quedar por dentro de ambos y ver la
    # excepción primero. Para lo que no es /api/*, ErrorHandler re-lanza y la
    # página HTML de error sigue funcionando igual que siempre.
    # Anotado en TODOS.md como corrección a proponer al estándar.
    #
    # `CompanyContext` NO se registra a propósito — el company_id vive en la
    # session cookie, no en un header (§2.4).
    config.middleware.insert_after ActionDispatch::DebugExceptions,
                                   Clavisco::Common::Middleware::ErrorHandler
    config.middleware.insert_before Rails::Rack::Logger,
                                    Clavisco::Common::Middleware::RequestLogger

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

    # Sin excepciones: leer una fila en claro levanta en vez de devolverla como si
    # nada. Con `true`, una contraseña sin cifrar se lee para siempre sin que nadie
    # se entere — y eso fue exactamente lo que pasó: `encrypts` solo actúa al
    # escribir, así que las filas viejas se quedaron en texto plano en silencio.
    #
    # Las que existían las cifró `20260812110000_encrypt_existing_sap_passwords`,
    # que corre antes que esto entre en efecto. Si aparece una nueva fila en claro
    # (una importación mal hecha, por ejemplo), ahora falla a la vista.
    config.active_record.encryption.support_unencrypted_data = false
  end
end

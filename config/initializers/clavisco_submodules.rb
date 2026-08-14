# frozen_string_literal: true

# Carga los submodules compartidos de Clavisco y define alias cortos.
# Los submodules viven en vendor/clavisco/ como git submodules.
# El orden importa — cada submodule puede depender de los anteriores.

require_relative '../../vendor/clavisco/structures/lib/clavisco/structures'
require_relative '../../vendor/clavisco/common/lib/clavisco/common'
require_relative '../../vendor/clavisco/data_access/lib/clavisco/data_access'
require_relative '../../vendor/clavisco/auth/lib/clavisco/auth'
require_relative '../../vendor/clavisco/service_layer/lib/clavisco/service_layer'

# licensing y app_menu todavía no existen como submodules — agregar cuando estén disponibles.
# require_relative '../../vendor/clavisco/licensing/lib/clavisco/licensing'
# require_relative '../../vendor/clavisco/app_menu/lib/clavisco/app_menu'

# sap_udfs administra la estructura (UDTs/UDFs) en SAP. NO se requiere acá: es una
# herramienta de línea de comandos (rake sap:schema:*) que corre fuera del request
# cycle, y sus tareas ya hacen su propio require. Cargarlo en el boot de Rails sería
# meter en cada request código que la app nunca llama. Los schemas viven en
# config/sap_schemas/*.json — ver CLAUDE.md §32.

# ── Alias ─────────────────────────────────────────────────────────────────────
ApiResponse = Clavisco::Structures::ApiResponse unless defined?(ApiResponse)

# LicenseService = Clavisco::Licensing::LicenseService unless defined?(LicenseService)
# MenuEnricher   = Clavisco::AppMenu::MenuEnricher      unless defined?(MenuEnricher)

# ── Alias de middleware ───────────────────────────────────────────────────────
module Middleware
  ErrorHandler  = Clavisco::Common::Middleware::ErrorHandler  unless defined?(Middleware::ErrorHandler)
  RequestLogger = Clavisco::Common::Middleware::RequestLogger unless defined?(Middleware::RequestLogger)
end

# ── Proxy modules (permiten `include Authenticatable` e `include Auditable`) ──
module Authenticatable
  def self.included(base) = base.include(Clavisco::Auth::Authenticatable)
end

module Auditable
  def self.included(base) = base.include(Clavisco::DataAccess::Auditable)
end

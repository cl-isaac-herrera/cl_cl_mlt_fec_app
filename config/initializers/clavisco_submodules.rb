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

# sap_udfs administra la estructura (UDTs/UDFs) en SAP. Este producto todavía no
# declara schemas propios; agregar cuando los tenga.
# require_relative '../../vendor/clavisco/sap_udfs/lib/clavisco/sap_udfs'

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

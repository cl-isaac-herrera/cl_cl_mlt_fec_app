# frozen_string_literal: true

require_relative 'config/application'

Rails.application.load_tasks

# Tareas del submódulo sap_udfs (sap:schema:* / sap:test_data:*). No vienen por
# `load_tasks` porque el submódulo no es un engine: hay que cargar sus .rake a mano.
# Reciben la ruta a un archivo de conexiones que NUNCA se commitea — ver
# config/sap_connections.example.json y CLAUDE.md §32.
#
# service_layer tiene que quedar en el $LOAD_PATH, no solo cargado. Dos razones:
#   1. `config/application` solo define la clase de la aplicación — los initializers
#      (donde clavisco_submodules.rb lo requiere) corren en `initialize!`, que las
#      tareas rake nunca invocan.
#   2. `Clavisco::SapUdfs::ClientFactory.build` no pregunta por la constante: hace
#      `require "clavisco/service_layer"`, que resuelve contra el $LOAD_PATH. Un
#      `require_relative` deja la clase disponible pero ese require falla igual.
# Sin esto las tareas abortan con "Clavisco::ServiceLayer::Client is not available
# on the load path" — ver TODOS.md → Submódulos.
$LOAD_PATH.unshift File.expand_path('vendor/clavisco/service_layer/lib', __dir__)
Dir[Rails.root.join('vendor/clavisco/sap_udfs/lib/tasks/*.rake')].each { |f| load f }

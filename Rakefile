# frozen_string_literal: true

require_relative 'config/application'

Rails.application.load_tasks

# Tareas del submódulo sap_udfs (sap:schema:* / sap:test_data:*). No vienen por
# `load_tasks` porque el submódulo no es un engine: hay que cargar sus .rake a mano.
# Reciben la ruta a un archivo de conexiones que NUNCA se commitea — ver
# config/sap_connections.example.json y CLAUDE.md §32.
Dir[Rails.root.join('vendor/clavisco/sap_udfs/lib/tasks/*.rake')].each { |f| load f }

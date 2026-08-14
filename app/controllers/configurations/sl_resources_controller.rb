# frozen_string_literal: true

module Configurations
  # SlResourcesController — Mantenimiento de las consultas al Service Layer.
  #
  # Sirve la shell HTML; el filtro, la tabla y las llamadas al API los maneja
  # Stimulus (`sl_resources_controller.js`).
  #
  # No tiene equivalente en el Angular legacy: allá estas filas se editaban
  # directamente contra la base.
  class SlResourcesController < ApplicationController
    layout 'protected'

    def index; end
  end
end

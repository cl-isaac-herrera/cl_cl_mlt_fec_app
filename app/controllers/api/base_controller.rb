# frozen_string_literal: true

class Api::BaseController < ActionController::API
  include Clavisco::Auth::Authenticatable

  before_action :authenticate_user!
end

# frozen_string_literal: true

# AuthController — login/logout vía OIDC (Auth0/Keycloak), usando Clavisco::Auth::OidcClient.
#
# Independiente del login actual (`SessionsController`, 100% client-side vía localStorage) —
# corre en paralelo bajo /auth/*, sin tocar el flujo existente. Sirve de base para cuando
# los controllers vayan migrando a sesión de servidor.
class AuthController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :callback

  # GET /auth/login
  def login
    state = SecureRandom.hex(16)
    nonce = SecureRandom.hex(16)
    session[:oidc_state] = state
    session[:oidc_nonce] = nonce

    redirect_to oidc_client.authorization_uri(state: state, nonce: nonce), allow_other_host: true
  end

  # GET /auth/callback
  def callback
    if params[:state] != session.delete(:oidc_state)
      return render plain: 'Estado inválido', status: :bad_request
    end

    access_token = oidc_client.exchange_code(params[:code])
    claims       = oidc_client.decode_id_token(access_token.id_token)
    session.delete(:oidc_nonce)

    user = User.find_by(email: claims['email'])
    unless user
      return render plain: 'No existe una cuenta para este correo.', status: :unauthorized
    end

    session[:user_id] = user.id
    redirect_to root_path
  end

  # DELETE /auth/logout
  def logout
    session.delete(:user_id)
    session.delete(:company_id)
    redirect_to oidc_client(redirect_uri: nil).logout_url(return_to: root_url), allow_other_host: true
  end

  private

  def oidc_client(redirect_uri: auth_callback_url)
    Clavisco::Auth::OidcClient.new(Rails.application.config.oidc, redirect_uri: redirect_uri)
  end
end

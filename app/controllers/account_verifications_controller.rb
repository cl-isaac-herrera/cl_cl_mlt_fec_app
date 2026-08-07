# frozen_string_literal: true

# AccountVerificationsController — Verificación de cuenta por OTP.
#
# Migrado de Angular: VerificationEmailComponent (ruta /account-verification/:OTPCode).
#
# Página pública (sin menú lateral): usa el layout `application` por defecto.
# La lógica (verificar correo + establecer contraseña) es 100% client-side vía el
# Stimulus controller `account-verification`, que consume:
#   - PATCH /api/User/confirm-email/:otpCode
#   - PATCH /api/User/set-password/:otpCode?password=...
class AccountVerificationsController < ApplicationController
  # Se llega por link de correo, antes de existir cualquier sesión: el OTP de la
  # URL es la credencial y el backend es quien lo valida.
  skip_before_action :require_session

  # GET /account-verification/:otp_code
  def show
    @otp_code = params[:otp_code].to_s
  end
end

import { Controller } from '@hotwired/stimulus'
import { Storage, SStore } from 'vendor/clavisco/core'
import Swal from 'sweetalert2'
import { showLoading, hideLoading } from 'vendor/clavisco/overlay'

/**
 * AccountVerificationController — Verificación de cuenta por OTP.
 *
 * Migrado de Angular: VerificationEmailComponent (ruta /account-verification/:OTPCode).
 * Ruta Rails: /account-verification/:otp_code
 *
 * Flujo:
 *   1. connect(): cierra cualquier sesión activa y verifica el correo con el OTP.
 *      - PATCH /api/User/confirm-email/:otpCode
 *      - Éxito  → muestra la sección "Establecer contraseña" + toast de éxito.
 *      - Error  → redirige a /login.
 *   2. changePassword(): valida y establece la contraseña.
 *      - PATCH /api/User/set-password/:otpCode?password=...
 *      - Éxito  → toast de éxito + redirige a /login.
 *      - Error  → modal de error (operación de escritura, ver CLAUDE.md §9).
 */
export default class extends Controller {
  static targets = [
    'passwordSection',
    'password',
    'confirmPassword',
    'submitButton',
  ]

  static values = {
    otpCode:      { type: String, default: '' },
    redirectPath: { type: String, default: '/login' },
    // Límites de contraseña — mantener sincronizados con minlength/maxlength en show.html.erb
    minPasswordLength: { type: Number, default: 8 },
    maxPasswordLength: { type: Number, default: 40 },
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  connect() {
    // Cerrar sesión previa (equivalente a logoutVerificationEmail del legacy).
    Storage.remove('Session')        // sesión principal
    SStore.remove('currentFEUser')   // sesión FE Sync
    SStore.remove('CurrentCompany')  // compañía seleccionada

    if (!this.otpCodeValue) {
      this.#goToLogin()
      return
    }

    this.#confirmEmail()
  }

  // ── Verificación del correo ─────────────────────────────────────────────

  async #confirmEmail() {
    showLoading('Verificando el correo, espere por favor...')
    try {
      await this.#apiFetch(`/api/User/confirm-email/${encodeURIComponent(this.otpCodeValue)}`, {
        method: 'PATCH',
      })
      this.passwordSectionTarget.classList.remove('hidden')
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Correo verificado con éxito.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
    } catch {
      // El correo no se pudo verificar (OTP inválido/expirado) → volver al login.
      this.#goToLogin()
    } finally {
      hideLoading()
    }
  }

  // ── Establecer contraseña ───────────────────────────────────────────────

  async changePassword() {
    const password        = this.passwordTarget.value
    const confirmPassword  = this.confirmPasswordTarget.value

    if (!password || !confirmPassword) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Por favor complete todos los campos requeridos.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    if (password.length < this.minPasswordLengthValue) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: `La contraseña debe tener un mínimo de ${this.minPasswordLengthValue} caracteres.`,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    if (password.length > this.maxPasswordLengthValue) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: `La contraseña no puede superar ${this.maxPasswordLengthValue} caracteres.`,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    if (password !== confirmPassword) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Las contraseñas no coinciden.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    showLoading('Actualizando contraseña, espere por favor...')
    this.submitButtonTarget.disabled = true
    try {
      await this.#apiFetch(
        `/api/User/set-password/${encodeURIComponent(this.otpCodeValue)}?password=${encodeURIComponent(password)}`,
        { method: 'PATCH' }
      )
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Contraseña cambiada con éxito.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      this.#goToLogin()
    } catch (err) {
      await Swal.fire({
        icon: 'error',
        title: 'Error al establecer la contraseña',
        text: err.message || 'Error desconocido.',
        confirmButtonText: 'Aceptar'
      })
    } finally {
      this.submitButtonTarget.disabled = false
      hideLoading()
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  togglePassword(event) {
    const button = event.currentTarget
    const input  = button.parentElement.querySelector('input')
    const icon   = button.querySelector('.material-icons')
    if (!input) return
    const isPassword = input.type === 'password'
    input.type = isPassword ? 'text' : 'password'
    if (icon) icon.textContent = isPassword ? 'visibility' : 'visibility_off'
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  #goToLogin() {
    window.location.href = this.redirectPathValue
  }

  async #apiFetch(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(options.headers || {}),
      },
    })

    const clMessage = response.headers.get('cl-message')
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage) } catch { return clMessage }
    })() : null

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      let bodyMessage = null
      if (text) {
        try { bodyMessage = JSON.parse(text)?.Message || null } catch { /* no es JSON */ }
      }
      throw new Error(decodedMessage || bodyMessage || text || `HTTP ${response.status}`)
    }

    const hasBody = response.status !== 204 &&
                    response.headers.get('content-length') !== '0' &&
                    response.headers.get('content-type')?.includes('application/json')
    if (!hasBody) return { Message: decodedMessage || null }

    const json = await response.json()
    if (decodedMessage && !json.Message) json.Message = decodedMessage
    return json
  }
}

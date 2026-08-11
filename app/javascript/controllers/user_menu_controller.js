import { Controller } from '@hotwired/stimulus'

/**
 * UserMenuController — Menú de usuario del toolbar.
 *
 * Ícono de usuario alineado al final del toolbar:
 *  - Hover → tooltip con el nombre de usuario.
 *  - Click → menú flotante (mismo patrón que el context menu de compañía).
 *  - Opción "Perfil de usuario" → navega a /configurations/user-profile.
 *
 * El usuario NO se lee del browser: tras el cutover a OIDC la sesión vive en la
 * cookie httpOnly, así que el layout `protected` imprime nombre y correo (y ya la
 * inicial) desde el servidor y este controller solo aplica el color del avatar.
 * El toolbar NO es data-turbo-permanent: reconecta en cada visita Turbo, y los
 * values vienen con el HTML nuevo.
 */
export default class extends Controller {
  static targets = ['menu', 'tooltip', 'username', 'initial', 'avatar']
  static values  = { label: String, email: String }

  // Paleta de avatares — fondo tenue + letra oscura (misma familia que los
  // badges del proyecto). El color se elige por hash del correo: varía entre
  // usuarios pero es estable para el mismo (el toolbar reconecta en cada visita
  // Turbo, un color aleatorio por render parpadearía al navegar).
  static PALETTE = [
    { bg: '#e8f0fe', color: '#1a56db' }, // azul
    { bg: '#e8f5ee', color: '#065f46' }, // verde
    { bg: '#fffbeb', color: '#b45309' }, // ambar
    { bg: '#f5f3ff', color: '#6d28d9' }, // violeta
    { bg: '#fce7f3', color: '#9d174d' }, // rosa
    { bg: '#ccfbf1', color: '#115e59' }, // teal
    { bg: '#fff7ed', color: '#c2410c' }, // naranja
    { bg: '#e0e7ff', color: '#3730a3' }, // indigo
    { bg: '#cffafe', color: '#155e75' }, // cian
    { bg: '#fdecea', color: '#c0392b' }, // rojo
  ]

  #dismissHandler = null

  connect() {
    this.#setUsername()
  }

  disconnect() {
    this.#closeMenu()
  }

  toggle(event) {
    event.stopPropagation()
    if (!this.hasMenuTarget) return

    const isHidden = this.menuTarget.classList.contains('hidden')
    if (isHidden) this.#openMenu()
    else this.#closeMenu()
  }

  goToProfile() {
    this.#closeMenu()
    if (window.Turbo) window.Turbo.visit('/configurations/user-profile')
    else window.location.href = '/configurations/user-profile'
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  #setUsername() {
    // El servidor ya imprimió el texto; acá solo se cubre el caso de un value
    // vacío (sesión sin nombre ni correo) y se aplica el color del avatar.
    const label = this.labelValue
    if (this.hasUsernameTarget) this.usernameTarget.textContent = label
    if (this.hasTooltipTarget) this.tooltipTarget.textContent = label
    if (this.hasInitialTarget) this.initialTarget.textContent = label ? label.charAt(0).toUpperCase() : '?'
    this.#applyAvatarColor(this.emailValue || label)
  }

  /** Colorea el avatar con un tono de la paleta elegido por hash del correo. */
  #applyAvatarColor(seed) {
    const palette = this.constructor.PALETTE
    let hash = 0
    for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) | 0
    const { bg, color } = palette[Math.abs(hash) % palette.length]

    if (this.hasAvatarTarget) {
      this.avatarTarget.classList.remove('bg-gray-300')
      this.avatarTarget.style.backgroundColor = bg
    }
    if (this.hasInitialTarget) {
      this.initialTarget.classList.remove('text-gray-700')
      this.initialTarget.style.color = color
    }
  }

  #openMenu() {
    this.menuTarget.classList.remove('hidden')
    // Cerrar al hacer click en cualquier otro lugar
    this.#dismissHandler = () => this.#closeMenu()
    document.addEventListener('click', this.#dismissHandler, { once: true })
  }

  #closeMenu() {
    if (this.hasMenuTarget) this.menuTarget.classList.add('hidden')
    if (this.#dismissHandler) {
      document.removeEventListener('click', this.#dismissHandler)
      this.#dismissHandler = null
    }
  }
}

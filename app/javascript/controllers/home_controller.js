import { Controller } from '@hotwired/stimulus'
import { Storage, SStore, getApiHeaders } from 'vendor/clavisco/core'
import { showToast } from 'vendor/clavisco/alerts'

/**
 * HomeController — Dashboard principal.
 *
 * Responsabilidades:
 *  - Leer Session desde localStorage, CurrentCompany desde sessionStorage
 *  - Cargar Banner.json y aplicar lógica de visibilidad
 *  - Manejar acciones de banner: cerrar y ver URL
 *
 * Pendiente (cuando se implementen gráficos):
 *  - Llamar APIs de documentos/emails con companyId
 *  - Renderizar charts con Chart.js
 *  - Escuchar evento storage para cambio de empresa
 */
export default class extends Controller {
  static targets = [
    'banner',
    'bannerImage',
    'canvas1', 'canvas2', 'canvas3', 'canvas4', 'canvas5', 'canvas6',
    'chartPlaceholder1', 'chartPlaceholder2', 'chartPlaceholder3',
    'chartPlaceholder4', 'chartPlaceholder5', 'chartPlaceholder6',
    'emailCount',
    'docCount'
  ]

  static values = {
    bannerUrl: { type: String, default: '/banner.json' }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  connect() {
    this.#loadCurrentUser()
    this.#loadSelectedCompany()
    this.#loadBanner()
    this.#checkCertExpireAlarm()
  }

  // ---------------------------------------------------------------------------
  // Banner actions
  // ---------------------------------------------------------------------------

  /**
   * Cierra el banner y persiste la preferencia del usuario.
   * Equivalente Angular: CloseBanner()
   */
  closeBanner() {
    this.#hideBanner()
    this.#persistBannerVisibility(true)
  }

  /**
   * Abre la URL del banner en nueva pestaña y persiste la preferencia.
   * Equivalente Angular: ViewBanner()
   */
  viewBanner() {
    if (this.#bannerViewUrl) {
      window.open(this.#bannerViewUrl, '_blank')
    }
    this.#persistBannerVisibility(true)
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /** @type {string} */
  #currentUser = ''

  /** @type {{ companyId: string } | null} */
  #selectedCompany = null

  /** @type {string} */
  #bannerViewUrl = ''

  #loadCurrentUser() {
    const session = Storage.get('Session')
    this.#currentUser = session?.UserEmail ?? ''
  }

  #loadSelectedCompany() {
    this.#selectedCompany = SStore.get('CurrentCompany')
  }

  async #loadBanner() {
    try {
      const response = await fetch(this.bannerUrlValue)
      if (!response.ok) return

      const data = await response.json()
      const bannerData = data?.Data?.[0]
      if (!bannerData) return

      if (!bannerData.Visible) return

      // Comprobar si el usuario ya cerró el banner y aún no expiró
      if (this.#isBannerSuppressedForUser()) return

      // Mostrar banner
      this.#bannerViewUrl = bannerData.ViewUrl ?? ''

      if (this.hasBannerImageTarget) {
        this.bannerImageTarget.src = bannerData.ImgBanner ?? ''
      }

      this.#showBanner()

      // Persistir visibilidad inicial
      this.#persistBannerVisibility(bannerData.Visible)
    } catch (error) {
      // Banner no disponible — no bloquear la carga de la página
      console.warn('[HomeController] No se pudo cargar el banner:', error)
    }
  }

  /**
   * Determina si el banner debe suprimirse para el usuario actual.
   * Lógica equivalente al Angular StorageService.GetBannerVisibilityByUser:
   *   - Si existe un entry para el usuario Y ExpiredDate > hoy → suprimir
   *
   * @returns {boolean}
   */
  #isBannerSuppressedForUser() {
    const bannerUsers = Storage.get('BannerUser')
    if (!Array.isArray(bannerUsers)) return false

    const entry = bannerUsers.find((u) => u.currentUser === this.#currentUser)
    if (!entry) return false

    const expiredDate = new Date(entry.ExpiredDate)
    const today = new Date()

    // Si la fecha de expiración es futura → el usuario cerró el banner y aún no caducó
    return expiredDate > today
  }

  /**
   * Persiste la preferencia de visibilidad del banner para el usuario actual.
   * Equivalente Angular: StorageService.SetBannerVisibilityByUser
   *
   * @param {boolean} visibility
   */
  #persistBannerVisibility(visibility) {
    const today = new Date()
    const expirationDate = new Date(today)
    expirationDate.setDate(expirationDate.getDate() + 1)

    let bannerUsers = Storage.get('BannerUser')
    if (!Array.isArray(bannerUsers)) bannerUsers = []

    const existingIndex = bannerUsers.findIndex((u) => u.currentUser === this.#currentUser)
    const entry = {
      currentUser: this.#currentUser,
      BannerVisibility: visibility,
      ExpiredDate: expirationDate.toISOString()
    }

    if (existingIndex >= 0) {
      bannerUsers[existingIndex] = entry
    } else {
      bannerUsers.push(entry)
    }

    Storage.set('BannerUser', bannerUsers)
  }

  /**
   * Consulta la alarma de vencimiento de certificado para la empresa activa
   * y muestra un toast de advertencia si el certificado esta proximo a vencer.
   *
   * Endpoint nativo de Rails: GET /api/certificate_alarm. El companyId NO viaja
   * — la compañía activa la lee el servidor de la session cookie (CLAUDE.md §28).
   * Reemplaza GET /api/Companies/GetCertExpireDateAlarm?companyId=N del .NET.
   *
   * `Data` es un objeto, no el arreglo de un elemento que devolvia el SP: por eso
   * el Angular leia `data.Data.ShowAlarm` sobre un arreglo y siempre obtenia
   * undefined.
   *
   * Cambio de empresa: company_selector_controller hace window.location.reload(),
   * por lo que connect() se vuelve a ejecutar y la alarma se reevalua con la
   * nueva empresa seleccionada.
   */
  async #checkCertExpireAlarm() {
    // Sin compañía activa no hay certificado que revisar, y el endpoint
    // responderia 404: se evita el toast de error en la primera carga.
    if (!this.#selectedCompany?.companyId) return

    try {
      const json = await this.#apiFetch('/api/certificate_alarm')

      if (json?.Data?.ShowAlarm) {
        showToast(json.Data.SmsAlert, 'warning')
      }
    } catch (error) {
      showToast(
        error.message || 'Error al obtener la fecha de expiracion del certificado',
        'error'
      )
    }
  }

  /**
   * Fetch contra el API nativo de Rails. Sin header Authorization: los endpoints
   * migrados se autentican con la session cookie (CLAUDE.md §28), y el mensaje de
   * error viene en el cuerpo (`Message`), no en el header `cl-message`.
   */
  async #apiFetch(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        'Accept': 'application/json',
        ...getApiHeaders(),
        ...(options.headers || {}),
      },
    })

    if (!response.ok) {
      const body = await response.json().catch(() => null)
      throw new Error(body?.Message || `HTTP ${response.status}`)
    }

    return response.json()
  }

  #showBanner() {
    if (this.hasBannerTarget) {
      this.bannerTarget.classList.remove('hidden')
    }
  }

  #hideBanner() {
    if (this.hasBannerTarget) {
      this.bannerTarget.classList.add('hidden')
    }
  }
}

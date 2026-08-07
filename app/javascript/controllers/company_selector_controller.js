import { Controller } from '@hotwired/stimulus'
import { TabulatorFull } from 'tabulator-tables'
import { SStore, getApiHeaders } from 'vendor/clavisco/core'
import { showToast } from 'vendor/clavisco/alerts'
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale'

/**
 * CompanySelectorController — Panel lateral de selección de empresa.
 *
 * Responsabilidades:
 *  - Mostrar nombre de empresa seleccionada en el toolbar
 *  - Abrir panel lateral con lista filtrable de empresas
 *  - Al cambiar empresa: guardar en localStorage, recargar permisos, reload
 *  - Abrir automáticamente si no hay empresa seleccionada al cargar
 */
export default class extends Controller {
  static targets = [
    'panel',
    'panelBackdrop',
    'pageLoader',
    'toolbarLabel',
    'searchInput',
    'table',
    'panelLoader',
    'cancelBtn',
    'confirmBtn',
    'contextMenu'
  ]

  /** @type {Array} Lista completa de empresas cargadas */
  #companies = []

  /** @type {boolean} La última carga de compañías falló */
  #loadFailed = false

  /** @type {object|null} Empresa seleccionada en el UI (pendiente de confirmar) */
  #pendingSelection = null

  /** @type {import('tabulator-tables').Tabulator|null} Instancia de la tabla */
  #table = null

  /** @type {Function|null} Handler de click global para cerrar el context menu */
  #contextMenuDismissHandler = null

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  connect() {
    this.#updateToolbarLabel()

    // Sin compañía seleccionada se abre el panel para que elija. Ya no hay
    // preselección automática: la compañía favorita vivía en
    // localStorage['FavoriteCompany'] y el esquema nuevo no la modela.
    if (!SStore.get('CurrentCompany')?.companyId) this.open()
  }

  disconnect() {
    this.#table?.destroy()
    this.#table = null
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  open() {
    this.#pendingSelection = null
    this.#resetInput()
    this.#showCancelIfApplicable()
    this.#setConfirmDisabled(true)
    this.#showModal()
    this.#loadCompanies()
  }

  close() {
    const company = SStore.get('CurrentCompany')
    // Solo permitir cerrar si ya hay una empresa seleccionada
    if (!company?.companyId) return
    this.#hideModal()
  }

  overlayClick() {
    this.close()
  }

  filter() {
    if (!this.#table) return
    const query = this.searchInputTarget.value.toLowerCase().trim()
    if (!query) {
      this.#table.clearFilter()
      return
    }
    this.#table.setFilter(row => (row.Name ?? '').toLowerCase().includes(query))
  }

  confirm() {
    if (!this.#pendingSelection) return

    const current = SStore.get('CurrentCompany')

    // Misma empresa → solo cerrar
    if (current?.companyId === this.#pendingSelection.Id) {
      this.#hideModal()
      return
    }

    this.#applyCompanyChange(this.#pendingSelection)
  }

  /**
   * Click derecho en el botón de compañía.
   * Solo muestra el menú si el usuario tiene F_ModifyCompany.
   */
  onContextMenu(event) {
    event.preventDefault()

    const permissions = SStore.get('Permissions') ?? []
    if (!permissions.includes('F_ModifyCompany')) return
    if (!this.hasContextMenuTarget) return

    this.contextMenuTarget.classList.remove('hidden')

    // Cerrar al hacer click en cualquier otro lugar
    this.#contextMenuDismissHandler = () => this.#closeContextMenu()
    document.addEventListener('click', this.#contextMenuDismissHandler, { once: true })
  }

  navigateToCompanyEdit() {
    this.#closeContextMenu()
    const company = SStore.get('CurrentCompany')
    if (!company?.companyId) return
    Turbo.visit(`/configurations/companies/${company.companyId}/edit`)
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  #closeContextMenu() {
    if (!this.hasContextMenuTarget) return
    this.contextMenuTarget.classList.add('hidden')
    if (this.#contextMenuDismissHandler) {
      document.removeEventListener('click', this.#contextMenuDismissHandler)
      this.#contextMenuDismissHandler = null
    }
  }

  #updateToolbarLabel() {
    if (!this.hasToolbarLabelTarget) return
    const company = SStore.get('CurrentCompany')
    this.toolbarLabelTarget.textContent = company?.companyName ?? 'No seleccionada'

    // Tooltip con ID
    const btn = this.toolbarLabelTarget.closest('button')
    if (btn && company?.companyId) {
      btn.title = `Identificador: ${company.companyId}`
    }
  }

  #showCancelIfApplicable() {
    if (!this.hasCancelBtnTarget) return
    const company = SStore.get('CurrentCompany')
    if (company?.companyId) {
      this.cancelBtnTarget.classList.remove('hidden')
    } else {
      this.cancelBtnTarget.classList.add('hidden')
    }
  }

  #showModal() {
    if (!this.hasPanelTarget) return
    this.panelBackdropTarget.classList.remove('hidden')
    this.panelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  #hideModal() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.add('translate-x-full')
    this.panelBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
  }

  #resetInput() {
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ''
    this.#table?.clearFilter()
    this.#clearSelection()
  }

  #setConfirmDisabled(disabled) {
    if (!this.hasConfirmBtnTarget) return
    this.confirmBtnTarget.disabled = disabled
  }

  #initTable() {
    if (this.#table || !this.hasTableTarget) return

    this.#table = new TabulatorFull(this.tableTarget, {
      height:            '100%',
      layout:            'fitColumns',
      placeholder:       'Sin resultados',
      locale:            TABULATOR_LOCALE,
      langs:             TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: {
        headerSort: true,
        // cellClick es el mecanismo de clic probado en el proyecto (Tabulator no
        // dispara rowClick de forma fiable en este build); cubre toda la fila.
        cellClick:    (_e, cell) => this.#selectRow(cell.getRow()),
        cellDblClick: (_e, cell) => { this.#selectRow(cell.getRow()); this.confirm() },
      },
      columns: [
        { title: 'Compañía', field: 'Name', widthGrow: 1 },
      ],
    })
  }

  /** Marca una fila como seleccionada (resaltado + estado pendiente). */
  #selectRow(row) {
    this.#table?.getRows().forEach(r => { r.getElement().style.backgroundColor = '' })
    row.getElement().style.backgroundColor = '#dbeafe' // blue-100
    this.#pendingSelection = row.getData()
    this.#setConfirmDisabled(false)
  }

  /** Limpia la selección y su resaltado. */
  #clearSelection() {
    this.#pendingSelection = null
    this.#table?.getRows().forEach(r => { r.getElement().style.backgroundColor = '' })
    this.#setConfirmDisabled(true)
  }

  /**
   * GET /api/companies — endpoint nativo de Rails. Devuelve solo las compañías
   * asignadas al usuario de la sesión, así que no lleva filtros ni estado.
   * Separado del render porque connect() lo necesita antes de abrir el panel,
   * para saber si hay una favorita que aplicar sola.
   * @returns {Promise<Array>}
   */
  async #fetchCompanies() {
    try {
      const response = await fetch('/api/companies', { headers: getApiHeaders() })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const data = await response.json()
      this.#companies = data?.Data ?? []
      this.#loadFailed = false
    } catch (error) {
      console.error('[CompanySelector] Error cargando compañías:', error)
      this.#companies  = []
      this.#loadFailed = true
    }
    return this.#companies
  }

  async #loadCompanies() {
    this.#initTable()
    this.#showPanelLoader()

    try {
      // Reutiliza lo que connect() ya trajo; solo va a la red si no hay nada.
      if (!this.#companies.length) await this.#fetchCompanies()

      await this.#table.setData(this.#companies)
      if (this.#loadFailed) this.#table?.alert('Error al cargar compañías', 'error')
      // El panel entra con translate-x; forzamos redibujado para que calcule la altura
      requestAnimationFrame(() => this.#table?.redraw(true))
    } finally {
      this.#hidePanelLoader()
      // Una vez cargadas las empresas, enfocar el input de búsqueda
      if (this.hasSearchInputTarget) {
        requestAnimationFrame(() => this.searchInputTarget.focus())
      }
    }
  }

  #showPanelLoader() {
    if (this.hasPanelLoaderTarget) this.panelLoaderTarget.classList.remove('hidden')
  }

  #hidePanelLoader() {
    if (this.hasPanelLoaderTarget) this.panelLoaderTarget.classList.add('hidden')
  }

  async #applyCompanyChange(company) {
    this.#setConfirmDisabled(true)
    this.#hideModal()
    if (this.hasPageLoaderTarget) this.pageLoaderTarget.classList.remove('hidden')

    // 1. La compañía activa es estado de SESIÓN: se guarda en el servidor. De ahí la
    //    leen require_permission! y require_view_permission!, que no miran el browser.
    const saved = await this.#setCurrentCompany(company.Id)
    if (!saved) {
      if (this.hasPageLoaderTarget) this.pageLoaderTarget.classList.add('hidden')
      return
    }

    // 2. Copia local solo para DISPLAY (nombre en el toolbar). No es la fuente de
    //    verdad; el servidor ya sabe cuál compañía está activa.
    SStore.set('CurrentCompany', {
      companyName: company.Name,
      companyId:   company.Id,
      companyUuid: company.Uuid,
      sapDbCode:   company.SapDbCode
    })

    // 3. Recargar permisos de la nueva compañía
    sessionStorage.removeItem('Permissions')
    await this.#reloadPermissions()

    // 4. Recargar página
    window.location.reload()
  }

  /**
   * PUT /api/session/company — fija la compañía activa en la session cookie.
   * El servidor rechaza con 403 cualquier compañía no asignada al usuario.
   * @returns {Promise<boolean>} true si quedó guardada.
   */
  async #setCurrentCompany(companyId) {
    try {
      const response = await fetch('/api/session/company', {
        method:  'PUT',
        headers: getApiHeaders(),
        body:    JSON.stringify({ company_id: companyId }),
      })

      if (response.ok) return true

      const body = await response.json().catch(() => ({}))
      showToast(body?.Message || 'No se pudo seleccionar la compañía.', 'error')
      return false
    } catch (error) {
      showToast(`No se pudo seleccionar la compañía: ${error.message}`, 'error')
      return false
    }
  }

  // #reloadFEToken se eliminó: pedía credenciales al App server .NET, hacía un
  // segundo login contra el servidor FE Sync y guardaba ESE token en
  // sessionStorage.currentFEUser. Eran las dos cosas que este cutover elimina —
  // un token accesible desde JS (prohibido por §2.3) y una segunda autenticación
  // paralela, cuando ahora hay una sola sesión creada por el IdP.

  /**
   * GET /api/permissions — permisos efectivos en la compañía activa.
   * No recibe companyId: el servidor la toma de la sesión.
   */
  async #reloadPermissions() {
    try {
      const response = await fetch('/api/permissions', { headers: getApiHeaders() })
      if (!response.ok) return
      const data = await response.json()
      const perms = (data?.Data ?? []).map(p => p.Name)
      SStore.set('Permissions', perms)
    } catch {
      // Permisos se cargarán en el siguiente connect() del menu_controller
    }
  }
}

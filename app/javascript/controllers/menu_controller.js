import { Controller } from '@hotwired/stimulus'
import { Storage, SStore, getApiHeaders } from 'vendor/clavisco/core'
import { confirm } from 'vendor/clavisco/alerts'
import { notifySessionClosed, thereAreMultipleContexts, clearSession } from 'vendor/clavisco/session-sync'
import MENU_NODES from 'data/menu'

/**
 * MenuController — Sidebar del layout protegido.
 *
 * El <aside> que lo monta es `data-turbo-permanent`: Turbo conserva ese nodo DOM
 * entre visitas y Stimulus NO reconecta este controller. Por eso `#expandedGroups`
 * vive en memoria y los nodos padre expandidos sobreviven a la navegación —
 * el mismo modelo de shell persistente que el app.component de Angular, sin
 * necesidad de persistir el estado en storage.
 *
 * Implicaciones del montaje en el <aside>:
 *  - `connect()` corre UNA sola vez por sesión de página (no en cada navegación).
 *    Solo se vuelve a ejecutar tras un reload real (F5, cambio de empresa, login).
 *  - El botón de toggle vive en el toolbar, FUERA del scope de este controller →
 *    se enlaza con un listener delegado en `document` (sobrevive a los swaps de Turbo).
 *  - El resaltado de la opción activa se recalcula en cada `turbo:load` porque el
 *    menú ya no se re-renderiza al navegar.
 *
 * Responsabilidades:
 *  - Renderizar nodos del menú según permisos del usuario (una sola vez)
 *  - Toggle collapse del sidebar
 *  - Navegación entre rutas vía Turbo Drive (sin full reload)
 *  - Resaltar la opción activa y abrir su grupo padre
 *  - Logout (limpia sesión y redirige a /login)
 *  - Mostrar username
 */
export default class extends Controller {
  static targets = ['nav']

  // ---------------------------------------------------------------------------
  // Definición del menú — single source of truth en docs/menu.json
  // ---------------------------------------------------------------------------
  static MENU_NODES = MENU_NODES

  // Estado interno de grupos expandidos — sobrevive en memoria (aside permanente)
  #expandedGroups = new Set()

  // Handlers enlazados (para poder removerlos en disconnect)
  #onToggleClick = null
  #onTurboLoad = null

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  connect() {
    // Al navegar, Turbo reemplaza el <body> y mueve el <aside> permanente al
    // nuevo body; Stimulus trata ese movimiento como una reconexión y vuelve a
    // ejecutar connect(). El nodo permanente CONSERVA el DOM del menú (con los
    // grupos abiertos), así que capturamos qué grupos estaban expandidos ANTES
    // de re-renderizar para no perder la expansión. Sin esto, el menú colapsa
    // en cada navegación pese a ser data-turbo-permanent.
    this.#captureExpandedFromDom()

    this.#restoreCollapseState()
    this.#loadPermissionsAndRender()

    // Toggle del sidebar: el botón está en el toolbar (fuera de este scope).
    // Listener delegado en document → resiste los reemplazos de body de Turbo.
    this.#onToggleClick = (event) => {
      if (event.target.closest('[data-menu-toggle]')) this.toggleSidebar()
    }
    document.addEventListener('click', this.#onToggleClick)

    // El menú no se re-renderiza al navegar: refrescar el resaltado en cada visita.
    this.#onTurboLoad = () => this.#highlightActive()
    document.addEventListener('turbo:load', this.#onTurboLoad)
  }

  disconnect() {
    if (this.#onToggleClick) document.removeEventListener('click', this.#onToggleClick)
    if (this.#onTurboLoad) document.removeEventListener('turbo:load', this.#onTurboLoad)
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  toggleSidebar() {
    const collapsed = this.element.dataset.collapsed === 'true'
    // Al contraer, plegar también los nodos padre expandidos para que el riel
    // quede consistente (y al re-expandir el sidebar aparezcan cerrados).
    if (!collapsed) this.#collapseAllGroups()
    this.#setCollapsed(!collapsed)
    Storage.set('menuState', { isCollapsed: !collapsed })
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  #restoreCollapseState() {
    const state = Storage.get('menuState')
    if (state?.isCollapsed) this.#setCollapsed(true)
  }

  /**
   * Reconstruye #expandedGroups a partir del DOM ya renderizado (preservado por
   * el <aside> permanente). Se llama al inicio de connect() para que un reconnect
   * de Turbo no pierda los grupos que el usuario tenía abiertos.
   */
  #captureExpandedFromDom() {
    if (!this.hasNavTarget) return
    this.navTarget.querySelectorAll('[data-group]').forEach(sub => {
      if (sub.dataset.group && !sub.classList.contains('hidden')) {
        this.#expandedGroups.add(sub.dataset.group)
      }
    })
  }

  #setCollapsed(collapsed) {
    // this.element ES el <aside> (el controller se monta directo sobre el sidebar).
    this.element.dataset.collapsed = String(collapsed)

    if (collapsed) {
      this.element.classList.replace('w-64', 'w-16')
    } else {
      this.element.classList.replace('w-16', 'w-64')
    }
  }

  async #loadPermissionsAndRender() {
    const company  = SStore.get('CurrentCompany')
    let permissions = SStore.get('Permissions') // array de strings — sessionStorage (per-tab)

    // Si no hay permisos en caché, cargarlos del API. Se sigue exigiendo compañía
    // seleccionada: sin ella el servidor no tiene con qué resolver los roles y
    // devolvería una lista vacía que se cachearía como "sin permisos".
    if (!permissions && company?.companyId) {
      permissions = await this.#fetchPermissions()
    }

    const permSet = new Set(Array.isArray(permissions) ? permissions : [])
    this.#renderMenu(permSet)
  }

  /**
   * GET /api/permissions — endpoint nativo de Rails, lee de las tablas propias
   * (user_roles → role_permissions → permissions). No recibe companyId: la
   * compañía activa vive en la session cookie del servidor (§2.4), así que el
   * cliente no puede pedir los permisos de otra.
   */
  async #fetchPermissions() {
    try {
      const response = await fetch('/api/permissions', { headers: getApiHeaders() })
      if (!response.ok) return []
      const data = await response.json()
      const perms = (data?.Data ?? []).map(p => p.Name)
      SStore.set('Permissions', perms)
      return perms
    } catch {
      return []
    }
  }

  /**
   * Aplica lógica de visibilidad idéntica a menu.service.ts
   * @param {Set<string>} permSet
   */
  #buildVisibleNodes(permSet) {
    return this.constructor.MENU_NODES.map(node => {
      // home y logout siempre visibles
      if (node.key === 'home' || node.key === 'logout') {
        return { ...node, visible: true }
      }

      const hasPermission = (req) => {
        // Sin permiso requerido = nodo público (visible para todos).
        // Ej.: "Perfil de usuario" — accesible sin permiso asignado.
        if (!req) return true
        return Array.isArray(req)
          ? req.some(p => permSet.has(p))
          : permSet.has(req)
      }

      // Nodos hijo visibles
      const visibleChildren = (node.nodes ?? []).filter(child =>
        hasPermission(child.requiredPermission)
      )

      // Padre visible si tiene su propio permiso O algún hijo tiene permiso
      const parentVisible = hasPermission(node.requiredPermission) || visibleChildren.length > 0

      return {
        ...node,
        visible: parentVisible,
        nodes: visibleChildren
      }
    })
  }

  /**
   * ¿El nodo está bloqueado por una propiedad de la compañía seleccionada?
   * (p.ej. `requiredCompanyFlag: 'UseFactProv'`). Solo bloquea si hay compañía
   * seleccionada y la propiedad está desactivada — mismo criterio que auth_guard.
   */
  #isCompanyFlagBlocked(node) {
    if (!node.requiredCompanyFlag) return false
    const company = SStore.get('CurrentCompany')
    return !!company?.companyId && !company[node.requiredCompanyFlag]
  }

  #renderMenu(permSet) {
    if (!this.hasNavTarget) return
    const nodes = this.#buildVisibleNodes(permSet)
    this.navTarget.innerHTML = ''

    nodes.forEach(node => {
      if (!node.visible) return
      const el = this.#createNodeElement(node)
      this.navTarget.appendChild(el)
    })

    // Tras el render inicial, resaltar la ruta actual y abrir su grupo padre.
    this.#highlightActive()
  }

  #createNodeElement(node) {
    const hasChildren = node.nodes?.length > 0

    const wrapper = document.createElement('div')

    // Botón del ítem principal
    const btn = document.createElement('button')
    btn.dataset.testid = `menu-item-${node.key}`
    btn.className = [
      'w-full flex items-center gap-3 px-4 py-2.5 text-sm text-gray-300',
      'hover:bg-gray-700 hover:text-white transition-colors text-left'
    ].join(' ')

    // Icono
    if (node.icon) {
      const icon = document.createElement('span')
      icon.className = 'material-icons text-lg flex-shrink-0'
      icon.textContent = node.icon
      btn.appendChild(icon)
    }

    // Label (oculto cuando sidebar colapsa)
    const label = document.createElement('span')
    label.className = 'truncate flex-1 sidebar-label'
    label.textContent = node.label
    btn.appendChild(label)

    if (hasChildren) {
      // Estado inicial del grupo: respeta lo que ya estaba expandido (memoria/DOM)
      const expanded = this.#expandedGroups.has(node.key)

      // Chevron — se agrega al btn antes de crear subList
      const chevron = document.createElement('span')
      chevron.className = 'material-icons text-base transition-transform sidebar-label'
      chevron.textContent = 'chevron_right'
      chevron.dataset.chevron = node.key
      if (expanded) chevron.style.transform = 'rotate(90deg)'
      btn.appendChild(chevron)

      // subList declarado aquí para que el listener lo capture en su closure
      const subList = document.createElement('div')
      subList.className = 'bg-gray-800 pl-4'
      if (!expanded) subList.classList.add('hidden')
      subList.dataset.group = node.key

      btn.addEventListener('click', () => this.#onGroupClick(node.key, subList, chevron))

      node.nodes.forEach(child => {
        const childBtn = document.createElement('button')
        childBtn.dataset.testid = `menu-item-${child.key}`
        childBtn.textContent = child.label

        // Nodo bloqueado por flag de compañía (p.ej. UseFactProv): se DESHABILITA
        // (gris, no navegable) con tooltip explicativo — no se oculta.
        if (this.#isCompanyFlagBlocked(child)) {
          childBtn.className = [
            'w-full flex items-center gap-3 px-4 py-2 text-sm text-gray-600',
            'cursor-not-allowed text-left'
          ].join(' ')
          childBtn.title = 'Opción no disponible: la compañía seleccionada no tiene habilitada la facturación de proveedor.'
          subList.appendChild(childBtn)
          return
        }

        // data-route habilita el resaltado de la opción activa (#highlightActive)
        if (child.route) childBtn.dataset.route = child.route
        childBtn.className = [
          'w-full flex items-center gap-3 px-4 py-2 text-sm text-gray-400',
          'hover:bg-gray-700 hover:text-white transition-colors text-left'
        ].join(' ')
        childBtn.addEventListener('click', () => this.#navigate(child))
        subList.appendChild(childBtn)
      })

      wrapper.appendChild(btn)
      wrapper.appendChild(subList)
    } else {
      if (node.route) {
        btn.dataset.route = node.route
        btn.addEventListener('click', () => this.#navigate(node))
      }
      wrapper.appendChild(btn)
    }

    return wrapper
  }

  /**
   * Click en un nodo padre. Si el sidebar está colapsado, los hijos (solo texto,
   * sin icono) no caben en el riel de 64px: primero expandimos el sidebar y luego
   * abrimos el grupo, en vez de mostrar texto recortado/envuelto.
   */
  #onGroupClick(key, subList, chevron) {
    if (this.element.dataset.collapsed === 'true') {
      this.#setCollapsed(false)
      Storage.set('menuState', { isCollapsed: false })
      this.#openGroup(key, subList, chevron)
      return
    }
    this.#toggleGroup(key, subList, chevron)
  }

  #openGroup(key, subList, chevron) {
    this.#expandedGroups.add(key)
    subList.classList.remove('hidden')
    if (chevron) chevron.style.transform = 'rotate(90deg)'
  }

  /** Pliega todos los grupos abiertos (usado al contraer el sidebar). */
  #collapseAllGroups() {
    if (!this.hasNavTarget) return
    this.navTarget.querySelectorAll('[data-group]').forEach(subList => {
      subList.classList.add('hidden')
      const key = subList.dataset.group
      const chevron = this.navTarget.querySelector(`[data-chevron="${key}"]`)
      if (chevron) chevron.style.transform = ''
    })
    this.#expandedGroups.clear()
  }

  #toggleGroup(key, subList, chevron) {
    if (this.#expandedGroups.has(key)) {
      this.#expandedGroups.delete(key)
      subList.classList.add('hidden')
      if (chevron) chevron.style.transform = ''
    } else {
      this.#openGroup(key, subList, chevron)
    }
  }

  /**
   * Resalta la opción cuya ruta coincide con la URL actual y, si está dentro de
   * un grupo colapsado, lo expande. Se llama tras el render y en cada turbo:load.
   */
  #highlightActive() {
    if (!this.hasNavTarget) return

    const path = window.location.pathname
    const ACTIVE = ['bg-gray-700', 'text-white']

    // Limpiar resaltado previo
    this.navTarget.querySelectorAll('[data-route]').forEach(b => b.classList.remove(...ACTIVE))

    const active = this.navTarget.querySelector(`[data-route="${path}"]`)
    if (!active) return
    active.classList.add(...ACTIVE)

    // Si la opción activa vive en un grupo colapsado, abrirlo.
    const subList = active.closest('[data-group]')
    if (subList && subList.classList.contains('hidden')) {
      const key = subList.dataset.group
      const chevron = this.navTarget.querySelector(`[data-chevron="${key}"]`)
      this.#toggleGroup(key, subList, chevron)
    }
  }

  #navigate(node) {
    if (node.key === 'logout') {
      this.#logout()
      return
    }
    if (!node.route) return

    // Turbo Drive: navega sin full reload, así el <aside> permanente conserva
    // su instancia y el estado de grupos expandidos. Fallback defensivo a location.
    if (window.Turbo) {
      window.Turbo.visit(node.route)
    } else {
      window.location.href = node.route
    }
  }

  async #logout() {
    const multiple = await thereAreMultipleContexts()

    const message = multiple
      ? 'Se han detectado múltiples pestañas abiertas. Al continuar se cerrará la sesión en todas ellas.'
      : '¿Está seguro de que desea cerrar sesión?'
    const title = multiple ? 'Múltiples pestañas abiertas' : 'Cerrar sesión'

    const confirmed = await confirm(message, title)
    if (!confirmed) return

    // Notificar a las demás pestañas antes de limpiar (flujo B del análisis)
    if (multiple) notifySessionClosed()

    // clearSession solo borra datos de display del browser; la sesión real (y el
    // token) viven en la cookie httpOnly y los invalida /auth/logout con
    // reset_session, que además cierra sesión en el proveedor OIDC.
    clearSession()
    window.location.href = '/auth/logout'
  }
}

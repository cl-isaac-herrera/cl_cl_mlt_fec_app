import { Controller } from '@hotwired/stimulus'
import { SStore, getApiHeaders } from 'vendor/clavisco/core'
import MENU_NODES from 'data/menu'

// Mapa plano ruta → permiso(s) requerido(s), construido una sola vez desde menu.js.
const ROUTE_PERMISSION_MAP = (() => {
  const map = {}
  for (const node of MENU_NODES) {
    if (node.route && node.requiredPermission) map[node.route] = node.requiredPermission
    for (const child of node.nodes ?? []) {
      if (child.route && child.requiredPermission) map[child.route] = child.requiredPermission
    }
  }
  return map
})()

// Rutas DINÁMICAS (con :id u otros segmentos variables) que no viven en menu.js
// pero requieren permiso al navegar manualmente por URL. Se evalúan por patrón
// cuando no hay match exacto en ROUTE_PERMISSION_MAP. `permission` acepta string
// o array (misma semántica: se permite si el usuario tiene AL MENOS uno).
const ROUTE_PATTERN_PERMISSIONS = [
  // Crear factura de proveedor desde un documento recepcionado:
  // /documents/receptions/:id/create?xmlDocType=...
  { pattern: /^\/documents\/receptions\/[^/]+\/create\/?$/, permission: 'F_CreateAPInvoice' },
  // Crear compañía: /configurations/companies/new
  { pattern: /^\/configurations\/companies\/new\/?$/, permission: 'Configurations_Companies_Create' },
  // Editar compañía: /configurations/companies/:id/edit
  { pattern: /^\/configurations\/companies\/[^/]+\/edit\/?$/, permission: 'Configurations_Companies_Update' },
]

// Rutas que además requieren que la compañía seleccionada (SStore.CurrentCompany)
// tenga una PROPIEDAD/flag activa (independiente de permisos). Se valida al navegar
// manualmente por URL. `flag` es el nombre de la propiedad en CurrentCompany.
const ROUTE_COMPANY_FLAG_MAP = {
  // UDFs solo aplica si la compañía usa factura de proveedor
  '/configurations/udfs': 'UseFactProv',
}
const ROUTE_COMPANY_FLAG_PATTERNS = [
  // Crear factura de proveedor desde un documento recepcionado
  { pattern: /^\/documents\/receptions\/[^/]+\/create\/?$/, flag: 'UseFactProv' },
]

/**
 * AuthGuardController — gating de PERMISOS por ruta (no de sesión).
 *
 * La autenticación ya no se valida acá: la sesión vive en la cookie httpOnly y
 * ApplicationController#require_session redirige antes de renderizar. Si este
 * controller corre, el usuario ya está autenticado por el servidor.
 *
 * Responsabilidades restantes:
 *  - Validar el permiso requerido por la ruta actual (y flags de compañía).
 *  - Revelar el contenido (`[data-auth-content]` nace `invisible`) una vez validado.
 */
export default class extends Controller {
  connect() {
    this.#checkRoutePermission()
  }

  // -------------------------------------------------------------------------
  // Private
  // -------------------------------------------------------------------------

  async #checkRoutePermission() {
    const path = window.location.pathname
    // 1) match exacto (rutas estáticas de menu.js); 2) match por patrón (rutas dinámicas)
    const requiredPerm = ROUTE_PERMISSION_MAP[path]
      ?? ROUTE_PATTERN_PERMISSIONS.find(r => r.pattern.test(path))?.permission

    const requiredFlag = ROUTE_COMPANY_FLAG_MAP[path]
      ?? ROUTE_COMPANY_FLAG_PATTERNS.find(r => r.pattern.test(path))?.flag

    // Ruta sin restricciones → mostrar
    if (!requiredPerm && !requiredFlag) {
      this.#revealContent()
      return
    }

    // Flag de compañía (propiedad de CurrentCompany, p.ej. UseFactProv). Solo se
    // bloquea si hay compañía seleccionada y la propiedad está desactivada — igual
    // criterio que el permiso (sin compañía no se puede validar todavía).
    if (requiredFlag) {
      const company = SStore.get('CurrentCompany')
      if (company?.companyId && !company[requiredFlag]) {
        this.#redirectNotFound()
        return
      }
    }

    if (requiredPerm) {
      let permissions = SStore.get('Permissions')

      // Si no hay caché (primera carga o nueva pestaña), cargarlos del API.
      // Mismo patrón que menu_controller — el segundo en correr encontrará el caché.
      if (!permissions) {
        const company = SStore.get('CurrentCompany')
        if (!company?.companyId) {
          this.#revealContent()
          return
        }
        permissions = await this.#fetchPermissions()
      }

      const permSet = new Set(Array.isArray(permissions) ? permissions : [])
      const hasPerm = Array.isArray(requiredPerm)
        ? requiredPerm.some(p => permSet.has(p))
        : permSet.has(requiredPerm)

      if (!hasPerm) {
        this.#redirectNotFound()
        return
      }
    }

    this.#revealContent()
  }

  #redirectNotFound() {
    if (window.Turbo) {
      window.Turbo.visit('/not-found')
    } else {
      window.location.href = '/not-found'
    }
  }

  #revealContent() {
    document.querySelectorAll('[data-auth-content]').forEach(el => el.classList.remove('invisible'))
    const meta = document.querySelector('meta[name="x-page-title"]')
    document.title = meta ? meta.content : 'Factura Electrónica'
  }

  /**
   * GET /api/permissions — endpoint nativo de Rails, lee de las tablas propias
   * (user_roles → role_permissions → permissions). No recibe companyId: la
   * compañía activa vive en la session cookie del servidor (§2.4).
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

}

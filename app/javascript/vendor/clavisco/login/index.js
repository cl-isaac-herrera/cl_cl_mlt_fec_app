/**
 * @clavisco/login — servicio de autenticación.
 *
 * La app NO autentica en el browser: la identidad la confirma el proveedor OIDC y
 * la sesión (con el token) vive en la cookie httpOnly de Rails. Este módulo por lo
 * tanto NO recibe credenciales, NO escribe tokens y NO decide si hay sesión — solo
 * dispara los flujos del servidor (`/auth/login`, `/auth/logout`) y expone datos de
 * display cacheados.
 *
 * Conserva la firma que exige CLAVISCO-PLATFORM-STANDARDS §5.1:
 * `login()`, `logout()`, `hasPermission(code)`.
 */

import { Storage, SStore, clPrint, CL_DISPLAY } from 'vendor/clavisco/core'
import { publish } from 'vendor/clavisco/linker'

// ============================================================
// AUTH SERVICE
// ============================================================

class AuthService {
  constructor() {
    this.isAuthenticated = false
    this.user = null
    this.companies = []
    this.currentCompany = null
  }

  /**
   * Inicia el flujo de login: navega a /login, que redirige al proveedor OIDC.
   * No recibe credenciales — la contraseña se escribe en la página del proveedor.
   */
  login() {
    window.location.href = '/login'
  }

  /**
   * Load user information
   */
  async loadUserInfo() {
    try {
      // El proxy adjunta el token desde la cookie de sesión — no se manda Authorization.
      const response = await fetch('/api/Users/GetUserInfo', {
        headers: { 'Content-Type': 'application/json' }
      })

      if (response.ok) {
        const data = await response.json()
        this.user = data.Data || data
        Storage.set('UserInfo', this.user)
      }
    } catch (error) {
      clPrint('Error loading user info', CL_DISPLAY.WARNING)
    }
  }

  /**
   * Load available companies
   * @returns {Promise<Array>} Companies list
   */
  async loadCompanies() {
    try {
      const response = await fetch('/api/Companies', {
        headers: { 'Content-Type': 'application/json' }
      })

      if (response.ok) {
        const data = await response.json()
        this.companies = data.Data || data || []
        Storage.set('Companies', this.companies)
        return this.companies
      }

      return []
    } catch (error) {
      clPrint('Error loading companies', CL_DISPLAY.WARNING)
      return []
    }
  }

  /**
   * Select current company
   * @param {Object} company - Company to select
   */
  selectCompany(company) {
    this.currentCompany = company
    SStore.set('CurrentCompany', company)

    publish({
      View: 'login',
      Target: 'companySelected',
      Data: company
    })
  }

  /**
   * Cierra sesión: limpia los datos de display del browser y delega en /auth/logout,
   * que invalida la cookie (reset_session) y cierra sesión en el proveedor OIDC.
   */
  logout() {
    this.isAuthenticated = false
    this.user = null
    this.currentCompany = null

    Storage.remove('UserInfo')
    Storage.remove('Companies')
    SStore.remove('CurrentCompany')

    publish({
      View: 'login',
      Target: 'logout',
      Data: null
    })

    // Full reload obligatorio: debe salir del dominio hacia el proveedor.
    window.location.href = '/auth/logout'
  }

  /**
   * Get current user
   * @returns {Object|null} User object
   */
  getUser() {
    return this.user || Storage.get('UserInfo')
  }

  /**
   * Get current company
   * @returns {Object|null} Company object
   */
  getCompany() {
    return this.currentCompany || Storage.getCurrentCompany()
  }

  /**
   * Check if user has permission
   * @param {string} permissionCode - Permission code
   * @returns {boolean} Has permission
   */
  hasPermission(permissionCode) {
    const user = this.getUser()
    if (!user || !user.Permissions) return false

    return user.Permissions.some(p =>
      p.Code === permissionCode && p.Status === true
    )
  }
}

// Singleton instance
const auth = new AuthService()

// ============================================================
// EXPORTS
// ============================================================

export const Auth = auth

export function login() {
  auth.login()
}

export function logout() {
  auth.logout()
}

// checkAuth() se eliminó: la sesión vive en una cookie httpOnly, así que el browser
// no puede — ni debe — determinar si hay sesión. Lo decide el servidor
// (ApplicationController#require_session).

export function getUser() {
  return auth.getUser()
}

export function getCompany() {
  return auth.getCompany()
}

export function loadCompanies() {
  return auth.loadCompanies()
}

export function selectCompany(company) {
  auth.selectCompany(company)
}

export function hasPermission(code) {
  return auth.hasPermission(code)
}

export default {
  Auth,
  login,
  logout,
  getUser,
  getCompany,
  loadCompanies,
  selectCompany,
  hasPermission
}

/**
 * @clavisco - Main entry point for all Clavisco components
 *
 * This module re-exports all @clavisco components for use in the EMA application.
 * Import specific modules as needed:
 *
 * @example
 * import { Alerts, showToast } from 'vendor/clavisco/alerts'
 * import { Storage, getApiHeaders } from 'vendor/clavisco/core'
 * import { publish, subscribe } from 'vendor/clavisco/linker'
 */

// Core utilities
export * as Core from './core/index.js'

// Pub/Sub communication
export * as Linker from './linker/index.js'

// UI Components
export * as Alerts from './alerts/index.js'
export * as Table from './table/index.js'
export * as SearchModal from './search-modal/index.js'
export * as PaymentModal from './payment-modal/index.js'
export * as Overlay from './overlay/index.js'
export * as Menu from './menu/index.js'

// Authentication
export * as Login from './login/index.js'

// Notifications
export * as NotificationCenter from './notification-center/index.js'

// Hardware integration
export * as Pinpad from './pinpad/index.js'

// UDFs (User Defined Fields)
export * as UdfPresentation from './dynamics-udfs-presentation/index.js'
export * as UdfConsole from './dynamics-udfs-console/index.js'

// Reports
export * as ReportManager from './rptmng-menu/index.js'

// Convenience re-exports from Core
export {
  Storage,
  getApiHeaders,
  apiRequest,
  clPrint,
  getError,
  downloadBase64File,
  printBase64File,
  CL_DISPLAY,
  CL_ACTIONS
} from './core/index.js'

// Convenience re-exports from Linker
export { publish, subscribe, flow } from './linker/index.js'

// Convenience re-exports from Alerts
export { showToast, showAlert, success, error, warning, info, confirm } from './alerts/index.js'

// Convenience re-exports from Overlay
export { open, close, closeAll, showLoading, hideLoading } from './overlay/index.js'

// Convenience re-exports from Login
export { login, logout, getUser, getCompany } from './login/index.js'

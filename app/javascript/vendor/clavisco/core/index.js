/**
 * @clavisco/core - Core utilities and structures
 * Migrated from Angular to vanilla JavaScript for Rails/Stimulus
 */

// ============================================================
// ENUMS
// ============================================================

export const CL_DISPLAY = {
  SUCCESS: 0,
  INFORMATION: 1,
  WARNING: 2,
  ERROR: 3
}

export const CL_ACTIONS = {
  CREATE: 0,
  UPDATE: 1,
  DELETE: 2,
  READ: 3,
  DISMISS: 4,
  CONTINUE: 5,
  CANCEL: 6,
  OPTION_1: 7,
  OPTION_2: 8,
  OPTION_3: 9,
  OPTION_4: 10,
  OPTION_5: 11,
  OPTION_6: 12,
  OPTION_7: 13,
  OPTION_8: 14,
  OPTION_9: 15,
  OPTION_10: 16,
  OPTION_11: 17,
  OPTION_12: 18,
  OPTION_13: 19,
  OPTION_14: 20,
  OPTION_15: 21
}

export const TOKENS = {
  ALERTS: 'ALERTS',
  CORE: 'CORE',
  DYN_UDF_CON: 'DYN_UDF_CON',
  DYN_UDF_PRE: 'DYN_UDF_PRE',
  GUARD: 'GUARD',
  HOME: 'HOME',
  INCG_PAY: 'INCOMMING PAYMENT',
  OINV: 'INVOICE',
  LINK: 'LINKER',
  LOGN: 'LOGIN',
  MENU: 'MENU',
  OVLAY: 'OVERLAY',
  PAY_MOD: 'PAYMENT_MODAL',
  RPMG_DK: 'REPORT MANAGER DESK',
  RPMG_MN: 'REPORT MANAGER MENU',
  SKTN: 'SKELETON',
  SHARED: 'SHARED',
  TABL: 'TABLE',
  ACTCEN: 'ACTION CENTER',
  MUL_WiNDOW: 'MULTIPLE WINDOW',
  USER_HELP: 'USER_HELP'
}

// ============================================================
// UTILITY FUNCTIONS
// ============================================================

/**
 * Validates an email with standard format
 * @param {string} email - User email
 * @returns {boolean} True if correct format
 */
export function isValidEmail(email) {
  return /^(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$/.test(email)
}

/**
 * Deep object comparison
 * @param {any} object1 - First object
 * @param {any} object2 - Second object
 * @returns {boolean} True if objects are deeply equal
 */
export function deepEqual(object1, object2) {
  const keys1 = Object.keys(object1)
  const keys2 = Object.keys(object2)

  if (keys1.length !== keys2.length) return false

  for (const key of keys1) {
    const val1 = object1[key]
    const val2 = object2[key]
    const areObjects = isObject(val1) && isObject(val2)
    if ((areObjects && !deepEqual(val1, val2)) || (!areObjects && val1 !== val2)) {
      return false
    }
  }
  return true
}

/**
 * Check if variable is an object
 * @param {any} object - Variable to check
 * @returns {boolean} True if object type
 */
export function isObject(object) {
  return object != null && typeof object === 'object'
}

/**
 * Custom console logging with formatting
 * @param {any} data - Data to log
 * @param {number} displayType - CL_DISPLAY enum value
 */
export function clPrint(data, displayType = CL_DISPLAY.ERROR) {
  const backgrounds = {
    [CL_DISPLAY.SUCCESS]: '#00cc66',
    [CL_DISPLAY.INFORMATION]: '#0099ff',
    [CL_DISPLAY.WARNING]: '#ff9900',
    [CL_DISPLAY.ERROR]: '#cc3300'
  }

  const labels = {
    [CL_DISPLAY.SUCCESS]: 'SUCCESS',
    [CL_DISPLAY.INFORMATION]: 'INFORMATION',
    [CL_DISPLAY.WARNING]: 'WARNING',
    [CL_DISPLAY.ERROR]: 'ERROR'
  }

  let message = typeof data === 'object' ? getError(data) : data

  console.log(
    `%c[CL - ${labels[displayType]}]`,
    `background: ${backgrounds[displayType]}; color: #fff; padding: 2px 6px; font-size: 12px;`,
    message
  )
}

/**
 * Extract error message from various error object formats
 * @param {any} error - Error object
 * @returns {string} Error message
 */
export function getError(error) {
  if (!error) return 'Unknown error'

  if (error.error?.errorInfo?.Message) return error.error.errorInfo.Message
  if (error.error?.error_description) return error.error.error_description
  if (error.error?.Message) return error.error.Message
  if (error.message) return error.message
  if (error.errorInfo?.Message) return error.errorInfo.Message
  if (error.error) return error.error
  if (error.Message) return error.Message
  if (error.Error?.Message) return `${error.Error.Code ? error.Error.Code + ' - ' : ''}${error.Error.Message}`

  return typeof error === 'string' ? error : JSON.stringify(error)
}

/**
 * Download a file from base64 string
 * @param {string} base64File - Base64 encoded file
 * @param {string} fileName - File name without extension
 * @param {string} blobType - MIME type
 * @param {string} fileExtension - File extension
 */
export function downloadBase64File(base64File, fileName, blobType, fileExtension) {
  try {
    if (!base64File) throw new Error("The string in base64 must not be empty")
    if (!fileName) throw new Error("The file name must not be empty")
    if (!blobType) throw new Error("The blob type must not be empty")
    if (!fileExtension) throw new Error("The file extension must not be empty")

    const arrayBuffer = stringToArrayBuffer(atob(base64File))
    if (!arrayBuffer) throw new Error("There was an error generating the buffer array")

    const blob = new Blob([arrayBuffer], { type: blobType })
    const link = document.createElement('a')
    link.href = window.URL.createObjectURL(blob)
    link.download = `${fileName}.${fileExtension}`
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
  } catch (error) {
    clPrint(error, CL_DISPLAY.ERROR)
  }
}

/**
 * Print or open a base64 file
 * @param {Object} args - Arguments
 * @param {string} args.base64File - Base64 encoded file
 * @param {string} args.blobType - MIME type
 * @param {boolean} args.onNewWindow - Open in new window
 */
export function printBase64File({ base64File, blobType, onNewWindow }) {
  const byteCharacters = atob(base64File)
  const byteNumbers = new Array(byteCharacters.length)

  for (let i = 0; i < byteCharacters.length; i++) {
    byteNumbers[i] = byteCharacters.charCodeAt(i)
  }

  const byteArray = new Uint8Array(byteNumbers)
  const blob = new Blob([byteArray], { type: blobType })
  const blobURL = URL.createObjectURL(blob)

  const iframe = document.createElement('iframe')
  document.body.appendChild(iframe)
  iframe.style.display = 'none'
  iframe.src = blobURL

  iframe.onload = function() {
    setTimeout(function() {
      if (onNewWindow) {
        const tabOrWindow = window.open(iframe.src, '_blank')
        tabOrWindow?.focus()
      } else {
        iframe.focus()
        iframe.contentWindow?.print()
      }
    }, 1)
  }
}

/**
 * Convert string to ArrayBuffer
 * @param {string} toConvert - String to convert
 * @returns {ArrayBuffer|null} ArrayBuffer or null on error
 */
export function stringToArrayBuffer(toConvert) {
  try {
    const arrayBuffer = new ArrayBuffer(toConvert.length)
    const uInt8Array = new Uint8Array(arrayBuffer)

    for (let i = 0; i < toConvert.length; i++) {
      uInt8Array[i] = toConvert.charCodeAt(i) & 0xff
    }

    return arrayBuffer
  } catch (error) {
    clPrint(error, CL_DISPLAY.ERROR)
    return null
  }
}

/**
 * Generate formatted timestamp
 * @returns {string} Timestamp string
 */
export function getTimeStamp() {
  const date = new Date()
  const pad = (n) => n.toString().padStart(2, '0')

  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
    date.getMilliseconds()
  ].join('%')
}

/**
 * Decode URI encoded string
 * @param {string} text - Text to decode
 * @returns {string} Decoded text
 */
export function uriDecode(text) {
  try {
    return decodeURIComponent(text)
  } catch (error) {
    console.info('Error decoding text:', error)
    return text
  }
}

/**
 * Encode string to URI format
 * @param {string} text - Text to encode
 * @returns {string} Encoded text
 */
export function uriEncode(text) {
  try {
    return encodeURIComponent(text)
  } catch (error) {
    console.error('Error encoding text:', text)
    return text
  }
}

// ============================================================
// STORAGE SERVICE
// ============================================================

export const Storage = {
  /**
   * Get item from localStorage
   * @param {string} key - Storage key
   * @returns {any} Parsed value or null
   */
  get(key) {
    try {
      const item = localStorage.getItem(key)
      return item ? JSON.parse(item) : null
    } catch {
      return localStorage.getItem(key)
    }
  },

  /**
   * Set item in localStorage
   * @param {string} key - Storage key
   * @param {any} value - Value to store
   */
  set(key, value) {
    localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value))
  },

  /**
   * Remove item from localStorage
   * @param {string} key - Storage key
   */
  remove(key) {
    localStorage.removeItem(key)
  },

  /**
   * Clear all localStorage
   */
  clear() {
    localStorage.clear()
  },

  /**
   * Get session data
   * @returns {Object|null} Session object
   */
  getSession() {
    return this.get('Session')
  },

  /**
   * Get current company desde sessionStorage (per-tab).
   * @returns {Object|null} Company object
   */
  getCurrentCompany() {
    return SStore.get('CurrentCompany')
  },

  /**
   * Get auth token
   * @returns {string|null} Access token
   */
  getToken() {
    const session = this.getSession()
    return session?.access_token || null
  },

  /**
   * Get company ID desde sessionStorage (per-tab).
   * @returns {number} Company ID
   */
  getCompanyId() {
    const company = this.getCurrentCompany()
    return company?.companyId || 1
  }
}

// ============================================================
// SESSION STORAGE HELPER (per-tab: empresa seleccionada, permisos)
// ============================================================

/**
 * SStore — equivalente a Storage pero sobre sessionStorage.
 * Usar para datos por pestaña: CurrentCompany, Permissions.
 */
export const SStore = {
  get(key) {
    try {
      const item = sessionStorage.getItem(key)
      return item ? JSON.parse(item) : null
    } catch {
      return sessionStorage.getItem(key)
    }
  },

  set(key, value) {
    try {
      sessionStorage.setItem(key, JSON.stringify(value))
    } catch {
      sessionStorage.setItem(key, value)
    }
  },

  remove(key) {
    sessionStorage.removeItem(key)
  },

  clear() {
    sessionStorage.clear()
  }
}

// ============================================================
// SESSION VALIDITY HELPER
// ============================================================

// isSessionValid() se eliminó junto con el login client-side: la sesión vive en una
// cookie httpOnly, que por definición el JavaScript no puede leer. Quien decide si
// hay sesión es el servidor (ApplicationController#require_session), antes de
// renderizar. Cualquier chequeo client-side sería, además de imposible, falseable.

// ============================================================
// API HEADERS HELPER
// ============================================================

/**
 * Headers estándar para llamar al API a través del proxy.
 *
 * NO incluye Authorization a propósito: el token vive en la cookie httpOnly y lo
 * adjunta ProxyController del lado servidor (§2.3). El browser no tiene —ni debe
 * tener— acceso al token, y el proxy descarta cualquier Authorization que llegue
 * del cliente.
 *
 * @returns {Object} Headers object
 */
export function getApiHeaders() {
  return {
    'Content-Type': 'application/json',
    'cl-company-id': String(Storage.getCompanyId())
  }
}

/**
 * Make authenticated API request
 * @param {string} url - API URL
 * @param {Object} options - Fetch options
 * @returns {Promise<Response>} Fetch response
 */
export async function apiRequest(url, options = {}) {
  const headers = {
    ...getApiHeaders(),
    ...options.headers
  }

  return fetch(url, {
    ...options,
    headers
  })
}

// Default export
export default {
  CL_DISPLAY,
  CL_ACTIONS,
  TOKENS,
  isValidEmail,
  deepEqual,
  isObject,
  clPrint,
  getError,
  downloadBase64File,
  printBase64File,
  stringToArrayBuffer,
  getTimeStamp,
  uriDecode,
  uriEncode,
  Storage,
  getApiHeaders,
  apiRequest
}

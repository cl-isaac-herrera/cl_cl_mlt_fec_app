/**
 * Headers compartidos para los componentes deslizantes/modales de vendor/clavisco/*
 * (search-modal, slide-search, *-slide, payment-modal, rptmng-desk) que llaman al API
 * a traves del proxy de Rails.
 *
 * La sesion vive en una cookie httpOnly (ver vendor/clavisco/core#getApiHeaders):
 * el browser no tiene el token y no debe adjuntarlo, asi que estos helpers solo
 * agregan sobre getApiHeaders() los headers de descripcion/paginacion que estos
 * componentes usan para el logging del proxy y la paginacion del Service Layer.
 */
import { getApiHeaders } from 'vendor/clavisco/core'

/**
 * @param {Object} [options]
 * @param {string} [options.successDescription]
 * @param {string} [options.errorDescription]
 * @param {number} [options.page]
 * @param {number} [options.pageSize]
 * @returns {Object}
 */
export function getAPIHeaders(options = {}) {
  const headers = getApiHeaders()

  if (options.successDescription) headers['cl-request-success-description'] = options.successDescription
  if (options.errorDescription)   headers['cl-request-error-description']   = options.errorDescription
  if (options.page !== undefined)     headers['cl-sl-pagination-page']      = String(options.page)
  if (options.pageSize !== undefined) headers['cl-sl-pagination-page-size'] = String(options.pageSize)

  return headers
}

/**
 * Atajo para busquedas de datos maestros (BusinessPartners, Items, etc.): la misma
 * descripcion se usa tanto para el caso de exito como el de error.
 * @param {string} description
 * @param {Object} [options] - se reenvia a getAPIHeaders (ej. page/pageSize)
 * @returns {Object}
 */
export function getMasterDataHeaders(description, options = {}) {
  return getAPIHeaders({
    successDescription: description,
    errorDescription: description,
    ...options
  })
}

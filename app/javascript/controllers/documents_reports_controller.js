import { Controller } from '@hotwired/stimulus';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';

/**
 * DocumentsReportsController — Reportes de documentos emitidos y recepcionados.
 *
 * Replica: pages/reports/reports.component.ts (Angular legacy, ruta /docReport)
 * Ruta Rails: /documents-reports
 *
 * Funcionalidad:
 *   - Filtro por StartDate / EndDate con botones "Hoy"
 *   - Radio buttons por tipo de reporte (visibles según permisos)
 *   - Validación de fechas (no nulas, no futuras, StartDate ≤ EndDate)
 *   - GET /api/Report/GetDocReport      → PDF base64 → nueva pestaña
 *   - GET /api/Report/GetDocReceptReport → PDF base64 → nueva pestaña
 *   - Overlay durante la carga
 *   - Toast warning cuando no hay datos
 *   - Toast error cuando la API falla
 */
export default class extends Controller {
  static targets = [
    'startDate',
    'endDate',
    'docTab',
    'recepTab',
    'submitBtn',
    'overlay',
    'viewer',
    'viewerEmpty',
  ]

  // ── Estado ──────────────────────────────────────────────────────────────
  #companyId   = null
  #reportType  = '1'
  #pdfBlobUrl  = null

  // Clases del toggle segmentado (tipo de reporte)
  #tabActive   = ['bg-blue-600', 'text-white', 'shadow-sm']
  #tabInactive = ['text-gray-600', 'hover:text-gray-800']

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company   = SStore.get('CurrentCompany') || {}
    this.#companyId = company.companyId ?? null

    this.#initDefaults()
    this.#setReportType('1')   // ambos tipos disponibles; por defecto "Emitidos"
    this.#updateSubmitState()
  }

  disconnect() {
    this.#revokePdf()
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  #initDefaults() {
    const today = this.#formatDate(new Date())
    this.startDateTarget.value = today
    this.endDateTarget.value   = today
  }

  // ── Handlers ──────────────────────────────────────────────────────────────

  selectReportType(event) {
    this.#setReportType(event.currentTarget.dataset.reportType)
  }

  quickRange(event) {
    const range = event.currentTarget.dataset.range
    const today = new Date()
    let start   = new Date(today)

    if (range === '7') {
      start.setDate(today.getDate() - 6)
    } else if (range === 'month') {
      start = new Date(today.getFullYear(), today.getMonth(), 1)
    }

    this.startDateTarget.value = this.#formatDate(start)
    this.endDateTarget.value   = this.#formatDate(today)
    this.#updateSubmitState()
  }

  validateDates() {
    this.#updateSubmitState()
  }

  submit() {
    const startDate = this.startDateTarget.value
    const endDate   = this.endDateTarget.value

    if (!startDate || !endDate) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'El formulario no puede enviarse con campos vacíos. Complete todos los campos antes de continuar.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    const start = new Date(startDate)
    const end   = new Date(endDate)
    const today = new Date()
    today.setHours(23, 59, 59, 999)

    if (start > today || end > today || start > end) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'La fecha de búsqueda es futura o la fecha de inicio es posterior a la fecha final. Por favor, verifica y ajusta las fechas para asegurarte de que el rango de búsqueda sea válido.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    const reportType = this.#reportType
    if (reportType === '1') {
      this.#fetchReport('GetDocReport', startDate, endDate)
    } else {
      this.#fetchReport('GetDocReceptReport', startDate, endDate)
    }
  }

  // ── API ───────────────────────────────────────────────────────────────────

  async #fetchReport(endpoint, startDate, endDate) {
    this.#showOverlay()
    try {
      const companyId = this.#companyId
      const url = `/api/Report/${endpoint}?StartDate=${startDate}&EndDate=${endDate}&CompanyId=${companyId}`
      const data = await this.#apiFetch(url)

      if (data?.Data) {
        this.#renderPdf(data.Data)
      } else {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'warning',
          title: 'Lo sentimos, no hay información disponible para generar el reporte en el rango de fechas proporcionados',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
      }
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al generar el reporte',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
    } finally {
      this.#hideOverlay()
    }
  }

  async #apiFetch(url, options = {}) {
    const session   = Storage.get('Session') || {}
    const token     = session.access_token
    const company   = SStore.get('CurrentCompany') || {}
    const companyId = company.companyId ?? this.#companyId

    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(token     ? { Authorization:   `Bearer ${token}` } : {}),
        ...(companyId ? { 'Cl-Company-Id': String(companyId) } : {}),
        ...(options.headers || {}),
      },
    })

    const clMessage = response.headers.get('cl-message')
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage) } catch { return clMessage }
    })() : null

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      // El body de error suele venir como JSON { Message, Code }; extraer Message.
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

  // ── PDF ───────────────────────────────────────────────────────────────────

  // Convierte el base64 en un blob URL, lo muestra en el visor y revela las acciones.
  #renderPdf(base64) {
    this.#revokePdf()

    const binary      = atob(base64)
    const arrayBuffer = new ArrayBuffer(binary.length)
    const uintArray   = new Uint8Array(arrayBuffer)
    for (let i = 0; i < binary.length; i++) {
      uintArray[i] = binary.charCodeAt(i)
    }
    const blob = new Blob([uintArray], { type: 'application/pdf' })
    this.#pdfBlobUrl = URL.createObjectURL(blob)

    this.viewerTarget.src = this.#pdfBlobUrl
    this.viewerTarget.classList.remove('hidden')
    this.viewerEmptyTarget.classList.add('hidden')
  }

  #revokePdf() {
    if (this.#pdfBlobUrl) {
      URL.revokeObjectURL(this.#pdfBlobUrl)
      this.#pdfBlobUrl = null
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  #formatDate(date) {
    const pad = n => String(n).padStart(2, '0')
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
  }

  #setReportType(value) {
    this.#reportType = value
    this.#updateTabStyles()
  }

  #updateTabStyles() {
    const set = (el, isActive) => {
      el.classList.remove(...this.#tabActive, ...this.#tabInactive)
      el.classList.add(...(isActive ? this.#tabActive : this.#tabInactive))
    }
    if (this.hasDocTabTarget)   set(this.docTabTarget,   this.#reportType === '1')
    if (this.hasRecepTabTarget) set(this.recepTabTarget, this.#reportType === '2')
  }

  #updateSubmitState() {
    const valid = this.startDateTarget.value && this.endDateTarget.value
    this.submitBtnTarget.disabled = !valid
  }

  #showOverlay() {
    this.overlayTarget.classList.remove('hidden')
  }

  #hideOverlay() {
    this.overlayTarget.classList.add('hidden')
  }
}

import { Controller } from '@hotwired/stimulus'
import { Storage, SStore } from 'vendor/clavisco/core'
import Swal from 'sweetalert2'
import { showLoading, hideLoading } from 'vendor/clavisco/overlay'

// Constantes de dominio — mismas que Angular legacy
const MESSAGE_TYPE = [
  { id: 1, name: 'Aceptado' },
  { id: 2, name: 'Aceptar Parcialmente' },
  { id: 3, name: 'Rechazado' },
]

// CondicionImpuesto que habilitan TaxFactor
const TAX_FACTOR_CONDITIONS = new Set(['03', '05'])

// Mensaje que requiere DetalleMensaje
const DETAIL_REQUIRED_MESSAGES = new Set(['2', '3'])

// Longitud del DetalleMensaje: máximo 160; mínimo 5 solo si se ingresa texto
const DETAIL_MIN_LENGTH = 5
const DETAIL_MAX_LENGTH = 160

export default class extends Controller {
  static targets = [
    // Panel lateral contenedor
    'panel', 'panelBackdrop', 'panelLoader',
    // Form
    'fileInput', 'inputAdjunto', 'errorAdjunto',
    'selectMensaje',
    'selectCondicionImpuesto',
    'inputTaxFactor', 'errorTaxFactor',
    'inputCodigoActividad', 'errorCodigoActividad',
    'inputDetalleMensaje', 'errorDetalleMensaje', 'counterDetalleMensaje',
    // Panel lateral de previsualización
    'previewBackdrop', 'previewPanel',
    'previewNumeroConsecutivo', 'previewFechaEmision',
    'previewMoneda', 'previewTipoCambio',
    'previewClave', 'previewPlazoCredito',
    'previewMedioPago',
    'previewEmsrNombre', 'previewEmsrNombreComercial',
    'previewEmsrNumero', 'previewEmsrCorreo', 'previewEmsrTelefono',
    'previewRcprNombre', 'previewRcprNombreComercial',
    'previewRcprNumero', 'previewRcprCorreo', 'previewRcprTelefono',
    'previewDetalleBody', 'previewCargosBody', 'previewTotalesBody',
  ]

  #selectedFile    = null
  #companyId       = null
  #codigoActividad = ''
  #activityCodes   = []
  #permissions     = []

  connect() {
    const company = SStore.get('CurrentCompany')
    if (company) {
      this.#companyId       = company.companyId
      this.#codigoActividad = company.codigoActividad ?? ''
    }

    const permissions = SStore.get('Permissions')
    this.#permissions = Array.isArray(permissions) ? permissions : []

    if (this.#companyId) {
      this.#loadActivityCodes()
    } else {
      this.panelLoaderTarget.classList.add('hidden')
    }
  }

  // ──────────────────────────────────────────────
  // PANEL LATERAL — abrir / cerrar
  // ──────────────────────────────────────────────

  openPanel() {
    // Defensa en profundidad: el botón se deshabilita en la UI sin permiso,
    // pero reverificamos aquí (ver CLAUDE.md §26).
    if (!this.#permissions.includes('S_ReceptDocs')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para recepcionar documentos.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }
    this.#resetForm()
    this.panelBackdropTarget.classList.remove('hidden')
    this.panelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full')
    this.panelBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
  }

  #resetForm() {
    this.#selectedFile = null
    this.fileInputTarget.value     = ''
    this.inputAdjuntoTarget.value  = ''
    this.errorAdjuntoTarget.classList.add('hidden')

    this.selectMensajeTarget.value           = '1'
    this.selectCondicionImpuestoTarget.value = '01'
    this.inputDetalleMensajeTarget.value     = ''
    this.errorDetalleMensajeTarget.classList.add('hidden')
    this.errorCodigoActividadTarget.classList.add('hidden')
    this.#updateDetalleCounter()

    this.#populateActivitySelect()

    // Reset TaxFactor según condición por defecto (01 → deshabilitado)
    this.onCondicionImpuestoChange()
    this.onMensajeChange()
  }

  // ──────────────────────────────────────────────
  // FILE INPUT
  // ──────────────────────────────────────────────

  triggerFileInput() {
    this.fileInputTarget.click()
  }

  onFileSelected(event) {
    const file = event.target.files[0]
    if (!file) return

    const isXml = file.type.toLowerCase() === 'text/xml' ||
                  file.name.toLowerCase().endsWith('.xml')

    if (isXml) {
      this.#selectedFile = file
      this.inputAdjuntoTarget.value = file.name
      this.errorAdjuntoTarget.classList.add('hidden')
    } else {
      this.#selectedFile = null
      this.inputAdjuntoTarget.value = ''
      this.fileInputTarget.value = ''
      this.errorAdjuntoTarget.classList.remove('hidden')
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Solo se permiten archivos .xml',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
    }
  }

  // ──────────────────────────────────────────────
  // CAMPO: Mensaje → habilita/requiere DetalleMensaje
  // ──────────────────────────────────────────────

  onMensajeChange() {
    const mensaje = this.selectMensajeTarget.value
    const required = DETAIL_REQUIRED_MESSAGES.has(mensaje)
    const textarea = this.inputDetalleMensajeTarget

    if (required) {
      textarea.placeholder = 'Detalle requerido para esta respuesta'
    } else {
      textarea.placeholder = 'Detalle del mensaje (opcional)'
      this.errorDetalleMensajeTarget.classList.add('hidden')
    }
  }

  // Contador de caracteres del detalle: N/160. En rojo cuando hay texto pero por
  // debajo del mínimo (5); el mínimo solo aplica si se ingresó algún mensaje.
  onDetalleMensajeInput() {
    this.errorDetalleMensajeTarget.classList.add('hidden')
    this.#updateDetalleCounter()
  }

  #updateDetalleCounter() {
    if (!this.hasCounterDetalleMensajeTarget) return
    const len   = this.inputDetalleMensajeTarget.value.trim().length
    const short = len > 0 && len < DETAIL_MIN_LENGTH
    this.counterDetalleMensajeTarget.textContent = short
      ? `Mínimo ${DETAIL_MIN_LENGTH} caracteres · ${len}/${DETAIL_MAX_LENGTH}`
      : `${len}/${DETAIL_MAX_LENGTH}`
    this.counterDetalleMensajeTarget.classList.toggle('text-red-500', short)
    this.counterDetalleMensajeTarget.classList.toggle('text-gray-400', !short)
  }

  // ──────────────────────────────────────────────
  // CAMPO: CondicionImpuesto → habilita/deshabilita TaxFactor
  // ──────────────────────────────────────────────

  onCondicionImpuestoChange() {
    const condicion = this.selectCondicionImpuestoTarget.value
    const taxInput  = this.inputTaxFactorTarget

    if (TAX_FACTOR_CONDITIONS.has(condicion)) {
      taxInput.disabled = false
      taxInput.classList.remove('bg-gray-100', 'text-gray-400', 'cursor-not-allowed')
    } else {
      taxInput.disabled = true
      taxInput.value    = '0'
      taxInput.classList.add('bg-gray-100', 'text-gray-400', 'cursor-not-allowed')
      this.errorTaxFactorTarget.classList.add('hidden')
    }
  }

  // ──────────────────────────────────────────────
  // VALIDACIÓN
  // ──────────────────────────────────────────────

  #validate() {
    let valid = true

    // Archivo
    if (!this.#selectedFile) {
      this.errorAdjuntoTarget.classList.remove('hidden')
      valid = false
    } else {
      this.errorAdjuntoTarget.classList.add('hidden')
    }

    // CodigoActividad (requerido)
    const codigo = this.inputCodigoActividadTarget.value
    if (!codigo) {
      this.errorCodigoActividadTarget.classList.remove('hidden')
      valid = false
    } else {
      this.errorCodigoActividadTarget.classList.add('hidden')
    }

    // TaxFactor cuando es requerido
    const condicion = this.selectCondicionImpuestoTarget.value
    if (TAX_FACTOR_CONDITIONS.has(condicion)) {
      const taxFactor = this.inputTaxFactorTarget.value.trim()
      if (!taxFactor) {
        this.errorTaxFactorTarget.classList.remove('hidden')
        valid = false
      } else {
        this.errorTaxFactorTarget.classList.add('hidden')
      }
    }

    // DetalleMensaje: requerido según el tipo de mensaje + longitud.
    // El mínimo de 5 caracteres solo aplica cuando se ingresó texto.
    const mensaje  = this.selectMensajeTarget.value
    const detalle  = this.inputDetalleMensajeTarget.value.trim()
    const required = DETAIL_REQUIRED_MESSAGES.has(mensaje)
    if (required && !detalle) {
      this.errorDetalleMensajeTarget.textContent = 'El detalle del mensaje es requerido para esta respuesta'
      this.errorDetalleMensajeTarget.classList.remove('hidden')
      valid = false
    } else if (detalle && detalle.length < DETAIL_MIN_LENGTH) {
      this.errorDetalleMensajeTarget.textContent = `El detalle del mensaje debe tener al menos ${DETAIL_MIN_LENGTH} caracteres`
      this.errorDetalleMensajeTarget.classList.remove('hidden')
      this.#updateDetalleCounter()
      valid = false
    } else {
      this.errorDetalleMensajeTarget.classList.add('hidden')
    }

    return valid
  }

  // ──────────────────────────────────────────────
  // ENVIAR — POST api/Documents/ReceptMessage (ApiFEUrl)
  // ──────────────────────────────────────────────

  async onSubmit() {
    if (!this.#companyId || parseInt(this.#companyId) === 0) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'No posee seleccionada una compañía. Verifique seleccionar o crear una antes de continuar.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    if (!this.#selectedFile) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Actualmente no es posible enviar el documento. Por favor, proceda a cargar un documento antes de intentar acceder a esta información.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    if (!this.#validate()) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'El formulario contiene errores',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    const recepcion = {
      Mensaje:           parseInt(this.selectMensajeTarget.value),
      DetalleMensaje:    this.inputDetalleMensajeTarget.value.trim(),
      Sucursal:          1,
      Terminal:          1,
      CompanyId:         parseInt(this.#companyId),
      CondicionImpuesto: this.selectCondicionImpuestoTarget.value,
      TaxFactor:         this.inputTaxFactorTarget.value.trim(),
      CodigoActividad:   this.inputCodigoActividadTarget.value.trim(),
      UserId:            '',
    }

    const fd = new FormData()
    fd.append('file', this.#selectedFile)
    fd.append('Recepcion', JSON.stringify(recepcion))

    try {
      showLoading('Procesando documento, espere por favor...')

      const data = await this.#apiFetch('/api/Documents/ReceptMessage', {
        method:  'POST',
        headers: { 'API': 'ApiFEUrl' },
        body:    fd,
      }, { isFormData: true })

      hideLoading()

      if (data?.result) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Se procesó correctamente la petición',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
        this.closePanel()
        this.dispatch('done')   // documents-reception:done → recarga la tabla de receptions
      } else {
        const msg = data?.errorInfo?.Message ?? 'Error al procesar la recepción'
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'warning',
          title: msg,
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
      }
    } catch (err) {
      hideLoading()
      await Swal.fire({
        icon: 'error',
        title: 'Error al enviar el documento',
        text: err.message || 'Error al enviar el documento',
        confirmButtonText: 'Aceptar'
      })
    }
  }

  // ──────────────────────────────────────────────
  // PREVISUALIZAR — POST api/Documents/GetPreviewDocument (ApiAppUrl)
  // ──────────────────────────────────────────────

  async getPreview() {
    if (!this.#selectedFile) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Actualmente no es posible visualizar los datos. Por favor, proceda a cargar un documento antes de intentar acceder a esta información.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }

    const fd = new FormData()
    fd.append('file', this.#selectedFile)

    try {
      showLoading('Procesando documento, espere por favor...')

      const response = await this.#apiFetch('/api/Documents/GetPreviewDocument', {
        method:  'POST',
        headers: { 'API': 'ApiAppUrl', 'Request-With-Files': 'true' },
        body:    fd,
      }, { isFormData: true })

      hideLoading()

      if (response?.Data) {
        this.#fillPreview(response.Data)
        this.#openPreview()
      } else {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'warning',
          title: response?.Message ?? 'No se pudo obtener la previsualización',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
      }
    } catch (err) {
      hideLoading()
      await Swal.fire({
        icon: 'error',
        title: 'Error al obtener la previsualización',
        text: err.message || 'Error al obtener la previsualización',
        confirmButtonText: 'Aceptar'
      })
    }
  }

  // ──────────────────────────────────────────────
  // LLENAR MODAL DE PREVISUALIZACIÓN
  // ──────────────────────────────────────────────

  #fillPreview(data) {
    const moneda = data.ResumenFactura?.CodigoMoneda ?? ''

    this.previewNumeroConsecutivoTarget.textContent = data.NumeroConsecutivo ?? '—'
    this.previewFechaEmisionTarget.textContent      = data.FechaEmision       ?? '—'
    this.previewMonedaTarget.textContent            = moneda                  || '—'
    this.previewTipoCambioTarget.textContent        = `${moneda} ${data.ResumenFactura?.TipoCambio ?? ''}`.trim() || '—'
    this.previewClaveTarget.textContent             = data.Clave              ?? '—'
    this.previewPlazoCreditoTarget.textContent      = data.PlazoCredito       ?? '—'

    // Medio de pago
    const medioPago = data.ResumenFactura?.MedioPago ?? []
    this.previewMedioPagoTarget.innerHTML = medioPago.map(mp => `
      <div class="grid grid-cols-3 gap-4 pt-2 border-t border-gray-100">
        <div><p class="text-xs text-gray-500">Tipo Medio Pago</p><p class="text-sm font-medium">${mp.TipoMedioPago ?? '—'}</p></div>
        <div><p class="text-xs text-gray-500">Medio Pago Otros</p><p class="text-sm font-medium">${mp.MedioPagoOtros ?? '—'}</p></div>
        <div><p class="text-xs text-gray-500">Total</p><p class="text-sm font-medium">${this.#fmt(mp.TotalMedioPago, moneda)}</p></div>
      </div>
    `).join('')

    // Emisor
    this.previewEmsrNombreTarget.textContent          = data.EmsrNombre           ?? '—'
    this.previewEmsrNombreComercialTarget.textContent = data.EmsrNombreComercial  ?? '—'
    this.previewEmsrNumeroTarget.textContent          = data.EmsrNumero           ?? '—'
    this.previewEmsrCorreoTarget.textContent          = data.EmsrCorreoElectronico ?? '—'
    this.previewEmsrTelefonoTarget.textContent        = `${data.EmsrCodigoPaisTelefono ?? ''} ${data.EmsrNumTelefono ?? ''}`.trim() || '—'

    // Receptor
    this.previewRcprNombreTarget.textContent          = data.RcprNombre           ?? '—'
    this.previewRcprNombreComercialTarget.textContent = data.RcprNombreComercial  ?? '—'
    this.previewRcprNumeroTarget.textContent          = data.RcprNumero           ?? '—'
    this.previewRcprCorreoTarget.textContent          = data.RcprCorreoElectronico ?? '—'
    this.previewRcprTelefonoTarget.textContent        = `${data.RcprCodigoPaisTelefono ?? ''} ${data.RcprNumTelefono ?? ''}`.trim() || '—'

    // Detalle líneas
    const lineas = data.DetalleServicio ?? []
    this.previewDetalleBodyTarget.innerHTML = lineas.length
      ? lineas.map(l => `
          <tr class="border-b border-gray-100">
            <td class="py-1.5 pr-3 text-xs">${l.Codigo ?? ''}</td>
            <td class="py-1.5 pr-3 text-xs">${l.Detalle ?? ''}</td>
            <td class="py-1.5 pr-3 text-xs text-right">${l.Cantidad ?? ''}</td>
            <td class="py-1.5 pr-3 text-xs text-right">${this.#fmt(l.PrecioUnitario, moneda)}</td>
            <td class="py-1.5 text-xs text-right">${this.#fmt(l.MontoTotalLinea, moneda)}</td>
          </tr>
        `).join('')
      : '<tr><td colspan="5" class="text-center text-gray-400 py-3 text-xs">Sin líneas</td></tr>'

    // Cargos — campo correcto del modelo: DetalleCargos (no OtrosCargos)
    const cargos = data.DetalleCargos ?? []
    this.previewCargosBodyTarget.innerHTML = cargos.length
      ? cargos.map(c => `
          <tr class="border-b border-gray-100">
            <td class="py-1.5 pr-3 text-xs">${c.TipoDocumento ?? ''}</td>
            <td class="py-1.5 pr-3 text-xs">${c.Detalle ?? ''}</td>
            <td class="py-1.5 text-xs text-right">${this.#fmt(c.PrecioUnitario, moneda)}</td>
          </tr>
        `).join('')
      : '<tr><td colspan="3" class="text-center text-gray-400 py-3 text-xs">Sin cargos</td></tr>'

    // Totales
    const rf = data.ResumenFactura ?? {}
    const totalesRows = [
      ['Total Serv Exentos',         rf.TotalServExentos],
      ['Total Serv Gravados',        rf.TotalServGravados],
      ['Total Serv Exonerados',      rf.TotalServExonerado],
      ['Total Serv No Sujetos',      rf.TotalServNoSujeto],
      ['Total Mercancías Exentas',   rf.TotalMercanciasExentas],
      ['Total Mercancías Gravadas',  rf.TotalMercanciasGravadas],
      ['Total Mercancías Exoneradas',rf.TotalMercExonerada],
      ['Total Mercancías No Sujetas',rf.TotalMercNoSujeta],
      ['Total Gravado',              rf.TotalGravado],
      ['Total Exento',               rf.TotalExento],
      ['Total Exonerado',            rf.TotalExonerado],
      ['Total No Sujeto',            rf.TotalNoSujeto],
      ['Total Venta',                rf.TotalVenta],
      ['Total Descuentos',           rf.TotalDescuentos],
      ['Total Venta Neta',           rf.TotalVentaNeta],
      ['Total Impuesto',             rf.TotalImpuesto],
      ['Total IVA Devuelto',         rf.TotalIVADevuelto],
      ['Total Otros Cargos',         rf.TotalOtrosCargos],
      ['Total Comprobante',          rf.TotalComprobante],
    ]
    this.previewTotalesBodyTarget.innerHTML = totalesRows
      .filter(([, val]) => val != null)
      .map(([label, val]) => `
        <tr>
          <td class="py-1.5 pr-4 text-xs text-gray-500 font-medium">${label}</td>
          <td class="py-1.5 text-xs text-gray-800 text-right font-semibold">${this.#fmt(val, moneda)}</td>
        </tr>
      `).join('')
  }

  #fmt(value, currency = '') {
    if (value == null || value === '') return '—'
    const num = parseFloat(value)
    if (isNaN(num)) return String(value)
    return `${currency} ${num.toLocaleString('es-CR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`.trim()
  }

  // ──────────────────────────────────────────────
  // MODALES
  // ──────────────────────────────────────────────

  #openPreview() {
    this.previewBackdropTarget.classList.remove('hidden')
    this.previewPanelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  closePreview() {
    this.previewPanelTarget.classList.add('translate-x-full')
    this.previewBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
  }


  // ──────────────────────────────────────────────
  // CÓDIGOS DE ACTIVIDAD — carga y población del select
  // ──────────────────────────────────────────────

  async #loadActivityCodes() {
    try {
      const data = await this.#apiFetch(
        `/api/Companies/${this.#companyId}/activity-codes`
      )
      this.#activityCodes = data?.Data ?? []
      this.#populateActivitySelect()
    } catch {
      this.#activityCodes = []
    } finally {
      this.panelLoaderTarget.classList.add('hidden')
    }
  }

  // El popup nativo del <select> se ensancha hasta la opción más larga; como el
  // panel está pegado al borde derecho, un nombre de actividad largo lo desborda
  // hacia la izquierda. Se trunca el nombre en la etiqueta (el código queda íntegro)
  // y el nombre completo va en `title` como respaldo.
  #activityLabel(code, name) {
    const MAX = 45
    const short = name.length > MAX ? `${name.slice(0, MAX).trimEnd()}…` : name
    return `${code} — ${short}`
  }

  #populateActivitySelect() {
    const select = this.inputCodigoActividadTarget
    select.innerHTML = '<option value="">-- Seleccione --</option>'
    for (const item of this.#activityCodes) {
      const opt = document.createElement('option')
      opt.value       = item.Code
      opt.textContent = this.#activityLabel(item.Code, item.Name ?? '')
      opt.title       = `${item.Code} — ${item.Name ?? ''}`
      if (item.Code === this.#codigoActividad) opt.selected = true
      select.appendChild(opt)
    }
  }

  // ──────────────────────────────────────────────
  // API FETCH — patrón estándar del proyecto
  // ──────────────────────────────────────────────

  async #apiFetch(url, options = {}, { isFormData = false } = {}) {
    const apiTarget = options.headers?.['API'] ?? 'ApiAppUrl'
    const isFESync  = apiTarget === 'ApiFEUrl'

    const token = isFESync
      ? (JSON.parse(sessionStorage.getItem('currentFEUser') || '{}')?.access_token ?? null)
      : (Storage.get('Session') || {}).access_token

    const company   = SStore.get('CurrentCompany')
    const companyId = company?.companyId ?? this.#companyId

    const baseHeaders = {
      'API':                      apiTarget,
      'X-Skip-Error-Interceptor': 'true',
      ...(token     ? { Authorization:   `Bearer ${token}` } : {}),
      ...(companyId ? { 'Cl-Company-Id': String(companyId) } : {}),
      ...(options.headers || {}),
    }

    // FormData: no forzar Content-Type, el browser lo pone con boundary
    if (!isFormData) {
      baseHeaders['Content-Type'] = 'application/json'
    }

    const response = await fetch(url, {
      ...options,
      headers: baseHeaders,
    })

    const clMessage = response.headers.get('cl-message')
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage) } catch { return clMessage }
    })() : null

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText)
      throw new Error(decodedMessage || text || `HTTP ${response.status}`)
    }

    const hasBody = response.status !== 204 &&
                    response.headers.get('content-length') !== '0' &&
                    response.headers.get('content-type')?.includes('application/json')
    if (!hasBody) return { Message: decodedMessage || null }

    const json = await response.json()
    if (decodedMessage && !json.Message) json.Message = decodedMessage
    return json
  }
}

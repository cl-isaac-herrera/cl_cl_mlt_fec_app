import { Controller } from '@hotwired/stimulus'
import { Storage, SStore, getApiHeaders } from 'vendor/clavisco/core'
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts'
import { showLoading, hideLoading } from 'vendor/clavisco/overlay'

/**
 * GeneralConfigsController — Configuraciones Generales.
 *
 * Dos orígenes distintos en la misma pantalla:
 *
 *   1. Los AJUSTES (`settings`) son nativos de Rails (CLAUDE.md §28, §36):
 *        GET   /api/settings
 *        PATCH /api/settings/:code            ← el `code` va en el path
 *        POST  /api/external_db_health_checks ← botón "Probar conexión"
 *      Van con la session cookie: `getApiHeaders()`, sin Authorization.
 *
 *   2. El FORMATO DE IMPRESIÓN por defecto sigue en el .NET por proxy
 *      (GET/PATCH /api/GeneralConfigs), y ese sí necesita el Bearer.
 *
 * Los inputs de ajustes no tienen un target por campo: comparten
 * `settingInput` y se identifican por `data-setting-code`, que es la llave del
 * recurso. Agregar un ajuste al catálogo es agregar un render en la vista.
 */
export default class extends Controller {
  static targets = [
    // Formato de impresión (.NET por proxy)
    'printFormatInput',
    'fileInput',
    'printFormatError',
    'uploadWrapper',
    'downloadWrapper',
    'updateFormatWrapper',
    'btnUpdateFormat',
    'formatLoader',
    'formatAudit',
    'formatAuditText',
    // Ajustes (`settings`)
    'settingInput',
    'settingHint',
    'groupButton',
    'groupAudit',
    'groupLoader',
    // Base de documentos
    'engineNotice',
    'engineNoticeText',
    'btnTestDb',
    'healthResult',
    'healthIcon',
    'healthMessage',
    'healthDetail',
  ]

  // ----------------------------------------------------------------
  // Estado privado
  // ----------------------------------------------------------------
  #generalConfigId = null
  #selectedFile    = null

  /** Code → ajuste serializado, tal como lo devolvió `GET /api/settings`. */
  #settings = new Map()

  /** Grupos que la pantalla administra, con su nombre para los mensajes. */
  static GROUP_LABELS = {
    GENERAL:      'la cédula del proveedor de sistemas',
    CRYSTAL:      'las credenciales de Crystal',
    DOCS_DB_ODBC: 'la conexión a la base de documentos',
  }

  // ----------------------------------------------------------------
  // Lifecycle
  // ----------------------------------------------------------------
  connect() {
    this.#setupPermissions()
    this.#loadAll()
  }

  // ----------------------------------------------------------------
  // Setup permisos
  // ----------------------------------------------------------------
  #setupPermissions() {
    const perms = SStore.get('Permissions') || []

    const canUpload   = perms.includes('Configurations_General_UploadDefaultPrintFormat')
    const canDownload = perms.includes('Configurations_General_DownloadDefaultPrintFormat')

    if (canUpload) {
      this.uploadWrapperTarget.classList.remove('hidden')
      this.updateFormatWrapperTarget.classList.remove('hidden')
    }

    if (canDownload) {
      this.downloadWrapperTarget.classList.remove('hidden')
    }
  }

  // ----------------------------------------------------------------
  // Carga inicial
  // ----------------------------------------------------------------
  async #loadAll() {
    // Cada sección tiene su propia consulta → loader independiente por sección
    // (sin overlay global de página). Ver CLAUDE.md §15.
    await Promise.all([
      this.#loadGeneralConfigs(),
      this.#loadSettings(),
    ])
  }

  async #loadGeneralConfigs() {
    this.#showSectionLoader(this.formatLoaderTarget)
    try {
      const data = await this.#proxyFetch('/api/GeneralConfigs/GetGeneralConfigs')

      if (data.Data && data.Data.length > 0) {
        const config = data.Data[0]
        this.#generalConfigId = config.Id

        const fullPath = config.DefaultPrintFormatPath || ''
        const fileName = fullPath ? fullPath.split('\\').at(-1) : ''
        this.printFormatInputTarget.value = fileName

        this.#renderAuditText(
          this.formatAuditTarget, this.formatAuditTextTarget,
          config.UpdateDate, config.UpdatedBy
        )
      } else {
        showToast(data.Message || 'No se encontraron configuraciones', 'warning')
      }
    } catch (err) {
      showToast(err.message || 'Error al cargar configuraciones generales', 'error')
    } finally {
      this.#hideSectionLoader(this.formatLoaderTarget)
    }
  }

  // ----------------------------------------------------------------
  // Ajustes (`settings`)
  // ----------------------------------------------------------------
  async #loadSettings() {
    this.groupLoaderTargets.forEach(el => this.#showSectionLoader(el))
    try {
      const json = await this.#settingsFetch('/api/settings')
      const list = Array.isArray(json.Data) ? json.Data : []

      this.#settings = new Map(list.map(setting => [setting.Code, setting]))
      this.#applySettings()
      this.#renderGroupAudits()
      this.#applyEngineHints()
      this.#refreshGroupButtons()
    } catch (err) {
      showToast(err.message || 'Error al cargar los ajustes', 'error')
    } finally {
      this.groupLoaderTargets.forEach(el => this.#hideSectionLoader(el))
    }
  }

  /**
   * Vuelca los valores en los inputs y deja el baseline: el botón Actualizar se
   * habilita solo con lo que difiere, y solo eso se manda.
   */
  #applySettings() {
    this.settingInputTargets.forEach(input => {
      const setting = this.#settings.get(input.dataset.settingCode)
      if (!setting) return

      // Un ajuste oculto (`IsVisible: false`) NO trae valor: el servidor no lo
      // devuelve nunca. El input nace vacío y el placeholder es lo que le dice
      // al operador si ya hay una contraseña guardada — sin eso, un campo vacío
      // es indistinguible de uno sin configurar.
      const value = setting.IsVisible ? (setting.Value ?? '') : ''

      if (input.tagName === 'SELECT') this.#applySelectValue(input, value)
      else                            input.value = value

      input.dataset.baseline = input.value

      if (!setting.IsVisible) {
        input.placeholder = setting.HasValue
          ? '•••••••• (hay un valor guardado)'
          : 'Sin configurar'
      }
    })
  }

  /**
   * Preserva un valor que no está en el catálogo del select (ej. un motor
   * importado): se inyecta como opción temporal en vez de perderlo en silencio.
   */
  #applySelectValue(select, value) {
    if (value && ![...select.options].some(opt => opt.value === value)) {
      select.add(new Option(value, value))
    }
    select.value = value
  }

  /** Inputs de un grupo cuyo valor difiere del que trajo el servidor. */
  #changedInputs(group) {
    return this.settingInputTargets.filter(input => {
      const setting = this.#settings.get(input.dataset.settingCode)
      if (!setting || setting.GroupCode !== group) return false

      return input.value !== (input.dataset.baseline ?? '')
    })
  }

  onSettingInput(event) {
    this.#refreshGroupButtons()

    if (event?.target?.dataset?.settingCode === 'DOCS_DB_ODBC_ENGINE') {
      this.#applyEngineHints()
    }
  }

  #refreshGroupButtons() {
    this.groupButtonTargets.forEach(button => {
      button.disabled = this.#changedInputs(button.dataset.settingGroup).length === 0
    })
  }

  /**
   * Guarda los ajustes cambiados de un grupo, uno por petición: cada ajuste es
   * su propio recurso y el `code` va en el path.
   *
   * ⚠️ Un campo oculto vacío NO se manda: su baseline es la cadena vacía, así
   * que dejarlo en blanco no cuenta como cambio y la contraseña guardada queda
   * intacta. Para borrarla hay que escribir algo y volver a vaciar... o hacerlo
   * desde la base; es el precio de no devolver nunca el valor.
   */
  async saveGroup(event) {
    const group   = event.currentTarget.dataset.settingGroup
    const changed = this.#changedInputs(group)
    if (changed.length === 0) return

    const label     = this.constructor.GROUP_LABELS[group] || 'estos ajustes'
    const confirmed = await confirm(
      `¿Está seguro de que desea actualizar ${label}?`,
      'Actualizar ajustes'
    )
    if (!confirmed) return

    showLoading('Guardando los ajustes, espere por favor...')

    try {
      for (const input of changed) {
        await this.#settingsFetch(`/api/settings/${input.dataset.settingCode}`, {
          method: 'PATCH',
          body:   JSON.stringify({ Value: input.value }),
        })
      }

      showToast('Ajustes actualizados con éxito.', 'success')
    } catch (err) {
      showAlert({
        type:    ALERT_TYPES.ERROR,
        title:   'Error al actualizar los ajustes',
        message: err.message || 'Error desconocido',
      })
    } finally {
      hideLoading()
      // Siempre, incluso si falló: la tanda se manda de a un ajuste por
      // petición, así que un error a mitad de camino deja algunos guardados y
      // otros no. Recargar es lo único que deja la pantalla contando la verdad.
      await this.#loadSettings()
    }
  }

  toggleSecret(event) {
    const field = event.currentTarget.closest('[data-secret-field]')
    const input = field?.querySelector('input')
    const icon  = event.currentTarget.querySelector('.material-icons')
    if (!input) return

    const hidden     = input.type === 'password'
    input.type       = hidden ? 'text' : 'password'
    icon.textContent = hidden ? 'visibility' : 'visibility_off'
  }

  // ----------------------------------------------------------------
  // Base de documentos — ayudas por motor y prueba de conexión
  // ----------------------------------------------------------------
  /**
   * Los campos son los mismos pero no significan lo mismo en los dos motores
   * (CLAUDE.md §37). En vez de dejar que el operador lo descubra con un error de
   * conexión, el texto de ayuda de cada campo cambia con el motor elegido.
   */
  #applyEngineHints() {
    const engine = this.#inputFor('DOCS_DB_ODBC_ENGINE')?.value || ''
    const hana   = engine === 'HANA'

    if (!engine) {
      this.engineNoticeTarget.classList.add('hidden')
    } else {
      this.engineNoticeTextTarget.textContent = hana
        ? 'SAP HANA: la cadena de conexión es SERVERNODE=servidor:puerto. El puerto es obligatorio y la base de datos no entra en la cadena — califica cada consulta.'
        : 'SQL Server: la cadena de conexión es Server=servidor;Database=base. El puerto es opcional (1433 implícito).'
      this.engineNoticeTarget.classList.remove('hidden')
    }

    this.#setHint('DOCS_DB_ODBC_PORT', hana
      ? 'Obligatorio en SAP HANA: es el puerto SQL de la instancia (3NN15 — 30015 para la instancia 00).'
      : 'Opcional en SQL Server: sin puerto se usa el 1433.')

    this.#setHint('DOCS_DB_ODBC_DATABASE', hana
      ? 'No viaja en la cadena de conexión: califica cada consulta (CALL CL_DOCS.SP1).'
      : 'Va en la cadena de conexión como Database=.')

    this.#setHint('DOCS_DB_ODBC_SCHEMA', hana
      ? 'En SAP HANA la base de datos ES el esquema; este campo no se usa.'
      : 'Normalmente dbo.')
  }

  #setHint(code, text) {
    const hint = this.settingHintTargets.find(el => el.dataset.settingCode === code)
    if (!hint) return

    hint.textContent = text
    hint.classList.toggle('hidden', !text)
  }

  /**
   * Prueba la conexión con los valores GUARDADOS, no con los del formulario: el
   * servidor arma la cadena desde `settings`. Por eso, si hay cambios sin
   * guardar, se avisa — o el operador probaría lo anterior creyendo que probó
   * lo que acaba de escribir.
   */
  async testExternalDb() {
    const pending = this.#changedInputs('DOCS_DB_ODBC').length > 0

    this.btnTestDbTarget.disabled = true
    this.#renderHealth(null, 'Probando la conexión…', '')

    try {
      const json = await this.#settingsFetch('/api/external_db_health_checks', {
        method: 'POST',
        body:   JSON.stringify({ GroupCode: 'DOCS_DB_ODBC' }),
      })

      const data   = json.Data || {}
      const detail = [
        data.Engine    ? `Motor: ${data.Engine}`       : null,
        data.Version   ? `Versión: ${data.Version}`    : null,
        data.LatencyMs != null ? `${data.LatencyMs} ms` : null,
        pending ? 'La prueba usa los valores guardados; hay cambios sin guardar.' : null,
      ].filter(Boolean).join(' · ')

      this.#renderHealth(data.Ok === true, json.Message || '', detail)
    } catch (err) {
      this.#renderHealth(false, err.message || 'No se pudo probar la conexión.', '')
    } finally {
      this.btnTestDbTarget.disabled = false
    }
  }

  /** @param ok true | false | null (null = en curso). */
  #renderHealth(ok, message, detail) {
    const palette = ok === null
      ? { border: 'border-blue-100',   bg: 'bg-blue-50',   text: 'text-blue-700',   icon: 'hourglass_top' }
      : ok
        ? { border: 'border-green-100', bg: 'bg-green-50',  text: 'text-green-700',  icon: 'check_circle' }
        : { border: 'border-red-100',   bg: 'bg-red-50',    text: 'text-red-700',    icon: 'error' }

    const box = this.healthResultTarget
    box.className = `mt-4 flex items-start gap-2 rounded-lg border px-3 py-2.5 ${palette.border} ${palette.bg} ${palette.text}`

    this.healthIconTarget.textContent    = palette.icon
    this.healthMessageTarget.textContent = message
    this.healthDetailTarget.textContent  = detail || ''
    this.healthDetailTarget.classList.toggle('hidden', !detail)
  }

  // ----------------------------------------------------------------
  // Upload: selección de archivo
  // ----------------------------------------------------------------
  triggerFileInput() {
    this.fileInputTarget.click()
  }

  onFileSelected(event) {
    const file = event.target.files[0]
    this.#selectedFile = null
    this.printFormatInputTarget.value = ''
    this.btnUpdateFormatTarget.disabled = true
    this.printFormatErrorTarget.classList.add('hidden')

    if (!file) return

    const validExtension = /\.rpt$/i.test(file.name)
    if (!validExtension) {
      showToast(
        'Por favor selecione un formato de impresión válido para continuar, gracias!!!',
        'error'
      )
      this.printFormatErrorTarget.classList.remove('hidden')
      // Limpiar el file input para permitir re-selección
      this.fileInputTarget.value = ''
      return
    }

    this.#selectedFile = file
    this.printFormatInputTarget.value = file.name
    this.btnUpdateFormatTarget.disabled = false
  }

  // ----------------------------------------------------------------
  // Actualizar formato de impresión
  // ----------------------------------------------------------------
  async updatePrintFormat() {
    if (!this.#selectedFile || !this.#generalConfigId) return

    const confirmed = await confirm(
      '¿Está seguro de que desea actualizar el formato de impresión por defecto?',
      'Actualizar formato de impresión'
    )
    if (!confirmed) return

    showLoading('Editando la configuración general, espere por favor...')

    const formData = new FormData()
    formData.append('filePrintFormat', this.#selectedFile)

    try {
      await this.#proxyFetch(
        `/api/GeneralConfigs?generalConfigsId=${this.#generalConfigId}`,
        {
          method: 'PATCH',
          headers: { 'Request-With-Files': 'true' },
          body: formData,
        }
      )

      showToast('Configuración general editada con éxito!!!', 'success')
      this.#selectedFile = null
      this.fileInputTarget.value = ''
      this.btnUpdateFormatTarget.disabled = true

      // Recargar para mostrar el nombre actualizado
      await this.#loadGeneralConfigs()
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al actualizar formato de impresión', message: err.message || 'Error desconocido' })
    } finally {
      hideLoading()
    }
  }

  // ----------------------------------------------------------------
  // Download formato de impresión
  // ----------------------------------------------------------------
  async downloadPrintFormat() {
    showLoading('Descargando formato de impresión predeterminado...')

    try {
      const session  = Storage.get('Session') || {}
      const token    = session.access_token
      const response = await fetch('/api/GeneralConfigs/default-print-format', {
        headers: token ? { Authorization: `Bearer ${token}` } : {}
      })

      if (!response.ok) {
        // Intentar parsear body como JSON para extraer mensaje de error
        const contentType = response.headers.get('content-type') || ''
        if (contentType.includes('application/json')) {
          const err = await response.json()
          throw new Error(err.Message || `HTTP ${response.status}`)
        }
        throw new Error(`HTTP ${response.status}`)
      }

      const blob     = await response.blob()
      const fileName = this.printFormatInputTarget.value || 'formato-impresion.rpt'
      const url      = window.URL.createObjectURL(blob)
      const link     = document.createElement('a')
      link.href      = url
      link.download  = fileName
      link.click()
      window.URL.revokeObjectURL(url)
    } catch (err) {
      showToast(err.message || 'Error al descargar el formato de impresión', 'error')
    } finally {
      hideLoading()
    }
  }

  // ----------------------------------------------------------------
  // Helpers: auditoría (última actualización)
  // ----------------------------------------------------------------
  /** Pinta, por grupo, la actualización más reciente de sus ajustes. */
  #renderGroupAudits() {
    this.groupAuditTargets.forEach(container => {
      const group   = container.dataset.settingGroup
      const latest  = [...this.#settings.values()]
        .filter(setting => setting.GroupCode === group && setting.UpdatedAt)
        .sort((a, b) => new Date(b.UpdatedAt) - new Date(a.UpdatedAt))[0]

      this.#renderAuditText(
        container, container.querySelector('[data-audit-text]'),
        latest?.UpdatedAt, latest?.UpdatedBy
      )
    })
  }

  #renderAuditText(container, textEl, date, user) {
    if (!container || !textEl) return

    const formatted = this.#formatDateTime(date)

    let text = ''
    if (formatted && user) text = `Actualizado el ${formatted} por ${user}`
    else if (formatted)    text = `Actualizado el ${formatted}`
    else if (user)         text = `Actualizado por ${user}`

    if (!text) { container.classList.add('hidden'); return }

    textEl.textContent = text
    container.classList.remove('hidden')
  }

  /** Formato yyyy-MM-dd HH:mm:ss (CLAUDE.md §5). */
  #formatDateTime(dateStr) {
    if (!dateStr) return ''
    const d = new Date(dateStr)
    if (isNaN(d.getTime())) return ''
    const pad = n => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
  }

  // ----------------------------------------------------------------
  // Helpers varios
  // ----------------------------------------------------------------
  #inputFor(code) {
    return this.settingInputTargets.find(input => input.dataset.settingCode === code)
  }

  // ----------------------------------------------------------------
  // Helpers: API
  // ----------------------------------------------------------------
  /**
   * Endpoints NATIVOS de Rails: van con la session cookie, sin Authorization
   * (CLAUDE.md §28). El mensaje real de la API viaja en el cuerpo (`Message`).
   */
  async #settingsFetch(url, options = {}) {
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

  /** Endpoints todavía en el .NET, que van por el proxy y usan el Bearer. */
  async #proxyFetch(url, options = {}) {
    const session = Storage.get('Session') || {}
    const token   = session.access_token

    // Para FormData no setear Content-Type (el browser lo pone con boundary)
    const isFormData = options.body instanceof FormData
    const defaultHeaders = {
      ...(isFormData ? {} : { 'Content-Type': 'application/json' }),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    }

    const response = await fetch(url, {
      ...options,
      headers: {
        ...defaultHeaders,
        ...(options.headers || {}),
      },
    })

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new Error(text || `HTTP ${response.status}`)
    }

    const contentType   = response.headers.get('content-type') || ''
    const contentLength = response.headers.get('content-length')
    if (contentLength === '0' || (!contentType.includes('json') && !contentType.includes('text'))) {
      return {}
    }
    const text = await response.text()
    if (!text || !text.trim()) return {}
    return JSON.parse(text)
  }

  // ----------------------------------------------------------------
  // Helpers: Loader por sección (carga de lectura — sin texto)
  // ----------------------------------------------------------------
  #showSectionLoader(target) { target?.classList.remove('hidden') }
  #hideSectionLoader(target) { target?.classList.add('hidden') }

}

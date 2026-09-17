import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';
import { showLoading, hideLoading } from 'vendor/clavisco/overlay';
import { relativeDate } from 'vendor/clavisco/format/dates';

/**
 * DocumentsEmailsController — Reporte de correos enviados.
 *
 * Migración del componente Angular EmailReportComponent
 * (pages/documents/email-report → ruta /email_report → nuevo path /documents/emails).
 *
 * Funcionalidad:
 *   - Formulario de filtros: fechas, tipo doc, estado correo, clave, to, cc, id receptor, nombre receptor
 *   - Tabla Tabulator server-side paginada
 *   - Acción "Ver detalle" → panel lateral con el campo Details (pre-formatted)
 *   - Acción "Ver documento" → navega a /documents/issued?clave=DocClave
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'inputInitialDate',
    'inputEndDate',
    'selectDocType',
    'selectEmailStatus',
    'inputDocClave',
    'inputEmailTo',
    'inputEmailCC',
    'inputRcprId',
    'inputRcprNombre',
    'panel',
    'panelBackdrop',
    'panelContent',
  ];

  static values = { ...TabulatorController.values };

  // ── Estado interno ────────────────────────────────────────────────────────

  #companyId       = null;
  #totalRecords    = 0;
  #detailDocClave  = null;   // clave del documento del correo abierto en el panel de detalle

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company   = SStore.get('CurrentCompany');
    this.#companyId = company?.companyId ?? null;

    const today = this.#todayString();
    this.inputInitialDateTarget.value = today;
    this.inputEndDateTarget.value     = today;

    super.connect();

    // Delegación para botones dentro de celdas Tabulator
    this.tableTarget.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-action-type]');
      if (!btn) return;
      const rowData = btn.dataset.rowData ? JSON.parse(btn.dataset.rowData) : null;
      if (!rowData) return;
      if (btn.dataset.actionType === 'view-detail')   this.#openDetail(rowData);
      if (btn.dataset.actionType === 'view-document') this.#goToDocument(rowData);
    });
  }

  // ── Acciones públicas ─────────────────────────────────────────────────────

  todayInitial() { this.inputInitialDateTarget.value = this.#todayString(); }
  todayEnd()     { this.inputEndDateTarget.value     = this.#todayString(); }

  search() {
    const initial = this.inputInitialDateTarget.value;
    const end     = this.inputEndDateTarget.value;
    if (!initial || !end) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Ingrese ambas fechas para consultar.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    if (initial > end) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'La fecha de inicio no puede ser posterior a la fecha final.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.table?.setData();
  }

  openPanel()  {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // Navega al documento del correo abierto en el panel de detalle (misma acción
  // que el botón "Ver documento" de la fila, para que el usuario no cierre el panel).
  viewDocumentFromPanel() {
    this.#goToDocument({ DocClave: this.#detailDocClave });
  }

  // ── Config Tabulator ──────────────────────────────────────────────────────

  getTableConfig() {
    return {
      ...super.getTableConfig(),
      data: undefined,   // evita que el [] heredado del base suprima el fetch remoto inicial (Tabulator requestDataCheck)
      height: '100%',
      maxHeight: undefined,  // sobreescribe el default 500px del TabulatorController
      layout: 'fitColumns',
      locale: TABULATOR_LOCALE,
      langs:  TABULATOR_LANGS,
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [5, 10, 15, 25],
      ajaxURL:         '/api/Email/GetOutgoingMailsByFilters/',
      ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
      ajaxResponse:    (_url, _params, response) => response,
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      columns: this.getColumns(),
      placeholder: 'No hay datos para mostrar',
    };
  }

  getColumns() {
    return [
      {
        title: 'Fecha creación',
        field: 'EmailCreateDate',
        widthGrow: 1.5,
        formatter: (cell) => this.#formatDateTime(cell.getValue()),
      },
      {
        title: 'Último intento',
        field: 'EmailLastAttempt',
        widthGrow: 1.5,
        formatter: (cell) => this.#formatDateTime(cell.getValue()),
      },
      {
        title: 'Estado correo',
        field: 'EmailStatus',
        widthGrow: 1,
        formatter: (cell) => {
          const statusMap = { 1: 'pendiente', 2: 'enviando', 3: 'error', 4: 'enviado' };
          return this.#emailStatusBadge(statusMap[cell.getValue()] ?? String(cell.getValue()));
        },
      },
      { title: 'Email To',        field: 'EmailOutputTo',  widthGrow: 2 },
      { title: 'Email CC',        field: 'EmailOutputCC',  widthGrow: 2 },
      { title: 'Remitente',       field: 'SenderEmail',    widthGrow: 2 },
      { title: 'Clave Doc',       field: 'DocClave',       widthGrow: 2 },
      { title: 'Nombre receptor', field: 'RcprNombre',     widthGrow: 2 },
      { title: 'ID receptor',     field: 'RcprIdeNumero',  widthGrow: 1 },
      {
        title: 'Acciones',
        field: '_actions',
        hozAlign: 'center',
        headerSort: false,
        widthGrow: 0.8,
        formatter: (cell) => {
          const row = cell.getRow().getData();
          const data = JSON.stringify(row).replace(/"/g, '&quot;');
          const hasDetail = row.Details && row.Details.trim() !== '';
          const detailTooltip = hasDetail
            ? 'Ver detalle del correo'
            : 'El correo debe tener detalle registrado para usar esta opción';
          return `
            <div class="flex items-center justify-center gap-1">
              <button type="button"
                      data-action-type="view-detail"
                      data-row-data="${data}"
                      data-tooltip="${detailTooltip}"
                      ${hasDetail ? '' : 'disabled'}
                      class="p-1.5 rounded transition-colors ${hasDetail ? 'text-blue-600 hover:bg-blue-50 cursor-pointer' : 'text-gray-300 cursor-not-allowed'}">
                <span class="material-icons text-base">lists</span>
              </button>
              <button type="button"
                      data-action-type="view-document"
                      data-row-data="${data}"
                      data-tooltip="Ver documento en Documentos Emitidos"
                      class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
                <span class="material-icons text-base">article</span>
              </button>
            </div>`;
        },
      },
    ];
  }

  // ── Helpers privados ──────────────────────────────────────────────────────

  async #fetchPage(params) {
    const page = params.page  ?? 1;
    const size = params.size  ?? 10;
    const startPos = page - 1;  // API espera número de página base-0, no offset

    const query = new URLSearchParams({
      CompanyId:     this.#companyId ?? '',
      InitialDate:   this.inputInitialDateTarget.value,
      EndDate:       this.inputEndDateTarget.value,
      DocType:       this.selectDocTypeTarget.value,
      EmailStatus:   this.selectEmailStatusTarget.value,
      DocClave:      this.inputDocClaveTarget.value,
      EmailOutputTo: this.inputEmailToTarget.value,
      EmailOutputCC: this.inputEmailCCTarget.value,
      RcprIdeNumero: this.inputRcprIdTarget.value,
      RcprNombre:    this.inputRcprNombreTarget.value,
      startPos,
      stepPos:       size,
    });

    this.table?.alert(TABULATOR_LOADING_HTML);
    try {
      const json = await this.#apiFetch(`/api/Email/GetOutgoingMailsByFilters/?${query}`);
      const total = json.Data?.[0]?.MaxQtyRowsFetch ?? 0;
      this.#totalRecords = total;
      const lastPage = Math.max(1, Math.ceil(total / size));
      return { data: json.Data ?? [], last_page: lastPage };
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al consultar correos.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return { data: [], last_page: 1 };
    } finally {
      this.table?.clearAlert();
    }
  }

  // Panel de detalle — muestra la misma información que un card del panel
  // "Historial de correos" (/documents/issued) pero sin el envoltorio de card,
  // ya que aquí siempre es un único correo: cabecera con fecha + estado, campos
  // de remitente/destinatarios/clave/receptor y el bloque de detalle al final.
  #openDetail(rowData) {
    this.#detailDocClave = rowData.DocClave ?? null;

    const detail    = this.#mailText(rowData.Details);
    const hasDetail = detail !== '—';

    const detailBlock = hasDetail
      ? `<p class="text-sm text-gray-700 whitespace-pre-wrap break-words leading-relaxed">${detail}</p>`
      : `<p class="text-sm text-gray-400 italic">Sin detalle registrado.</p>`;

    this.panelContentTarget.innerHTML = `
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs text-gray-400 mb-0.5">Fecha de creación</p>
          ${this.#relativeDateSpan(rowData.EmailCreateDate, 'text-sm font-semibold text-gray-800')}
        </div>
        ${this.#emailStatusIcon(rowData.EmailStatus)}
      </div>

      <div class="grid grid-cols-2 gap-4">
        ${this.#field('Último intento', this.#relativeDateSpan(rowData.EmailLastAttempt, 'text-sm text-gray-700'))}
        ${this.#field('Clave del documento', this.#mailText(rowData.DocClave))}
      </div>

      ${this.#field('Remitente', this.#mailText(rowData.SenderEmail))}
      ${this.#field('Para', this.#emailChips(rowData.EmailOutputTo))}
      ${this.#field('CC', this.#emailChips(rowData.EmailOutputCC))}

      <div class="grid grid-cols-2 gap-4">
        ${this.#field('Nombre del receptor', this.#mailText(rowData.RcprNombre))}
        ${this.#field('ID del receptor', this.#mailText(rowData.RcprIdeNumero))}
      </div>

      <div>
        <p class="text-xs text-gray-400 mb-1.5">Detalle de error</p>
        ${detailBlock}
      </div>`;

    this.openPanel();
  }

  // Span de fecha relativa (relativeDate compartido) con la fecha original
  // completa en el tooltip. Mismo formato que el panel Historial de correos.
  #relativeDateSpan(value, className) {
    const raw = (value == null) ? '' : String(value).trim();
    const hasValue = raw !== '' && raw.toLowerCase() !== 'null';
    if (!hasValue) return `<span class="${className}">—</span>`;
    return `<span class="${className} cursor-help" title="${this.#escapeHtml(raw)}">${relativeDate(value)}</span>`;
  }

  // Ícono + tooltip para el estado del correo (mismo estilo que Historial de correos).
  #iconTooltip(icon, bg, color, label) {
    return `<span class="relative group inline-flex items-center flex-shrink-0">
      <span class="inline-flex items-center justify-center rounded-full p-1.5 cursor-default"
            style="background-color:${bg}; color:${color}">
        <span class="material-icons" style="font-size:22px; line-height:1">${icon}</span>
      </span>
      <span class="pointer-events-none absolute top-full right-0 mt-1 z-20
                   whitespace-nowrap rounded bg-gray-800 text-white text-[11px] px-2 py-1
                   opacity-0 group-hover:opacity-100 transition-opacity duration-150">${label}</span>
    </span>`;
  }

  #emailStatusIcon(code) {
    const map = {
      1: { label: 'Pendiente', icon: 'schedule',     bg: '#f3f4f6', color: '#6b7280' },
      2: { label: 'Enviando',  icon: 'sync',         bg: '#e8f0fe', color: '#1a56db' },
      3: { label: 'Error',     icon: 'error',        bg: '#fdecea', color: '#c0392b' },
      4: { label: 'Enviado',   icon: 'check_circle', bg: '#e8f5ee', color: '#3a7d52' },
    };
    const s = map[Number(code)] ?? { label: String(code ?? ''), icon: 'help', bg: '#f3f4f6', color: '#4b5563' };
    return this.#iconTooltip(s.icon, s.bg, s.color, s.label);
  }

  // Renderiza un campo etiqueta + valor. valueHtml puede ser texto ya escapado
  // (via #mailText) o HTML (via #emailChips).
  #field(label, valueHtml) {
    return `<div>
      <p class="text-xs text-gray-400 mb-1">${label}</p>
      <div class="text-sm text-gray-700 break-all">${valueHtml}</div>
    </div>`;
  }

  // Normaliza un valor de texto de la API: null/undefined/""/"null" → "—".
  #mailText(value) {
    if (value == null) return '—';
    const str = String(value).trim();
    if (str === '' || str.toLowerCase() === 'null') return '—';
    return this.#escapeHtml(str);
  }

  // Parsea una lista de correos concatenados por ";" en un arreglo limpio.
  #parseEmails(value) {
    if (value == null) return [];
    return String(value)
      .split(';')
      .map((e) => e.trim())
      .filter((e) => e !== '' && e.toLowerCase() !== 'null');
  }

  // Renderiza una lista de correos como chips individuales. Si no hay, "—".
  #emailChips(value) {
    const emails = this.#parseEmails(value);
    if (!emails.length) return '<span class="text-sm text-gray-400">—</span>';
    return `
      <div class="flex flex-wrap gap-1.5">
        ${emails.map((e) => `
          <span class="inline-flex items-center max-w-full bg-gray-100 text-gray-700 text-xs font-medium px-2 py-0.5 rounded-md break-all">
            ${this.#escapeHtml(e)}
          </span>`).join('')}
      </div>`;
  }

  #escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  #goToDocument(rowData) {
    if (!rowData.DocClave) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'Sin clave de documento.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    Turbo.visit(`/documents/issued?clave=${encodeURIComponent(rowData.DocClave)}`);
  }

  #emailStatusBadge(status) {
    const map = {
      pendiente:  { bg: '#f3f4f6', color: '#6b7280', label: 'Pendiente'  },
      enviando:   { bg: '#e8f0fe', color: '#1a56db', label: 'Enviando'   },
      error:      { bg: '#fdecea', color: '#c0392b', label: 'Error'      },
      enviado:    { bg: '#e8f5ee', color: '#3a7d52', label: 'Enviado'    },
    };
    const { bg, color, label } = map[status] ?? { bg: '#f3f4f6', color: '#4b5563', label: status };
    return `<span style="background-color:${bg}; color:${color};"
                  class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${label}
    </span>`;
  }

  #formatDateTime(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  #todayString() {
    const d = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
  }

  async #apiFetch(url, options = {}) {
    const token     = (Storage.get('Session') || {}).access_token;
    const company   = SStore.get('CurrentCompany');
    const companyId = company?.companyId ?? this.#companyId;

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
    });

    const clMessage = response.headers.get('cl-message');
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage); } catch { return clMessage; }
    })() : null;

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText);
      throw new Error(decodedMessage || text || `HTTP ${response.status}`);
    }

    const hasBody = response.status !== 204 &&
                    response.headers.get('content-length') !== '0' &&
                    response.headers.get('content-type')?.includes('application/json');
    if (!hasBody) return { Message: decodedMessage || null };

    const json = await response.json();
    if (decodedMessage && !json.Message) json.Message = decodedMessage;
    return json;
  }
}

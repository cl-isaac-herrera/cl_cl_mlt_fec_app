import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';
import { showLoading, hideLoading } from 'vendor/clavisco/overlay';

/**
 * ReceptionLogsController — Logs del procesador de correo de recepción.
 *
 * Replica la funcionalidad del componente Angular LogComponent
 * (pages/documents/log → ruta /mailParser → nuevo path /documents/receptions/logs).
 *
 *   - Formulario con rango de fechas (StartDate, EndDate) + botones "Hoy"
 *   - Validación: fechas ≤ hoy, StartDate ≤ EndDate
 *   - Tabla Tabulator server-side
 *   - Columnas: Fecha Log, Archivo, Remitente, Estado, Error, Bandeja de Entrada
 *   - Botón por fila: Descargar Email (GET blob)
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'inputStartDate',
    'inputEndDate',
  ];

  static values = { ...TabulatorController.values };

  // ── Estado interno ────────────────────────────────────────────────────────

  #companyId    = null;
  #permissions  = [];
  #totalRecords = 0;
  #cachedData   = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company    = SStore.get('CurrentCompany');
    this.#companyId  = company?.companyId ?? null;
    this.#permissions = SStore.get('Permissions') ?? [];

    const today = this.#todayString();
    this.inputStartDateTarget.value = today;
    this.inputEndDateTarget.value   = today;

    super.connect();

    // Event delegation para botones dentro de las celdas de Tabulator
    this.tableTarget.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-action-type]');
      if (!btn) return;
      if (btn.dataset.actionType === 'download-email') {
        const rowId = parseInt(btn.dataset.rowId, 10);
        this.#downloadEmail(rowId);
      }
    });
  }

  // ── Acciones públicas ─────────────────────────────────────────────────────

  todayStart() {
    this.inputStartDateTarget.value = this.#todayString();
  }

  todayEnd() {
    this.inputEndDateTarget.value = this.#todayString();
  }

  search() {
    if (!this.#isValidDateRange()) {
      Swal.fire({
        icon: 'info',
        title: 'Rango de fechas inválido',
        text: 'La fecha de búsqueda es futura o la fecha de inicio es posterior a la fecha final. Por favor, verifica y ajusta las fechas para asegurarte de que el rango de búsqueda sea válido.',
        confirmButtonText: 'Aceptar'
      });
      return;
    }
    this.table?.setData();
  }

  // ── TabulatorController contract ──────────────────────────────────────────

  getTableConfig() {
    return {
      ...super.getTableConfig(),
      data: undefined,   // evita que el [] heredado del base suprima el fetch remoto inicial (Tabulator requestDataCheck)
      height: '100%',
      maxHeight: undefined,
      layout: 'fitColumns',
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [5, 10, 25, 50],
      ajaxURL: '/api/Log/GetMailParserLogs',
      ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
      ajaxResponse: (_url, _params, response) => response,
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      columns: this.getColumns(),
      placeholder: 'Seleccione un rango de fechas y presione Consultar',
      movableRows: false,
    };
  }

  getColumns() {
    return [
      {
        title: 'Fecha Log',
        field: 'TrxDateC',
        widthGrow: 1.5,
        formatter: (cell) => {
          const val = cell.getValue();
          return val ? this.#formatDateTime(val) : '';
        },
      },
      { title: 'Archivo',            field: 'FileName',            widthGrow: 2 },
      { title: 'Remitente',          field: 'EmailFrom',            widthGrow: 2 },
      {
        title: 'Estado',
        field: 'Status',
        widthGrow: 1,
        formatter: (cell) => this.#statusBadge(cell.getValue()),
      },
      { title: 'Error',              field: 'Exception',            widthGrow: 2 },
      { title: 'Bandeja de Entrada', field: 'MailParserInboxEmail', widthGrow: 2 },
      {
        title: 'Acciones',
        field: 'Id',
        width: 80,
        hozAlign: 'center',
        headerSort: false,
        formatter: (cell) => {
          const id = cell.getValue();
          return `<button type="button"
                          data-action-type="download-email"
                          data-row-id="${id}"
                          data-tooltip="Descargar Email"
                          class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
                    <span class="material-icons text-base">mail</span>
                  </button>`;
        },
      },
    ];
  }

  // ── Fetch + lógica privada ────────────────────────────────────────────────

  async #fetchPage(params) {
    const page = params.page ?? 1;
    const size = params.size ?? 10;

    if (!this.#isValidDateRange()) return { data: [], last_page: 1 };

    const startDate = this.inputStartDateTarget.value;
    const endDate   = this.inputEndDateTarget.value;

    const url = `/api/Log/GetMailParserLogs?companyId=${this.#companyId}&FFini=${startDate}&FFin=${endDate}`;

    this.table?.alert(TABULATOR_LOADING_HTML);

    try {
      const apiPage = page - 1; // la API es 0-indexed

      const { json, response } = await this.#apiFetchWithResponse(url, {
        headers: {
          'cl-dba-pagination-page':      String(apiPage),
          'cl-dba-pagination-page-size': String(size),
        },
      });

      const totalRecords = parseInt(response.headers.get('cl-dba-pagination-records-count') ?? '0', 10) || (json.Data?.length ?? 0);
      const lastPage     = Math.max(1, Math.ceil(totalRecords / size));

      this.#totalRecords = totalRecords;

      const records = (json.Data ?? []).map(r => ({
        ...r,
        TrxDateC: r.TrxDate ? this.#formatDateTime(r.TrxDate) : '',
      }));

      if (records.length) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Logs de recepción obtenidos con éxito',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      } else {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'info',
          title: json.Message || 'No se encontraron registros',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      }

      return { data: records, last_page: Math.max(1, lastPage) };
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al obtener los logs',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return { data: [], last_page: 1 };
    } finally {
      this.table?.clearAlert();
    }
  }

  async #downloadEmail(id) {
    showLoading('Descargando email...');
    try {
      const session   = Storage.get('Session') || {};
      const token     = session.access_token;
      const company   = SStore.get('CurrentCompany');
      const companyId = company?.companyId ?? this.#companyId;

      const response = await fetch(`/api/Log/email-processor/${id}/email`, {
        headers: {
          'API': 'ApiAppUrl',
          'X-Skip-Error-Interceptor': 'true',
          ...(token     ? { Authorization:   `Bearer ${token}` }   : {}),
          ...(companyId ? { 'Cl-Company-Id': String(companyId) }   : {}),
        },
      });

      if (!response.ok) {
        // El backend puede devolver JSON dentro de un blob cuando falla
        const clMessage = response.headers.get('cl-message');
        const decoded   = clMessage ? (() => { try { return decodeURIComponent(clMessage); } catch { return clMessage; } })() : null;
        if (decoded) throw new Error(decoded);

        const errBlob = await response.blob();
        if (errBlob.type === 'application/json') {
          const text = await errBlob.text();
          const json = JSON.parse(text);
          throw new Error(json.Message || json.message || `HTTP ${response.status}`);
        }
        throw new Error(`HTTP ${response.status}`);
      }

      const blob        = await response.blob();
      const disposition = response.headers.get('Content-Disposition') ?? '';
      const match       = disposition.match(/filename\*?=(?:UTF-8''|"?)([^";]+)/i);
      const fileName    = match ? decodeURIComponent(match[1].replace(/"/g, '')) : 'email.eml';

      const url  = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href       = url;
      link.download   = fileName;
      link.click();
      window.URL.revokeObjectURL(url);
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al descargar el email',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } finally {
      hideLoading();
    }
  }

  // Igual que #apiFetch pero devuelve también el objeto Response para leer headers
  async #apiFetchWithResponse(url, options = {}) {
    const session   = Storage.get('Session') || {};
    const token     = session.access_token;
    const company   = SStore.get('CurrentCompany');
    const companyId = company?.companyId ?? this.#companyId;

    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(token     ? { Authorization:   `Bearer ${token}` }   : {}),
        ...(companyId ? { 'Cl-Company-Id': String(companyId) }   : {}),
        ...(options.headers || {}),
      },
    });

    const clMessage = response.headers.get('cl-message');
    const decodedMessage = clMessage
      ? (() => { try { return decodeURIComponent(clMessage); } catch { return clMessage; } })()
      : null;

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText);
      throw new Error(decodedMessage || text || `HTTP ${response.status}`);
    }

    const json = await response.json();
    if (decodedMessage && !json.Message) json.Message = decodedMessage;
    return { json, response };
  }

  async #apiFetch(url, options = {}) {
    const session   = Storage.get('Session') || {};
    const token     = session.access_token;
    const company   = SStore.get('CurrentCompany');
    const companyId = company?.companyId ?? this.#companyId;

    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(token     ? { Authorization:   `Bearer ${token}` }   : {}),
        ...(companyId ? { 'Cl-Company-Id': String(companyId) }   : {}),
        ...(options.headers || {}),
      },
    });

    const clMessage = response.headers.get('cl-message');
    const decodedMessage = clMessage
      ? (() => { try { return decodeURIComponent(clMessage); } catch { return clMessage; } })()
      : null;

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

  // ── Helpers ───────────────────────────────────────────────────────────────

  #todayString() {
    const d = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  #formatDateTime(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  #isValidDateRange() {
    const start = this.inputStartDateTarget.value;
    const end   = this.inputEndDateTarget.value;
    if (!start || !end) return false;
    const today     = new Date();
    today.setHours(23, 59, 59, 999);
    const startDate = new Date(start);
    const endDate   = new Date(end);
    return startDate <= today && endDate <= today && startDate <= endDate;
  }

  #statusBadge(status) {
    if (!status?.trim()) return '';
    const map = {
      'PROCESSED':         { bg: '#e8f5ee', color: '#3a7d52' },
      'CRASHED':           { bg: '#fdecea', color: '#c0392b' },
      'FAILED LOADING XML': { bg: '#fdecea', color: '#c0392b' },
    };
    const style = map[status?.toUpperCase()] ?? { bg: '#f3f4f6', color: '#4b5563' };
    if (!style) return '';
    return `<span style="background-color:${style.bg}; color:${style.color};"
                  class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${status}
    </span>`;
  }
}

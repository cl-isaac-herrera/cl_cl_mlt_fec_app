import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * CompaniesController — Listado de compañías (/configurations/companies).
 *
 * Endpoint nativo de Rails: GET /api/companies?name=&page=&per_page=
 * (reemplaza GET /api/Companies/GetCompanies del .NET — ver CLAUDE.md §28).
 *
 * La tabla muestra nombre, estado y acciones. El nombre legal, el nombre
 * comercial y la identificación salieron del listado por decisión de producto —
 * son columnas de `companies`, así que volver a mostrarlas o filtrar por ellas es
 * sumarlas a `getColumns()` y al scope `search` del modelo.
 *
 * Permisos (CLAUDE.md §26 — se deshabilita con tooltip, no se oculta):
 *   - Configurations_Companies_ListAccess → gatea la pantalla (menú + endpoint)
 *   - Configurations_Companies_Create     → botón "Nueva Compañía"
 *   - Configurations_Companies_Update     → botón "Editar" de la fila
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'searchName',
    'btnCreate', 'btnCreateWrap',
  ];

  static values = { ...TabulatorController.values };

  // ── Estado interno ─────────────────────────────────────────────────────────

  #permissions = [];        // string[]
  #totalRecords = 0;        // total real del servidor (ver CLAUDE.md §17)

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  connect() {
    this.#permissions = SStore.get('Permissions') || [];

    // Botón "Nueva Compañía": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.#hasPerm('Configurations_Companies_Create')) {
      this.#enableCreateButton();
    } else if (this.hasBtnCreateWrapTarget) {
      this.#attachTooltip(this.btnCreateWrapTarget);
    }

    super.connect();   // construye la tabla y dispara la carga remota de la página 1
  }

  // ── Configuración Tabulator (paginación remota) ──────────────────────────────

  getTableConfig() {
    return {
      height: '100%',
      maxHeight: undefined,
      layout: 'fitColumns',
      movableRows: false,
      placeholder: 'No se encontraron compañías',
      columnDefaults: { headerSort: false },

      // Paginación server-side
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 15, 25],
      // Contador propio: Tabulator infiere el total como last_page*pageSize y lo
      // sobreestima cuando la última página no está llena (CLAUDE.md §17).
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      ajaxURL: '/api/companies',
      ajaxRequestFunc: (url, config, params) => this.#fetchPage(url, params),
      ajaxResponse: (_url, _params, response) => response,

      columns: this.getColumns(),
    };
  }

  getColumns() {
    return [
      { title: 'Nombre', field: 'Name', widthGrow: 3 },
      {
        title: 'Estado', field: 'Active', width: 120,
        formatter: (cell) => this.#statusBadge(cell.getValue() ? 'active' : 'inactive'),
      },
      {
        title: 'Acciones', field: 'Id', width: 110, hozAlign: 'center',
        formatter: () => this.#actionButtons(),
        cellClick: (e, cell) => {
          if (e.target.closest('[data-action-type="edit"]')) this.#onEditClick(cell.getRow().getData());
        },
      },
    ];
  }

  /**
   * Carga remota. El total viene en el cuerpo (`Data.Total`), no en un header ni
   * pegado a cada fila como hacía el .NET con `MaxQtyRowsFetch`.
   * @param {string} url    ajaxURL configurada
   * @param {Object} params { page (1-indexed), size, ... }
   * @returns {Promise<{data: Array, last_page: number}>}
   */
  async #fetchPage(url, params) {
    const size = params.size || 10;

    const qp = new URLSearchParams({
      name:     this.searchNameTarget.value.trim(),
      page:     String(params.page || 1),
      per_page: String(size),
    });

    try {
      const json = await this.#apiFetch(`${url}?${qp}`);

      if (!json.Data) {
        showToast(json.Message || 'Error al obtener las compañías', 'error');
        return { data: [], last_page: 1 };
      }

      const total = json.Data.Total ?? 0;
      this.#totalRecords = total;
      const lastPage = Math.max(1, Math.ceil(total / size));
      return { data: json.Data.Items ?? [], last_page: lastPage };
    } catch (err) {
      showToast(err.message || 'Error al obtener las compañías', 'error');
      return { data: [], last_page: 1 };
    }
  }

  // ── Acciones públicas ──────────────────────────────────────────────────────

  search() {
    // setData() recarga vía ajax y vuelve a la página 1
    this.table?.setData();
  }

  navigateCreate() {
    // Defensa en profundidad: la UI ya deshabilita el botón, pero se puede
    // manipular (CLAUDE.md §26).
    if (!this.#hasPerm('Configurations_Companies_Create')) {
      showToast('No cuenta con permisos para crear compañías.', 'info');
      return;
    }
    Turbo.visit('/configurations/companies/new');
  }

  // ── Event handlers de fila ─────────────────────────────────────────────────

  #onEditClick(company) {
    if (!this.#hasPerm('Configurations_Companies_Update')) {
      showToast('No cuenta con permisos para editar compañías.', 'info');
      return;
    }
    Turbo.visit(`/configurations/companies/${company.Id}/edit`);
  }

  // ── Render helpers (formatters Tabulator) ────────────────────────────────────

  #statusBadge(status) {
    const map = {
      active:   { bg: '#e8f5ee', color: '#3a7d52', label: 'Activo'   },
      inactive: { bg: '#fdecea', color: '#c0392b', label: 'Inactivo' },
    };
    const { bg, color, label } = map[status] ?? { bg: '#f3f4f6', color: '#4b5563', label: status };
    return `<span style="background-color:${bg}; color:${color};" class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">${label}</span>`;
  }

  // Editar: deshabilitado con tooltip si no tiene permiso (ver CLAUDE.md §26).
  // El data-tooltip va en el <span> envolvente porque un <button disabled> no
  // emite eventos de mouse; el setupTooltip base (tabla) lo detecta ahí.
  #actionButtons() {
    return this.#hasPerm('Configurations_Companies_Update')
      ? `<div class="flex items-center justify-center gap-1">
           <button type="button" data-action-type="edit" data-tooltip="Editar"
                   class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
             <span class="material-icons text-base">edit</span>
           </button>
         </div>`
      : `<div class="flex items-center justify-center gap-1">
           <span data-tooltip="No cuenta con permisos para editar compañías">
             <button type="button" disabled
                     class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
               <span class="material-icons text-base">edit</span>
             </button>
           </span>
         </div>`;
  }

  // ── Helpers de UI ──────────────────────────────────────────────────────────

  /** Permissions es string[] — e.g. ["Configurations_Companies_Create"] */
  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Nueva Compañía" (nace deshabilitado/gris con tooltip de
  // "sin permisos" en su <span> envolvente). Ver CLAUDE.md §26.
  #enableCreateButton() {
    const btn = this.btnCreateTarget;
    btn.disabled = false;
    btn.classList.remove('bg-gray-300', 'text-gray-500', 'cursor-not-allowed', 'pointer-events-none');
    btn.classList.add('bg-blue-600', 'text-white', 'hover:bg-blue-700');
    if (this.hasBtnCreateWrapTarget) this.btnCreateWrapTarget.removeAttribute('data-tooltip');
  }

  // Tooltip flotante scoped a un elemento del toolbar (fuera de la tabla, que el
  // setupTooltip base no cubre). Reposiciona dentro del viewport. Ver CLAUDE.md §25/§26.
  #attachTooltip(el) {
    let tip = document.getElementById('cl-tabulator-tooltip');
    if (!tip) {
      tip = document.createElement('div');
      tip.id = 'cl-tabulator-tooltip';
      tip.style.cssText = [
        'position:fixed', 'z-index:9999', 'pointer-events:none',
        'background:#1f2937', 'color:#fff', 'padding:4px 8px',
        'border-radius:4px', 'font-size:12px', 'line-height:1.35',
        'max-width:min(320px, calc(100vw - 16px))',
        'white-space:normal', 'word-break:break-word', 'text-align:left',
        'opacity:0', 'transition:opacity 0.15s',
      ].join(';');
      document.body.appendChild(tip);
    }

    const place = (e) => {
      const margin = 8;
      const { width: w, height: h } = tip.getBoundingClientRect();
      let left = e.clientX + 12;
      let top  = e.clientY - h - 10;
      if (left + w + margin > window.innerWidth) left = e.clientX - w - 12;
      if (left < margin) left = margin;
      if (left + w + margin > window.innerWidth) left = window.innerWidth - w - margin;
      if (top < margin) top = e.clientY + 18;
      if (top + h + margin > window.innerHeight) top = window.innerHeight - h - margin;
      tip.style.left = left + 'px';
      tip.style.top  = top + 'px';
    };

    el.addEventListener('mouseenter', (e) => {
      if (!el.dataset.tooltip) return;
      tip.textContent = el.dataset.tooltip;
      place(e);
      tip.style.opacity = '1';
    });
    el.addEventListener('mousemove', (e) => {
      if (tip.style.opacity === '1') place(e);
    });
    el.addEventListener('mouseleave', () => {
      tip.style.opacity = '0';
    });
  }

  /**
   * Endpoint nativo de Rails: la sesión viaja en la cookie, así que no se arma
   * ningún header Authorization — getApiHeaders() aporta lo único que hace falta.
   */
  async #apiFetch(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        'Accept': 'application/json',
        ...getApiHeaders(),
        ...(options.headers || {}),
      },
    });

    if (!response.ok) {
      const body = await response.json().catch(() => null);
      throw new Error(body?.Message || `HTTP ${response.status}`);
    }

    return response.json();
  }
}

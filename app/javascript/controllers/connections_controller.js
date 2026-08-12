import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * ConnectionsController — Lista + búsqueda de conexiones SAP (Tabulator) y
 * panel lateral de creación/edición.
 *
 * Endpoints nativos de Rails (ver CLAUDE.md §28):
 *   - GET   /api/connections?name=&sl_url=&page=&per_page=   (listado paginado)
 *   - GET   /api/connections/:id                             (cargar para editar)
 *   - POST  /api/connections                                 (crear)
 *   - PATCH /api/connections/:id                             (actualizar)
 *
 * El formulario solo maneja las tres columnas que existen en la tabla
 * `connections` (Name, SlUrl, SlType). Los parámetros de DI-API/ODBC que pedía
 * el .NET (ODBCType, ServerType, DBUser, DBPass, …) se eliminaron: este producto
 * llega a SAP únicamente por Service Layer (CLAUDE.md §29).
 *
 * Crear/editar ya NO navega a otra vista: abre un panel lateral derecho
 * (patrón de CLAUDE.md §8). Al guardar con éxito se cierra el panel y se
 * refresca la tabla, sin recargar la página.
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'inputName',
    'inputSlUrl',
    'btnCreate', 'btnCreateWrap',
    // Panel lateral
    'panel', 'panelBackdrop', 'panelTitle',
    'fName', 'fNameError',
    'fSlUrl', 'fSlUrlError',
    'fSlType',
    'submitBtn', 'submitIcon', 'submitLabel',
  ];

  static values = { ...TabulatorController.values };

  #permissions = [];
  #totalRecords = 0;        // total real del servidor (evita sobreestimación de Tabulator)
  #connectionId = 0;        // 0 = crear; >0 = editar
  #editMode = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  connect() {
    const perms = SStore.get('Permissions');
    this.#permissions = Array.isArray(perms) ? perms : [];

    // Botón "Nueva Conexión": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.#hasPerm('Configurations_Connections_Create')) {
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
      layout: 'fitColumns',
      movableRows: false,
      placeholder: 'No hay conexiones registradas',
      columnDefaults: { headerSort: false },

      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 15, 25],
      // paginationCounter custom — Tabulator calcula el total como last_page*pageSize, lo que
      // sobreestima cuando la última página no está llena. Usamos el total real del servidor.
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      ajaxURL: '/api/connections',
      ajaxRequestFunc: (url, config, params) => this.#fetchPage(url, params),

      columns: this.getColumns(),
    };
  }

  getColumns() {
    const canEdit = this.#hasPerm('Configurations_Connections_Update');

    const columns = [
      { title: 'ID', field: 'Id', width: 80 },
      { title: 'Nombre', field: 'Name', widthGrow: 2 },
      { title: 'Motor de base de datos', field: 'SlType', widthGrow: 1 },
      { title: 'URL del Service Layer', field: 'SlUrl', widthGrow: 3, tooltip: true },
    ];

    // Columna Acciones siempre presente; el botón editar se deshabilita con
    // tooltip cuando falta el permiso (ver CLAUDE.md §26).
    columns.push({
      title: 'Acciones', field: 'Id', width: 100, hozAlign: 'center', headerSort: false,
      formatter: (cell) => this.#editButton(cell.getValue(), canEdit),
      cellClick: (e, cell) => {
        if (e.target.closest('[data-action-type="edit"]')) {
          this.#onEditClick(cell.getRow().getData());
        }
      },
    });

    return columns;
  }

  /**
   * Función de carga remota para Tabulator.
   * El endpoint nativo pagina por query string (página 1-indexed) y devuelve el
   * total real en el cuerpo (`Data.Total`), no en un header.
   * @param {string} url     ajaxURL configurada
   * @param {Object} params  { page (1-indexed), size, ... }
   * @returns {Promise<{data: Array, last_page: number}>}
   */
  async #fetchPage(url, params) {
    const size = params.size || 10;

    const qp = new URLSearchParams({
      name:     this.inputNameTarget.value.trim(),
      sl_url:   this.inputSlUrlTarget.value.trim(),
      page:     String(params.page || 1),
      per_page: String(size),
    });

    try {
      const { json } = await this.#apiFetch(`${url}?${qp}`);

      if (!json.Data) {
        showToast(json.Message || 'Error al obtener las conexiones', 'error');
        return { data: [], last_page: 1 };
      }

      const total = json.Data.Total ?? 0;
      this.#totalRecords = total;
      const lastPage = Math.max(1, Math.ceil(total / size));
      return { data: json.Data.Items ?? [], last_page: lastPage };
    } catch (err) {
      showToast(err.message || 'Error al obtener las conexiones', 'error');
      return { data: [], last_page: 1 };
    }
  }

  // ── Acciones públicas — lista ────────────────────────────────────────────────

  search() {
    this.table.setData();   // recarga vía ajax y vuelve a la página 1
  }

  // ── Panel lateral — crear / editar ───────────────────────────────────────────

  /** Abre el panel en modo creación. */
  openCreatePanel() {
    if (!this.#hasPerm('Configurations_Connections_Create')) {
      showToast('No cuenta con permisos para realizar esta acción.', 'info');
      return;
    }

    this.#editMode     = false;
    this.#connectionId = 0;

    this.#resetPanel();
    this.panelTitleTarget.textContent  = 'Nueva Conexión SAP';
    this.submitIconTarget.textContent  = 'check';
    this.submitLabelTarget.textContent = 'Crear conexión';

    this.#openPanel();
  }

  /** Abre el panel en modo edición y carga los datos de la conexión. */
  async #onEditClick(conn) {
    if (!this.#hasPerm('Configurations_Connections_Update')) {
      showToast('No cuenta con permisos para realizar esta acción.', 'info');
      return;
    }

    this.#editMode     = true;
    this.#connectionId = conn.Id;

    this.#resetPanel();
    this.panelTitleTarget.textContent  = 'Editar Conexión SAP';
    this.submitIconTarget.textContent  = 'autorenew';
    this.submitLabelTarget.textContent = 'Actualizar';

    this.#openPanel();

    // Se recarga desde el servidor en vez de usar la fila: la lista pudo quedar
    // vieja si otra persona editó la conexión mientras la tabla estaba abierta.
    try {
      const { json } = await this.#apiFetch(`/api/connections/${this.#connectionId}`);
      if (!json.Data) {
        showToast(json.Message || 'No se encontró la conexión', 'error');
        this.closePanel();
        return;
      }
      this.#fillPanel(json.Data);
    } catch (err) {
      showToast(err.message || 'Error al cargar la conexión', 'error');
      this.closePanel();
    }
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  /** Habilita el botón de guardar solo cuando todos los campos requeridos están completos. */
  refreshSubmitState() {
    this.submitBtnTarget.disabled = !this.#isFormValid();
  }

  /** ¿Están completos todos los campos obligatorios del panel? */
  #isFormValid() {
    // El motor (SlType) es opcional: la tabla lo acepta nulo.
    return this.fNameTarget.value.trim() !== '' && this.#isSlUrlValid();
  }

  /** La URL tiene que ser http(s), igual que valida el modelo del servidor. */
  #isSlUrlValid() {
    return /^https?:\/\//i.test(this.fSlUrlTarget.value.trim());
  }

  async savePanel() {
    if (!this.#validatePanel()) return;

    const payload  = this.#buildPayload();
    const isCreate = !this.#editMode;

    this.submitBtnTarget.disabled = true;
    try {
      // Crear va a la colección; actualizar, al recurso: el id viaja en el path,
      // no en el cuerpo como pedía el .NET (CLAUDE.md §28).
      const { json } = await this.#apiFetch(
        isCreate ? '/api/connections' : `/api/connections/${this.#connectionId}`,
        {
          method: isCreate ? 'POST' : 'PATCH',
          body:   JSON.stringify(payload),
        },
      );

      if (!json.Data) {
        const action = isCreate ? 'crear' : 'actualizar';
        showAlert({ type: ALERT_TYPES.ERROR, title: `Error al ${action} conexión`, message: json.Message || 'Error desconocido' });
        return;
      }

      showToast(isCreate ? 'Conexión creada con éxito' : 'Conexión actualizada con éxito', 'success');
      this.closePanel();
      this.table.setData();   // refresca la lista sin recargar la página
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error', message: err.message });
    } finally {
      this.submitBtnTarget.disabled = false;
    }
  }

  // ── Panel — helpers ──────────────────────────────────────────────────────────

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  #resetPanel() {
    this.fNameTarget.value  = '';
    this.fSlUrlTarget.value = '';
    this.fSlTypeTarget.value = '';
    this.refreshSubmitState();

    [this.fNameErrorTarget, this.fSlUrlErrorTarget].forEach(e => e.classList.add('hidden'));
  }

  #fillPanel(conn) {
    this.fNameTarget.value  = conn.Name  ?? '';
    this.fSlUrlTarget.value = conn.SlUrl ?? '';
    this.#applySelectValue(this.fSlTypeTarget, conn.SlType ?? '');
    this.refreshSubmitState();
  }

  /**
   * Asigna un valor a un <select>; si el valor no corresponde a ninguna opción
   * (p. ej. una conexión importada con un motor fuera del catálogo actual),
   * agrega una opción temporal para no perder el dato al editar.
   */
  #applySelectValue(select, value) {
    if (value && ![...select.options].some(o => o.value === value)) {
      const opt = document.createElement('option');
      opt.value = value;
      opt.textContent = value;
      select.appendChild(opt);
    }
    select.value = value;
  }

  #validatePanel() {
    const nameEmpty  = !this.fNameTarget.value.trim();
    const urlInvalid = !this.#isSlUrlValid();

    this.fNameErrorTarget.classList.toggle('hidden', !nameEmpty);
    this.fSlUrlErrorTarget.classList.toggle('hidden', !urlInvalid);

    if (nameEmpty || urlInvalid) {
      showToast('Por favor complete todos los campos requeridos', 'warning');
      return false;
    }
    return true;
  }

  // Solo las tres columnas que existen en la tabla. El Id ya no viaja en el
  // cuerpo: para actualizar va en el path (CLAUDE.md §28).
  #buildPayload() {
    return {
      Name:   this.fNameTarget.value.trim(),
      SlUrl:  this.fSlUrlTarget.value.trim(),
      SlType: this.fSlTypeTarget.value.trim(),
    };
  }

  // ── Render helpers ───────────────────────────────────────────────────────────

  // Botón editar: habilitado (azul) o deshabilitado (gris + tooltip envuelto en
  // <span>, porque un <button disabled> no emite eventos de mouse). Ver §26.
  #editButton(id, canEdit) {
    if (canEdit) {
      return `
        <button type="button" data-action-type="edit" data-testid="btn-edit-${id}" data-tooltip="Editar"
                class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
          <span class="material-icons text-base">edit</span>
        </button>`;
    }
    return `
      <span data-tooltip="No cuenta con permisos para editar conexiones">
        <button type="button" data-testid="btn-edit-${id}" disabled
                class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
          <span class="material-icons text-base">edit</span>
        </button>
      </span>`;
  }

  // ── Utilidades ─────────────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Nueva Conexión" (nace deshabilitado/gris con tooltip de
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
   * Endpoints nativos: la sesión va en la cookie httpOnly, así que no se arma
   * ningún header Authorization — getApiHeaders() aporta lo único que hace falta.
   * El motivo del error lo trae el campo Message del contrato ApiResponse.
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

    return { json: await response.json(), headers: response.headers };
  }
}

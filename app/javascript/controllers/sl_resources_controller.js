import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * SlResourcesController — Mantenimiento de las consultas al Service Layer.
 *
 * Endpoints nativos de Rails (ver CLAUDE.md §28):
 *   - GET   /api/sl_resources?code=&resource=&is_standard=&page=&per_page=
 *   - GET   /api/sl_resources/:id      (cargar para editar)
 *   - PATCH /api/sl_resources/:id      (actualizar)
 *
 * No hay alta ni baja: el catálogo lo define `db/seeds.rb` y la pantalla solo
 * ajusta el recurso y la query de las consultas que la app ya sabe consumir.
 *
 * Los `query_params` se editan como lista clave/valor y se unifican en un solo
 * string al guardar: la columna guarda la query cruda que espera el Service
 * Layer, no una estructura.
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'inputCode', 'inputResource', 'inputIsStandard',
    // Panel lateral
    'panel', 'panelBackdrop',
    'fCode',
    'fResource', 'fResourceError',
    'paramsList', 'paramsEmpty', 'paramsPreview',
    'submitBtn',
  ];

  static values = { ...TabulatorController.values };

  #permissions = [];
  #totalRecords = 0;    // total real del servidor (evita la sobreestimación de Tabulator)
  #resourceId = 0;      // id de la consulta en edición

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  connect() {
    const perms = SStore.get('Permissions');
    this.#permissions = Array.isArray(perms) ? perms : [];

    super.connect();   // construye la tabla y dispara la carga de la página 1
  }

  // ── Configuración Tabulator (paginación remota) ─────────────────────────────

  getTableConfig() {
    return {
      height: '100%',
      layout: 'fitColumns',
      movableRows: false,
      placeholder: 'No hay consultas registradas',
      columnDefaults: { headerSort: false },

      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 15, 25],
      // Contador con el total real del servidor: Tabulator lo calcula como
      // last_page * pageSize y sobreestima cuando la última página no está
      // llena (CLAUDE.md §17).
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      ajaxURL: '/api/sl_resources',
      ajaxRequestFunc: (url, config, params) => this.#fetchPage(url, params),

      columns: this.getColumns(),
    };
  }

  getColumns() {
    const canEdit = this.#hasPerm('Configurations_SlResources_Update');

    return [
      { title: 'Código', field: 'Code', widthGrow: 1 },
      {
        title: 'Recurso', field: 'Resource', widthGrow: 2, tooltip: true,
        formatter: (cell) => this.#truncated(cell.getValue()),
      },
      {
        // `truncate` recorta con "..." dentro de la celda: la query es larga y
        // sin esto se sale del contenedor. El valor completo va en el tooltip.
        title: 'Parámetros', field: 'QueryParams', widthGrow: 2, tooltip: true,
        formatter: (cell) => this.#truncated(cell.getValue()),
      },
      {
        title: 'Tipo', field: 'IsStandard', width: 140, hozAlign: 'center',
        formatter: (cell) => this.#standardBadge(cell.getValue()),
      },
      {
        title: 'Última actualización', field: 'UpdatedAt', width: 170,
        formatter: (cell) => this.#formatDateTime(cell.getValue()),
      },
      {
        title: 'Actualizado por', field: 'UpdatedBy', widthGrow: 1, tooltip: true,
        // Vacío mientras nadie la haya editado: `Auditable` solo llena
        // `updated_by` en un UPDATE.
        formatter: (cell) => this.#truncated(cell.getValue() || '—'),
      },
      {
        title: 'Acciones', field: 'Id', width: 90, hozAlign: 'center', headerSort: false,
        formatter: (cell) => this.#editButton(cell.getValue(), canEdit),
        cellClick: (e, cell) => {
          if (e.target.closest('[data-action-type="edit"]')) {
            this.#onEditClick(cell.getRow().getData());
          }
        },
      },
    ];
  }

  /**
   * Carga remota para Tabulator. El endpoint pagina por query string (página
   * 1-indexed) y devuelve el total real en `Data.Total`.
   */
  async #fetchPage(url, params) {
    const size = params.size || 10;

    const qp = new URLSearchParams({
      code:     this.inputCodeTarget.value.trim(),
      resource: this.inputResourceTarget.value.trim(),
      page:     String(params.page || 1),
      per_page: String(size),
    });
    // Vacío = "Todos": el parámetro no viaja, porque el servidor distingue
    // "sin filtro" de `false` ("solo los personalizados").
    const isStandard = this.inputIsStandardTarget.value;
    if (isStandard !== '') qp.set('is_standard', isStandard);

    try {
      const { json } = await this.#apiFetch(`${url}?${qp}`);

      if (!json.Data) {
        showToast(json.Message || 'Error al obtener las consultas', 'error');
        return { data: [], last_page: 1 };
      }

      const total = json.Data.Total ?? 0;
      this.#totalRecords = total;
      return { data: json.Data.Items ?? [], last_page: Math.max(1, Math.ceil(total / size)) };
    } catch (err) {
      showToast(err.message || 'Error al obtener las consultas', 'error');
      return { data: [], last_page: 1 };
    }
  }

  // ── Acciones públicas — lista ────────────────────────────────────────────────

  search() {
    this.table.setData();   // recarga vía ajax y vuelve a la página 1
  }

  // ── Panel lateral — edición ─────────────────────────────────────────────────

  async #onEditClick(row) {
    if (!this.#hasPerm('Configurations_SlResources_Update')) {
      showToast('No cuenta con permisos para realizar esta acción.', 'info');
      return;
    }

    this.#resourceId = row.Id;
    this.#resetPanel();
    this.#openPanel();

    // Se recarga desde el servidor en vez de usar la fila: la lista pudo quedar
    // vieja si otra persona editó la consulta mientras la tabla estaba abierta.
    try {
      const { json } = await this.#apiFetch(`/api/sl_resources/${this.#resourceId}`);
      if (!json.Data) {
        showToast(json.Message || 'No se encontró la consulta', 'error');
        this.closePanel();
        return;
      }
      this.#fillPanel(json.Data);
    } catch (err) {
      showToast(err.message || 'Error al cargar la consulta', 'error');
      this.closePanel();
    }
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  /** Agrega una fila vacía de parámetro y le deja el foco en la clave. */
  addParam() {
    const row = this.#buildParamRow('', '');
    this.paramsListTarget.appendChild(row);
    row.querySelector('[data-param="key"]').focus();
    this.refreshSubmitState();
  }

  /** Elimina la fila de parámetro sobre la que se hizo click. */
  removeParam(event) {
    event.currentTarget.closest('[data-param-row]')?.remove();
    this.refreshSubmitState();
  }

  /**
   * Habilita el botón de guardar y refresca la vista previa. Lo dispara el
   * `data-action` del panel en cada `input`/`change`, así que cubre tanto los
   * campos fijos como las filas de parámetros que se agregan en caliente.
   */
  refreshSubmitState() {
    const empty = this.paramsListTarget.children.length === 0;
    this.paramsEmptyTarget.classList.toggle('hidden', !empty);

    const query = this.#joinParams(this.#collectParams());
    this.paramsPreviewTarget.textContent = query || '(sin parámetros)';

    this.submitBtnTarget.disabled = this.fResourceTarget.value.trim() === '';
  }

  async savePanel() {
    if (!this.#validatePanel()) return;

    const payload = {
      Resource:    this.fResourceTarget.value.trim(),
      QueryParams: this.#joinParams(this.#collectParams()),
    };

    this.submitBtnTarget.disabled = true;
    try {
      const { json } = await this.#apiFetch(`/api/sl_resources/${this.#resourceId}`, {
        method: 'PATCH',
        body:   JSON.stringify(payload),
      });

      if (!json.Data) {
        showAlert({
          type: ALERT_TYPES.ERROR,
          title: 'Error al actualizar la consulta',
          message: json.Message || 'Error desconocido',
        });
        return;
      }

      showToast('Consulta actualizada con éxito', 'success');
      this.closePanel();
      this.table.setData();   // refresca la lista (la fila pasa a "Personalizado")
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error', message: err.message });
    } finally {
      this.submitBtnTarget.disabled = false;
    }
  }

  // ── Panel — helpers ─────────────────────────────────────────────────────────

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  #resetPanel() {
    this.fCodeTarget.value     = '';
    this.fResourceTarget.value = '';
    this.paramsListTarget.replaceChildren();
    this.fResourceErrorTarget.classList.add('hidden');
    this.refreshSubmitState();
  }

  #fillPanel(data) {
    this.fCodeTarget.value     = data.Code     ?? '';
    this.fResourceTarget.value = data.Resource ?? '';

    const rows = this.#splitParams(data.QueryParams).map(({ key, value }) => this.#buildParamRow(key, value));
    this.paramsListTarget.replaceChildren(...rows);

    this.refreshSubmitState();
  }

  #validatePanel() {
    const resourceEmpty = this.fResourceTarget.value.trim() === '';
    this.fResourceErrorTarget.classList.toggle('hidden', !resourceEmpty);

    if (resourceEmpty) {
      showToast('Por favor complete todos los campos requeridos', 'warning');
      return false;
    }
    return true;
  }

  // ── Query params — lista clave/valor ↔ string ────────────────────────────────

  /**
   * Parte la query cruda en pares clave/valor.
   * Separa por `&` y por el PRIMER `=` de cada par, así que un valor que
   * contenga `=` se conserva entero (`$filter=(A eq B)`). Un valor que contenga
   * `&` no se puede representar en la lista — ninguna consulta del catálogo lo
   * tiene, y el campo de recurso sigue permitiendo editarlo a mano.
   */
  #splitParams(raw) {
    if (!raw) return [];

    return raw.split('&')
      .filter(pair => pair.trim() !== '')
      .map((pair) => {
        const i = pair.indexOf('=');
        if (i === -1) return { key: pair.trim(), value: '' };
        return { key: pair.slice(0, i).trim(), value: pair.slice(i + 1).trim() };
      });
  }

  /** Lee las filas del DOM. El DOM es la fuente de verdad: no hay estado paralelo. */
  #collectParams() {
    return [...this.paramsListTarget.querySelectorAll('[data-param-row]')].map(row => ({
      key:   row.querySelector('[data-param="key"]').value.trim(),
      value: row.querySelector('[data-param="value"]').value.trim(),
    }));
  }

  /**
   * Unifica los pares en el string que se guarda en `query_params`.
   * Las filas sin clave se descartan (una fila recién agregada y vacía no debe
   * ensuciar la query). SIN url-encoding: la columna guarda la query cruda que
   * espera el Service Layer, con sus espacios y paréntesis.
   *
   * Verificado contra las 32 consultas del catálogo: `split` + `join` devuelve
   * el string original tal cual, así que abrir el panel y guardar sin tocar nada
   * no altera el dato. Única asimetría posible: una clave escrita sin `=` se
   * guarda con él (`$count` → `$count=`); OData no usa parámetros sin valor y
   * ninguna fila del catálogo tiene esa forma.
   */
  #joinParams(pairs) {
    return pairs
      .filter(p => p.key !== '')
      .map(p => `${p.key}=${p.value}`)
      .join('&');
  }

  /** Fila clave/valor + botón de eliminar. */
  #buildParamRow(key, value) {
    const row = document.createElement('div');
    row.dataset.paramRow = '';
    row.className = 'flex items-start gap-2';
    row.innerHTML = `
      <input type="text" data-param="key" value="${this.#escape(key)}" placeholder="$filter"
             class="w-1/3 border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono
                    focus:outline-none focus:ring-2 focus:ring-blue-500">
      <input type="text" data-param="value" value="${this.#escape(value)}" placeholder="(CardCode eq @CardCode)"
             class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono
                    focus:outline-none focus:ring-2 focus:ring-blue-500">
      <button type="button" data-action="click->sl-resources#removeParam"
              data-tooltip="Eliminar parámetro"
              class="p-2 text-red-600 rounded hover:bg-red-50 transition-colors flex-shrink-0">
        <span class="material-icons text-base">delete</span>
      </button>`;
    return row;
  }

  // ── Render helpers ──────────────────────────────────────────────────────────

  /** Celda de una línea con recorte "..." — el valor completo va en el tooltip. */
  #truncated(value) {
    return `<span class="block truncate">${this.#escape(value ?? '')}</span>`;
  }

  // Badge de §1: azul informativo para lo que trae el producto, violeta
  // (el tono de "borrador") para lo que el cliente modificó.
  #standardBadge(isStandard) {
    const { bg, color, label } = isStandard
      ? { bg: '#e8f0fe', color: '#1a56db', label: 'Estándar' }
      : { bg: '#f5f3ff', color: '#6d28d9', label: 'Personalizado' };

    return `<span style="background-color:${bg}; color:${color};"
                  class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${label}
    </span>`;
  }

  // Botón editar: habilitado (azul) o deshabilitado (gris + tooltip en el <span>
  // envolvente, porque un <button disabled> no emite eventos de mouse). Ver §26.
  #editButton(id, canEdit) {
    if (canEdit) {
      return `
        <button type="button" data-action-type="edit" data-testid="btn-edit-${id}" data-tooltip="Editar"
                class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
          <span class="material-icons text-base">edit</span>
        </button>`;
    }
    return `
      <span data-tooltip="No cuenta con permisos para editar consultas de Service Layer">
        <button type="button" data-testid="btn-edit-${id}" disabled
                class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
          <span class="material-icons text-base">edit</span>
        </button>
      </span>`;
  }

  // ── Utilidades ──────────────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Formato único de fecha de la app: yyyy-MM-dd HH:mm:ss (CLAUDE.md §5).
  #formatDateTime(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
           `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  // Los valores se interpolan en HTML (formatters de Tabulator y filas del
  // panel), así que se escapan: la query es texto editable por el usuario.
  #escape(text) {
    return String(text)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  }

  /**
   * Endpoints nativos: la sesión va en la cookie httpOnly, así que no se arma
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

    return { json: await response.json(), headers: response.headers };
  }
}

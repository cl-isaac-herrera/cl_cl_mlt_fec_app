import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { TabulatorFull } from 'tabulator-tables';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';
import { docTypeDescription } from 'controllers/create_document_constants';

/**
 * NumberingController — Configuración de Numeración y Numeración de Recepción.
 *
 * Replica Angular NumberingConfigComponent (dos sub-secciones):
 *
 * SECCIÓN 1 — Numeración (NumberingComponent):
 *   - GET /api/Numbering?companyId={id}
 *   - GET /api/Sucursal/GetSucursalByCompany?companyId={id}
 *   - GET /api/Numbering/GetReceptNumberingByCompany?companyId={id}
 *   - Tabla: Tipo de Integración, Tipo de Documento, Número Siguiente, Observación, Sucursal, Terminal, Activo
 *   - Crear / Editar (DocType + SucursalId + Terminal deshabilitados en edición)
 *   - POST /api/Numbering/ | PATCH /api/Numbering/
 *
 * SECCIÓN 2 — Numeración de Recepción (ReceptionNumberingComponent):
 *   - Tabla: Tipo de Integración, Número Siguiente, Sucursal, Terminal, Observación, Activo
 *   - Crear (NextNumber deshabilitado) / Editar (SucursalId + Terminal deshabilitados)
 *   - POST /api/Numbering/PostReceptNumbering/ | PATCH /api/Numbering/PatchReceptNumbering/
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,

    // Tabs
    'tabNumbering', 'tabReception',
    'numberingPanelTab', 'receptionPanelTab',

    // Tablas
    'numberingTable', 'receptionTable',

    // Botones de creación (habilitación según permisos)
    'btnCreateNumbering', 'btnCreateNumberingWrap',
    'btnCreateReception', 'btnCreateReceptionWrap',

    // Filtros
    'numFilterDocType', 'numFilterSucursal', 'numFilterTerminal', 'numFilterEstado',
    'recFilterSucursal', 'recFilterTerminal', 'recFilterEstado',

    // Loaders por tab/tabla
    'numberingLoader', 'receptionLoader',

    // Panel Numeración
    'numberingPanel', 'numberingPanelBackdrop', 'numberingPanelTitle',
    'numNextNumber', 'numNextNumberError',
    'numDocType',    'numDocTypeError',
    'numSucursal',   'numSucursalError',
    'numTerminal',   'numTerminalError',
    'numObvs',       'numObvsError',
    'numIntegration','numIntegrationError',
    'numActive',     'numActiveLabel',
    'numSaveBtn',    'numSaveIcon', 'numSaveLabel',

    // Panel Recepción
    'receptionPanel', 'receptionPanelBackdrop', 'receptionPanelTitle',
    'recNextNumber', 'recNextNumberError',
    'recSucursal',   'recSucursalError',
    'recTerminal',   'recTerminalError',
    'recObvs',       'recObvsError',
    'recIntegration','recIntegrationError',
    'recActive',     'recActiveLabel',
    'recSaveBtn',    'recSaveIcon', 'recSaveLabel',

  ];

  static values = { ...TabulatorController.values };

  // ── Estado ────────────────────────────────────────────────────────────────

  #companyId    = null;
  #sucursalList = [];
  #numTable     = null;
  #recTable     = null;
  #editingNum   = null;   // null = crear, objeto = editar
  #editingRec   = null;
  #permissions  = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company   = SStore.get('CurrentCompany');
    this.#companyId = company?.companyId ? parseInt(company.companyId) : null;

    const perms = SStore.get('Permissions');
    this.#permissions = Array.isArray(perms) ? perms : [];

    // Botones de creación: deshabilitados por defecto (con tooltip explicativo);
    // se habilitan solo cuando el usuario tiene el permiso correspondiente.
    if (this.#hasPerm('Configurations_Numbering_Create')) {
      this.#enableCreateButton(this.btnCreateNumberingTarget, this.btnCreateNumberingWrapTarget);
    }
    if (this.#hasPerm('Configurations_Numbering_CreateReception')) {
      this.#enableCreateButton(this.btnCreateReceptionTarget, this.btnCreateReceptionWrapTarget);
    }

    this.#setupTooltips();

    this.#numTable = this.#buildTable(this.numberingTableTarget, this.#numColumns());
    this.#recTable = this.#buildTable(this.receptionTableTarget, this.#recColumns());

    this.#loadInitialData();
  }

  disconnect() {
    this.#numTable?.destroy();
    this.#recTable?.destroy();
  }

  // ── Construcción de tablas (síncronas) ────────────────────────────────────

  #buildTable(el, columns) {
    return new TabulatorFull(el, {
      height:    '100%',   // ocupa el contenedor (h-full + flex-1 min-h-0 en el padre)
      layout:    'fitColumns',
      pagination: true,
      paginationSize: 10,
      paginationSizeSelector: [10, 20, 50],
      paginationCounter: 'rows',
      locale:    TABULATOR_LOCALE,
      langs:     TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      placeholder: 'No hay registros',
      columnDefaults: { headerSort: false },
      columns,
    });
  }

  #numColumns() {
    const columns = [
      { title: 'Tipo de Integración', field: 'IntegrationClm', widthGrow: 1 },
      {
        title: 'Tipo de Documento', field: 'DocType', widthGrow: 1,
        formatter: (cell) => docTypeDescription(cell.getValue()),
      },
      { title: 'Número Siguiente',    field: 'NextNumber',     widthGrow: 1 },
      { title: 'Observación',         field: 'Obvs',           widthGrow: 2 },
      { title: 'Sucursal',            field: 'SucursalNum',    widthGrow: 1 },
      { title: 'Terminal',            field: 'Terminal',       widthGrow: 1 },
      {
        title: 'Estado', field: 'Active', width: 110,
        formatter: (cell) => this.#statusBadge(cell.getValue()),
      },
    ];

    const canEdit = this.#hasPerm('Configurations_Numbering_Update');
    columns.push({
      title: 'Acciones', field: 'Id', width: 100, hozAlign: 'center',
      formatter: () => this.#editButton(canEdit, 'No cuenta con permisos para editar numeraciones de emisión'),
      cellClick: (_e, cell) => {
        if (_e.target.closest('[data-action-type="edit"]')) {
          this.#openEditNum(cell.getRow().getData());
        }
      },
    });

    return columns;
  }

  #recColumns() {
    const columns = [
      { title: 'Tipo de Integración', field: 'IntegrationClm', widthGrow: 1 },
      { title: 'Número Siguiente',    field: 'NextNumber',     widthGrow: 1 },
      { title: 'Sucursal',            field: 'SucursalNum',    widthGrow: 1 },
      { title: 'Terminal',            field: 'Terminal',       widthGrow: 1 },
      { title: 'Observación',         field: 'Obvs',           widthGrow: 2 },
      {
        title: 'Estado', field: 'Active', width: 110,
        formatter: (cell) => this.#statusBadge(cell.getValue()),
      },
    ];

    const canEdit = this.#hasPerm('Configurations_Numbering_UpdateReception');
    columns.push({
      title: 'Acciones', field: 'Id', width: 100, hozAlign: 'center',
      formatter: () => this.#editButton(canEdit, 'No cuenta con permisos para editar numeraciones de recepción'),
      cellClick: (_e, cell) => {
        if (_e.target.closest('[data-action-type="edit"]')) {
          this.#openEditRec(cell.getRow().getData());
        }
      },
    });

    return columns;
  }

  // ── Carga de datos ─────────────────────────────────────────────────────────

  #showLoader(el) { el?.classList.remove('hidden'); }
  #hideLoader(el) { el?.classList.add('hidden'); }

  async #loadInitialData() {
    // Fase 1 — sucursales: prerequisito de ambas tablas (resuelve la etiqueta
    // de sucursal y los selects de los paneles). Loader visible en ambos tabs.
    this.#showLoader(this.numberingLoaderTarget);
    this.#showLoader(this.receptionLoaderTarget);
    try {
      const sucRes = await this.#apiFetch(`/api/Sucursal/GetSucursalByCompany?companyId=${this.#companyId}`);
      this.#sucursalList = sucRes.Data || [];
      this.#populateSucursalSelects();
    } catch (err) {
      this.#hideLoader(this.numberingLoaderTarget);
      this.#hideLoader(this.receptionLoaderTarget);
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al cargar las sucursales.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    // Fase 2 — numeraciones independientes: cada tab oculta su propio loader
    // en cuanto termina su consulta, sin esperar a la otra.
    this.#reloadNum();
    this.#reloadRec();
  }

  async #reloadNum() {
    const loader = this.hasNumberingLoaderTarget ? this.numberingLoaderTarget : null;
    this.#showLoader(loader);
    try {
      const numRes = await this.#apiFetch(`/api/Numbering?companyId=${this.#companyId}`);
      this.#numTable?.setData((numRes.Data || []).map(x => this.#mapNum(x)));
      if (!numRes.Data?.length && numRes.Message) Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: numRes.Message,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al recargar numeración.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } finally {
      this.#hideLoader(loader);
    }
  }

  async #reloadRec() {
    const loader = this.hasReceptionLoaderTarget ? this.receptionLoaderTarget : null;
    this.#showLoader(loader);
    try {
      const res = await this.#apiFetch(`/api/Numbering/GetReceptNumberingByCompany?companyId=${this.#companyId}`);
      this.#recTable?.setData((res.Data || []).map(x => this.#mapRec(x)));
      if (!res.Data?.length && res.Message) Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: res.Message,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al recargar numeración de recepción.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } finally {
      this.#hideLoader(loader);
    }
  }

  // ── Mapeo de filas ─────────────────────────────────────────────────────────

  #mapNum(x) {
    return {
      ...x,
      IntegrationClm: x.Integration === 1 ? 'Integrador' : 'AppFE',
      SucursalNum: this.#sucursalLabel(x.SucursalId),
    };
  }

  #mapRec(x) {
    return {
      ...x,
      IntegrationClm: x.Integration === 1 ? 'Integrador' : 'AppFE',
      SucursalNum: this.#sucursalLabel(x.SucursalId),
    };
  }

  // Etiqueta de sucursal para tablas: "<código> - <descripción>"
  #sucursalLabel(sucursalId) {
    const s = this.#sucursalList.find(s => s.Id === sucursalId);
    if (!s) return sucursalId;
    return s.Alias ? `${s.SucursalNum} - ${s.Alias}` : `${s.SucursalNum}`;
  }

  // ── Selects de sucursal ────────────────────────────────────────────────────

  #populateSucursalSelects() {
    const opts = this.#sucursalList
      .map(s => `<option value="${s.Id}">${s.SucursalNum}${s.Alias ? ' - ' + s.Alias : ''}</option>`)
      .join('');

    // Selects de los paneles (crear/editar) — placeholder "-- Seleccione --"
    [this.numSucursalTarget, this.recSucursalTarget].forEach(sel => {
      const prev = sel.value;
      sel.innerHTML = `<option value="">-- Seleccione --</option>${opts}`;
      if (prev) sel.value = prev;
    });

    // Selects de los filtros — placeholder "Todas"
    [this.numFilterSucursalTarget, this.recFilterSucursalTarget].forEach(sel => {
      const prev = sel.value;
      sel.innerHTML = `<option value="">Todas</option>${opts}`;
      if (prev) sel.value = prev;
    });
  }

  // ── Tabs ────────────────────────────────────────────────────────────────

  switchTab(event) {
    const tab = event.currentTarget.dataset.tab;

    const activeClass   = ['border-blue-600', 'text-blue-600', 'bg-white'];
    const inactiveClass = ['border-transparent', 'text-gray-500'];

    [this.tabNumberingTarget, this.tabReceptionTarget].forEach(btn => {
      btn.classList.remove(...activeClass, ...inactiveClass);
      btn.classList.add(...inactiveClass);
    });
    event.currentTarget.classList.remove(...inactiveClass);
    event.currentTarget.classList.add(...activeClass);

    if (tab === 'numbering') {
      this.numberingPanelTabTarget.classList.remove('hidden');
      this.receptionPanelTabTarget.classList.add('hidden');
      requestAnimationFrame(() => this.#numTable?.redraw(true));
    } else {
      this.numberingPanelTabTarget.classList.add('hidden');
      this.receptionPanelTabTarget.classList.remove('hidden');
      // Tabulator no puede calcular altura dentro de un elemento hidden;
      // forzamos redibujado al mostrar el panel
      requestAnimationFrame(() => this.#recTable?.redraw(true));
    }
  }

  // ── Filtros (cliente, sobre los datos ya cargados) ──────────────────────────

  filterNumbering() {
    const docType = this.numFilterDocTypeTarget.value;
    const sucId   = this.numFilterSucursalTarget.value;
    const term    = this.numFilterTerminalTarget.value.trim();
    const estado  = this.numFilterEstadoTarget.value;

    this.#numTable?.setFilter((row) => {
      if (docType && row.DocType !== docType) return false;
      if (sucId && String(row.SucursalId) !== String(sucId)) return false;
      if (term && !String(row.Terminal ?? '').includes(term)) return false;
      if (estado !== '' && (row.Active ? '1' : '0') !== estado) return false;
      return true;
    });
  }

  filterReception() {
    const sucId  = this.recFilterSucursalTarget.value;
    const term   = this.recFilterTerminalTarget.value.trim();
    const estado = this.recFilterEstadoTarget.value;

    this.#recTable?.setFilter((row) => {
      if (sucId && String(row.SucursalId) !== String(sucId)) return false;
      if (term && !String(row.Terminal ?? '').includes(term)) return false;
      if (estado !== '' && (row.Active ? '1' : '0') !== estado) return false;
      return true;
    });
  }

  // ── Panel Numeración ───────────────────────────────────────────────────────

  openCreateNumbering() {
    if (!this.#hasPerm('Configurations_Numbering_Create')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para realizar esta acción.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingNum = null;
    this.#resetNumPanel();
    this.numberingPanelTitleTarget.textContent = 'Nueva Numeración';
    this.numSaveIconTarget.textContent         = 'check';
    this.numSaveLabelTarget.textContent        = 'Crear';

    // Todos los campos habilitados al crear
    this.numNextNumberTarget.disabled = false;
    this.numDocTypeTarget.disabled    = false;
    this.numSucursalTarget.disabled   = false;
    this.numTerminalTarget.disabled   = false;

    this.#openPanel(this.numberingPanelTarget, this.numberingPanelBackdropTarget);
  }

  #openEditNum(row) {
    if (!this.#hasPerm('Configurations_Numbering_Update')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para realizar esta acción.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingNum = row;
    this.#resetNumPanel();
    this.numberingPanelTitleTarget.textContent = 'Editar Numeración';
    this.numSaveIconTarget.textContent         = 'autorenew';
    this.numSaveLabelTarget.textContent        = 'Modificar';

    // DocType, SucursalId y Terminal deshabilitados al editar
    this.numNextNumberTarget.disabled = false;
    this.numDocTypeTarget.disabled    = true;
    this.numSucursalTarget.disabled   = true;
    this.numTerminalTarget.disabled   = true;

    this.numNextNumberTarget.value   = row.NextNumber;
    this.numDocTypeTarget.value      = row.DocType;
    this.numSucursalTarget.value     = row.SucursalId;
    this.numTerminalTarget.value     = row.Terminal;
    this.numObvsTarget.value         = row.Obvs;
    this.numIntegrationTarget.value  = row.Integration;
    this.numActiveTarget.checked     = row.Active;
    this.numActiveLabelTarget.textContent = row.Active ? 'Activo' : 'Inactivo';

    this.#openPanel(this.numberingPanelTarget, this.numberingPanelBackdropTarget);
  }

  closeNumberingPanel() {
    this.#closePanel(this.numberingPanelTarget, this.numberingPanelBackdropTarget);
  }

  async saveNumbering() {
    if (!this.#validateNumPanel()) return;

    this.numSaveBtnTarget.disabled = true;
    try {
      if (this.#editingNum) {
        const patch = {
          id:          this.#editingNum.Id,
          companyId:   this.#companyId,
          nextNumber:  parseInt(this.numNextNumberTarget.value),
          sucursalId:  parseInt(this.numSucursalTarget.value),
          terminal:    parseInt(this.numTerminalTarget.value),
          docType:     this.numDocTypeTarget.value,
          obvs:        this.numObvsTarget.value.trim(),
          active:      this.numActiveTarget.checked,
          integration: parseInt(this.numIntegrationTarget.value),
        };
        await this.#apiFetch('/api/Numbering/', { method: 'PATCH', body: JSON.stringify(patch) });
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Numeración actualizada exitosamente.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      } else {
        const post = {
          Id:          0,
          CompanyId:   this.#companyId,
          NextNumber:  parseInt(this.numNextNumberTarget.value),
          DocType:     this.numDocTypeTarget.value,
          SucursalId:  parseInt(this.numSucursalTarget.value),
          Terminal:    parseInt(this.numTerminalTarget.value),
          Obvs:        this.numObvsTarget.value.trim(),
          Active:      this.numActiveTarget.checked,
          Integration: parseInt(this.numIntegrationTarget.value),
        };
        await this.#apiFetch('/api/Numbering/', { method: 'POST', body: JSON.stringify(post) });
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Numeración registrada exitosamente.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      }
      this.closeNumberingPanel();
      await this.#reloadNum();
    } catch (err) {
      Swal.fire({
        icon: 'error',
        title: `Error al ${this.#editingNum ? 'actualizar' : 'registrar'} la numeración`,
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
    } finally {
      this.numSaveBtnTarget.disabled = false;
    }
  }

  #validateNumPanel() {
    const checks = [
      { el: this.numNextNumberTarget,  err: this.numNextNumberErrorTarget,  ok: v => v !== '' && parseInt(v) >= 1 },
      { el: this.numDocTypeTarget,     err: this.numDocTypeErrorTarget,     ok: v => v !== '' },
      { el: this.numSucursalTarget,    err: this.numSucursalErrorTarget,    ok: v => v !== '' },
      { el: this.numTerminalTarget,    err: this.numTerminalErrorTarget,    ok: v => v !== '' && parseInt(v) >= 0 },
      { el: this.numObvsTarget,        err: this.numObvsErrorTarget,        ok: v => v.trim() !== '' },
      { el: this.numIntegrationTarget, err: this.numIntegrationErrorTarget, ok: v => v !== '' },
    ];
    let valid = true;
    for (const { el, err, ok } of checks) {
      if (el.disabled) { err.classList.add('hidden'); continue; }
      const pass = ok(el.value);
      err.classList.toggle('hidden', pass);
      if (!pass) valid = false;
    }
    return valid;
  }

  #resetNumPanel() {
    this.numNextNumberTarget.value  = 1;
    this.numDocTypeTarget.value     = '';
    this.numSucursalTarget.value    = '';
    this.numTerminalTarget.value    = '';
    this.numObvsTarget.value        = '';
    this.numIntegrationTarget.value = '';
    this.numActiveTarget.checked    = true;
    this.numActiveLabelTarget.textContent = 'Activo';
    [
      this.numNextNumberErrorTarget, this.numDocTypeErrorTarget,
      this.numSucursalErrorTarget,   this.numTerminalErrorTarget,
      this.numObvsErrorTarget,       this.numIntegrationErrorTarget,
    ].forEach(e => e.classList.add('hidden'));
  }

  // ── Panel Recepción ────────────────────────────────────────────────────────

  openCreateReception() {
    if (!this.#hasPerm('Configurations_Numbering_CreateReception')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para realizar esta acción.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingRec = null;
    this.#resetRecPanel();
    this.receptionPanelTitleTarget.textContent = 'Nueva Numeración de Recepción';
    this.recSaveIconTarget.textContent         = 'check';
    this.recSaveLabelTarget.textContent        = 'Crear';

    // NextNumber deshabilitado al crear; Sucursal y Terminal habilitados
    this.recNextNumberTarget.disabled = true;
    this.recSucursalTarget.disabled   = false;
    this.recTerminalTarget.disabled   = false;

    this.#openPanel(this.receptionPanelTarget, this.receptionPanelBackdropTarget);
  }

  #openEditRec(row) {
    if (!this.#hasPerm('Configurations_Numbering_UpdateReception')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para realizar esta acción.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingRec = row;
    this.#resetRecPanel();
    this.receptionPanelTitleTarget.textContent = 'Editar Numeración de Recepción';
    this.recSaveIconTarget.textContent         = 'autorenew';
    this.recSaveLabelTarget.textContent        = 'Modificar';

    // NextNumber habilitado; Sucursal y Terminal deshabilitados al editar
    this.recNextNumberTarget.disabled = false;
    this.recSucursalTarget.disabled   = true;
    this.recTerminalTarget.disabled   = true;

    this.recNextNumberTarget.value   = row.NextNumber;
    this.recSucursalTarget.value     = row.SucursalId;
    this.recTerminalTarget.value     = row.Terminal;
    this.recObvsTarget.value         = row.Obvs;
    this.recIntegrationTarget.value  = row.Integration;
    this.recActiveTarget.checked     = row.Active;
    this.recActiveLabelTarget.textContent = row.Active ? 'Activo' : 'Inactivo';

    this.#openPanel(this.receptionPanelTarget, this.receptionPanelBackdropTarget);
  }

  closeReceptionPanel() {
    this.#closePanel(this.receptionPanelTarget, this.receptionPanelBackdropTarget);
  }

  async saveReception() {
    if (!this.#validateRecPanel()) return;

    this.recSaveBtnTarget.disabled = true;
    try {
      const payload = {
        Id:          this.#editingRec ? this.#editingRec.Id : 0,
        CompanyId:   this.#companyId,
        NextNumber:  parseInt(this.recNextNumberTarget.value) || 0,
        SucursalId:  parseInt(this.recSucursalTarget.value),
        Terminal:    parseInt(this.recTerminalTarget.value),
        Message:     1,
        Obvs:        this.recObvsTarget.value.trim(),
        Integration: parseInt(this.recIntegrationTarget.value),
        Active:      this.recActiveTarget.checked,
      };

      if (this.#editingRec) {
        await this.#apiFetch('/api/Numbering/PatchReceptNumbering/', { method: 'PATCH', body: JSON.stringify(payload) });
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Numeración de Recepción actualizada exitosamente.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      } else {
        await this.#apiFetch('/api/Numbering/PostReceptNumbering/', { method: 'POST', body: JSON.stringify(payload) });
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Numeración de Recepción registrada exitosamente.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      }
      this.closeReceptionPanel();
      await this.#reloadRec();
    } catch (err) {
      Swal.fire({
        icon: 'error',
        title: `Error al ${this.#editingRec ? 'actualizar' : 'registrar'} la numeración de recepción`,
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
    } finally {
      this.recSaveBtnTarget.disabled = false;
    }
  }

  #validateRecPanel() {
    const checks = [
      { el: this.recNextNumberTarget,  err: this.recNextNumberErrorTarget,  ok: v => v !== '' && parseInt(v) >= 1 },
      { el: this.recSucursalTarget,    err: this.recSucursalErrorTarget,    ok: v => v !== '' },
      { el: this.recTerminalTarget,    err: this.recTerminalErrorTarget,    ok: v => v !== '' },
      { el: this.recObvsTarget,        err: this.recObvsErrorTarget,        ok: v => v.trim() !== '' },
      { el: this.recIntegrationTarget, err: this.recIntegrationErrorTarget, ok: v => v !== '' },
    ];
    let valid = true;
    for (const { el, err, ok } of checks) {
      if (el.disabled) { err.classList.add('hidden'); continue; }
      const pass = ok(el.value);
      err.classList.toggle('hidden', pass);
      if (!pass) valid = false;
    }
    return valid;
  }

  #resetRecPanel() {
    this.recNextNumberTarget.value  = 1;
    this.recSucursalTarget.value    = '';
    this.recTerminalTarget.value    = '';
    this.recObvsTarget.value        = '';
    this.recIntegrationTarget.value = '';
    this.recActiveTarget.checked    = true;
    this.recActiveLabelTarget.textContent = 'Activo';
    [
      this.recNextNumberErrorTarget, this.recSucursalErrorTarget,
      this.recTerminalErrorTarget,   this.recObvsErrorTarget,
      this.recIntegrationErrorTarget,
    ].forEach(e => e.classList.add('hidden'));
  }

  // ── Helpers de panel ──────────────────────────────────────────────────────

  #openPanel(panel, backdrop) {
    backdrop.classList.remove('hidden');
    panel.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  #closePanel(panel, backdrop) {
    panel.classList.add('translate-x-full');
    backdrop.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // ── Render helpers ────────────────────────────────────────────────────────

  #statusBadge(active) {
    return active
      ? `<span style="background-color:#e8f5ee; color:#3a7d52;"
               class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">Activo</span>`
      : `<span style="background-color:#fdecea; color:#c0392b;"
               class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">Inactivo</span>`;
  }

  // El tooltip vive en el <span> envolvente (no en el <button>): un botón
  // deshabilitado no emite eventos de mouse, así que el hover se detecta sobre
  // el span. `pointer-events-none` en el botón deshabilitado deja pasar el hover.
  #editButton(canEdit, disabledReason) {
    if (canEdit) {
      return `
        <span data-tooltip="Editar">
          <button type="button" data-action-type="edit"
                  class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
            <span class="material-icons text-base">edit</span>
          </button>
        </span>`;
    }
    return `
      <span data-tooltip="${disabledReason}">
        <button type="button" disabled
                class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
          <span class="material-icons text-base">edit</span>
        </button>
      </span>`;
  }

  // ── Permisos ────────────────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita un botón de creación que en el HTML nace deshabilitado (gris) con
  // un tooltip de "sin permisos" en su <span> envolvente.
  #enableCreateButton(btn, wrap) {
    btn.disabled = false;
    btn.classList.remove('bg-gray-300', 'text-gray-500', 'cursor-not-allowed', 'pointer-events-none');
    btn.classList.add('bg-blue-600', 'text-white', 'hover:bg-blue-700');
    wrap?.removeAttribute('data-tooltip');
  }

  // ── Tooltips ─────────────────────────────────────────────────────────────────
  // Delegación fija (position:fixed) sobre el elemento raíz del controller, para
  // cubrir tanto los botones del toolbar como los de las filas Tabulator. Este
  // controller construye sus tablas manualmente (no usa el setupTooltip base, que
  // apunta a un único tableTarget), por eso se instala aquí.

  #setupTooltips() {
    let tip = document.getElementById('cl-tabulator-tooltip');
    if (!tip) {
      tip = document.createElement('div');
      tip.id = 'cl-tabulator-tooltip';
      // max-width + wrapping: el tooltip NUNCA excede el ancho del viewport, así
      // que su contenido siempre queda completo (los textos largos envuelven).
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

    let activeEl = null;

    // Reposiciona el tooltip dentro del viewport: por defecto arriba del cursor;
    // hace flip horizontal/vertical y clamp contra los bordes para que nunca
    // quede cortado. (Ver CLAUDE.md §25 — estándar de tooltips flotantes.)
    const place = (e) => {
      const margin = 8;
      const { width: w, height: h } = tip.getBoundingClientRect();
      let left = e.clientX + 12;
      let top  = e.clientY - h - 10;               // arriba del cursor
      if (left + w + margin > window.innerWidth) left = e.clientX - w - 12;   // flip a la izquierda
      if (left < margin) left = margin;
      if (left + w + margin > window.innerWidth) left = window.innerWidth - w - margin;
      if (top < margin) top = e.clientY + 18;      // sin espacio arriba → abajo del cursor
      if (top + h + margin > window.innerHeight) top = window.innerHeight - h - margin;
      tip.style.left = left + 'px';
      tip.style.top  = top + 'px';
    };

    this.element.addEventListener('mouseover', (e) => {
      const el = e.target.closest('[data-tooltip]');
      if (el && el.dataset.tooltip && el !== activeEl) {
        activeEl = el;
        tip.textContent = el.dataset.tooltip;
        place(e);
        tip.style.opacity = '1';
      } else if (!el) {
        activeEl = null;
        tip.style.opacity = '0';
      }
    });

    this.element.addEventListener('mousemove', (e) => {
      if (!activeEl) return;
      place(e);
    });

    this.element.addEventListener('mouseleave', () => {
      activeEl = null;
      tip.style.opacity = '0';
    });
  }

  // ── apiFetch ───────────────────────────────────────────────────────────────

  async #apiFetch(url, options = {}) {
    const session = Storage.get('Session') || {};
    const token   = session.access_token;

    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(options.headers || {}),
      },
    });

    const clMessage      = response.headers.get('cl-message');
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage); } catch { return clMessage; }
    })() : null;

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText);
      throw new Error(decodedMessage || text || `HTTP ${response.status}`);
    }

    const contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('json')) return {};

    const text = await response.text();
    if (!text?.trim()) return {};
    const json = JSON.parse(text);
    if (decodedMessage && !json.Message) json.Message = decodedMessage;
    return json;
  }
}

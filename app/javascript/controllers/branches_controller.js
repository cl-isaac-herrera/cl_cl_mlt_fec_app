import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * BranchesController — Gestión de sucursales de la compañía activa (Tabulator).
 *
 * Endpoints NATIVOS de Rails (ver CLAUDE.md §28). Ya no se pasa por el proxy al
 * API .NET (`/api/Sucursal/...`):
 *   - GET   /api/branches?alias=&provincia=&canton=&distrito=&active=&page=&per_page=
 *   - GET   /api/branches/:code   (releer la sucursal antes de editarla)
 *   - POST  /api/branches         (crear)
 *   - PATCH /api/branches/:code   (actualizar)
 *
 * ── Tres cosas que cambiaron con la migración ──────────────────────────────
 *   1. **La sucursal vive en SAP**, en la UDT `@CL_FEC_SUCURSALES` de la
 *      compañía (ver `Sap::Branches`), no en la base del .NET. La llave es el
 *      `Code` que asigna SAP; `SucursalNum` es el número ante Hacienda y sigue
 *      siendo lo que se muestra.
 *   2. **`companyId` ya no viaja.** La compañía activa sale de la sesión del
 *      servidor y determina contra qué base de SAP se consulta.
 *   3. **El filtrado y la paginación los hace el servidor.** Antes se traían
 *      todas las sucursales y se filtraba en el browser; ahora las condiciones
 *      —el estado incluido— van al `$filter` de la consulta a SAP.
 *
 * ⚠️ Sin `Total` en la respuesta: el Service Layer no devuelve más de 20 filas
 * por respuesta sin un header que el submódulo todavía no soporta, así que no
 * hay forma honesta de contar el total (`TODOS.md` → SAP). Llega `HasMore` y de
 * ahí sale `last_page`; el contador muestra el rango, sin "de N filas"
 * (CLAUDE.md §17 asume un total conocible — acá NO lo hay, y es a propósito).
 *
 * JSON locales servidos desde /public (catálogo de ubicaciones de Costa Rica):
 *   /Provinces.json → { Provinces: [{ ProvinceId, ProvinceName }] }
 *   /Country.json   → { Country: [{ ProvinceId, CantonId, CantonName,
 *                                   DistrictId, DistrictName,
 *                                   NeighborhoodId, NeighborhoodName }] }
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,

    // Filtros
    'filterAlias', 'filterProvincia', 'filterCanton', 'filterDistrito', 'filterActive',

    // Toolbar
    'btnCreate', 'btnCreateWrap',

    // Panel lateral
    'panel', 'panelBackdrop', 'panelTitle',
    'saveBtn', 'saveIcon', 'saveLabel',

    // Campos del formulario
    'inputSucursalNum', 'errorSucursalNum', 'errorSucursalNumPattern',
    'selectProvincia',  'errorProvincia',
    'selectCanton',     'errorCanton',
    'selectDistrito',   'errorDistrito',
    'inputBarrio',      'errorBarrio', 'barrioDropdown',
    'inputOtrasSenas',  'errorOtrasSenas',
    'inputTelefono',    'errorTelefono',
    'inputFax',
    'inputEmail',       'errorEmail', 'errorEmailPattern',
    'inputAlias',       'errorAlias',
    'inputActive',

  ];

  static values = { ...TabulatorController.values };

  // ── Estado ────────────────────────────────────────────────────────────────

  #provinces     = [];       // [{ ProvinceId, ProvinceName }]
  #country       = [];       // array plano con todos los registros de Country.json
  #neighborhoodList = [];    // barrios del distrito seleccionado
  #editingBranch = null;     // null = crear, objeto = editar
  #provinceId    = '';
  #cantonId      = '';
  #permissions   = [];
  #lastPageRowCount = 0;     // filas de la página actual, para el contador

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  // `async` a propósito: el catálogo de ubicaciones tiene que estar cargado
  // ANTES de que Tabulator dispare su primer request, porque cada fila se
  // traduce a nombres (provincia/cantón/distrito) con esos JSON. Al revés, la
  // primera página mostraría los códigos crudos.
  async connect() {
    this.#permissions = SStore.get('Permissions') || [];

    // Botón "Nueva Sucursal": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.hasBtnCreateTarget) {
      if (this.#hasPerm('Configurations_Branches_Create')) {
        this.#enableCreateButton();
      } else if (this.hasBtnCreateWrapTarget) {
        this.#attachTooltip(this.btnCreateWrapTarget);
      }
    }

    await this.#loadLocations();

    super.connect();   // inicializa Tabulator y dispara la primera página
  }

  // ── Configuración Tabulator ────────────────────────────────────────────────

  getTableConfig() {
    const baseConfig = super.getTableConfig();
    delete baseConfig.data;   // sin data estática: la tabla arranca por AJAX

    return {
      ...baseConfig,
      height:    '100%',
      maxHeight: undefined,
      movableRows: false,
      layout: 'fitColumns',
      placeholder: 'No se encontraron sucursales para los filtros aplicados.',
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      // El tope del servidor es `Sap::Branches::MAX_PAGE_SIZE` (19), que deja
      // margen bajo el techo real de 20 filas por respuesta del Service Layer.
      paginationSizeSelector: [5, 10, 15],
      // Contador sin total (ver la cabecera del archivo): se muestra el rango
      // de la página actual.
      paginationCounter: (_pageSize, currentRow) => {
        if (!this.#lastPageRowCount) return '';
        const to = currentRow + this.#lastPageRowCount - 1;
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')}`;
      },
      ajaxURL: '/api/branches',   // requerido para activar el modo remote
      ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
      ajaxResponse:    (_url, _params, response) => response,
      locale: TABULATOR_LOCALE,
      langs:  TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      columns: this.getColumns(),
    };
  }

  // ── Columnas ──────────────────────────────────────────────────────────────

  getColumns() {
    return [
      { title: 'Sucursal',    field: 'SucursalNum',     width: 90  },
      { title: 'Alias',       field: 'Alias',           minWidth: 120 },
      { title: 'Provincia',   field: 'ProvinciaName',   minWidth: 110 },
      { title: 'Cantón',      field: 'CantonName',      minWidth: 110 },
      { title: 'Distrito',    field: 'DistritoName',    minWidth: 110 },
      { title: 'Barrio',      field: 'EmsrUbBarrio',    minWidth: 110 },
      { title: 'Otras señas', field: 'EmsrUbOtrasSenas',minWidth: 150 },
      {
        title: 'Estado',
        field: 'Active',
        width: 90,
        formatter: (cell) => this.#statusBadge(cell.getValue() ? 'active' : 'inactive'),
      },
      {
        title: 'Acciones',
        field: '_actions',
        width: 80,
        hozAlign: 'center',
        headerSort: false,
        // Editar sin permiso: deshabilitado + tooltip (CLAUDE.md §26). El
        // data-tooltip va en el <span> envolvente (un <button disabled> no emite
        // eventos de mouse); el setupTooltip base (tabla) lo detecta.
        formatter: () => this.#hasPerm('Configurations_Branches_Update')
          ? `<button type="button" data-action-type="edit" data-tooltip="Editar"
                     class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
               <span class="material-icons text-base">edit</span>
             </button>`
          : `<span data-tooltip="No cuenta con permisos para editar sucursales">
               <button type="button" disabled
                       class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
                 <span class="material-icons text-base">edit</span>
               </button>
             </span>`,
        cellClick: (_e, cell) => {
          const btn = _e.target.closest('[data-action-type]');
          if (btn?.dataset.actionType === 'edit') {
            this.#openEditPanel(cell.getRow().getData());
          }
        },
      },
    ];
  }

  // ── Carga de datos ─────────────────────────────────────────────────────────

  /** Catálogo de ubicaciones de Costa Rica (JSON estáticos de /public). */
  async #loadLocations() {
    try {
      const [countryRes, provincesRes] = await Promise.all([
        fetch('/Country.json').then(r => r.json()),
        fetch('/Provinces.json').then(r => r.json()),
      ]);
      this.#country   = countryRes.Country     || [];
      this.#provinces = provincesRes.Provinces || [];
      this.#populateProvinceSelect();
      this.#populateFilterProvinciaSelect();
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: 'Error al cargar datos de ubicación.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    }
  }

  /**
   * Una página de sucursales. La llama Tabulator en cada cambio de página o de
   * tamaño; los filtros se leen del formulario en ese momento, así que
   * `setData()` (ver `search`) alcanza para volver a buscar.
   */
  async #fetchPage(params) {
    const page = params.page || 1;
    const size = params.size || 10;

    const qp = new URLSearchParams({ page, per_page: size });
    const alias     = this.filterAliasTarget.value.trim();
    const provincia = this.filterProvinciaTarget.value;
    const canton    = this.filterCantonTarget.value;
    const distrito  = this.filterDistritoTarget.value;
    // '' = todas (activas e inactivas); 'true'/'false' acotan.
    const active    = this.hasFilterActiveTarget ? this.filterActiveTarget.value : '';

    if (alias)     qp.set('alias', alias);
    if (provincia) qp.set('provincia', provincia);
    if (canton)    qp.set('canton', canton);
    if (distrito)  qp.set('distrito', distrito);
    if (active)    qp.set('active', active);

    try {
      const json = await this.#apiFetch(`/api/branches?${qp}`);
      const items = (json.Data?.Items || []).map(b => this.#mapBranchNames(b));
      this.#lastPageRowCount = items.length;

      // Sin un total real, `last_page` es "esta página + 1" cuando el servidor
      // avisó que hay más — suficiente para que el botón "Siguiente" de
      // Tabulator se habilite o no.
      return { data: items, last_page: json.Data?.HasMore ? page + 1 : page };
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al cargar las sucursales.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.#lastPageRowCount = 0;
      return { data: [], last_page: 1 };
    }
  }

  /** Agrega campos *Name a partir de los JSON para que la tabla muestre nombres */
  #mapBranchNames(b) {
    return {
      ...b,
      ProvinciaName: this.#getProvinceName(b.EmsrUbProvincia),
      CantonName:    this.#getCantonName(b.EmsrUbProvincia, b.EmsrUbCanton),
      DistritoName:  this.#getDistritoName(b.EmsrUbProvincia, b.EmsrUbCanton, b.EmsrUbDistrito),
    };
  }

  // ── Panel lateral ─────────────────────────────────────────────────────────

  openCreatePanel() {
    // Defensa en profundidad: el botón se deshabilita sin permiso, pero
    // reverificamos aquí (ver CLAUDE.md §26).
    if (!this.#hasPerm('Configurations_Branches_Create')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para crear sucursales.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingBranch = null;
    this.panelTitleTarget.textContent = 'Nueva sucursal';
    this.saveIconTarget.textContent   = 'check';
    this.saveLabelTarget.textContent  = 'Guardar';
    this.#resetForm();
    this.#openPanel();
  }

  async #openEditPanel(row) {
    if (!this.#hasPerm('Configurations_Branches_Update')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para editar sucursales.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    this.panelTitleTarget.textContent = 'Editar sucursal';
    this.saveIconTarget.textContent   = 'refresh';
    this.saveLabelTarget.textContent  = 'Modificar';

    // Se relee del servidor en vez de usar la fila: la tabla pudo quedar vieja
    // si alguien editó la sucursal —o la emisión la tocó— mientras estaba
    // abierta. Mismo criterio que el panel de recursos de Service Layer.
    try {
      const json = await this.#apiFetch(`/api/branches/${row.Code}`);
      if (!json.Data) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'error',
          title: json.Message || 'No se encontró la sucursal.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
        return;
      }
      this.#editingBranch = json.Data;
      this.#populateFormForEdit(json.Data);
      this.#openPanel();
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al cargar la sucursal.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    }
  }

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // ── Formulario ────────────────────────────────────────────────────────────

  #resetForm() {
    this.inputSucursalNumTarget.value = '';
    this.inputOtrasSenasTarget.value  = '';
    this.inputTelefonoTarget.value    = '';
    this.inputFaxTarget.value         = '';
    this.inputEmailTarget.value       = '';
    this.inputAliasTarget.value       = '';
    this.inputActiveTarget.checked    = true;
    this.inputBarrioTarget.value      = '';
    this.#provinceId = '';
    this.#cantonId   = '';
    this.#neighborhoodList = [];

    // Provincia: solo resetear el valor seleccionado, NO borrar las opciones cargadas
    this.selectProvinciaTarget.value = '';
    // Cantón y Distrito: sí limpiar (dependen de la provincia seleccionada)
    this.#resetSelectTo(this.selectCantonTarget,   'Seleccione...');
    this.#resetSelectTo(this.selectDistritoTarget, 'Seleccione...');
    this.#clearAllErrors();
  }

  #populateFormForEdit(branch) {
    this.#provinceId = branch.EmsrUbProvincia;
    this.#cantonId   = branch.EmsrUbCanton;

    this.inputSucursalNumTarget.value = branch.SucursalNum ?? '';
    this.inputOtrasSenasTarget.value  = branch.EmsrUbOtrasSenas ?? '';
    this.inputTelefonoTarget.value    = branch.EmsrTlfNumTelefono ?? '';
    this.inputFaxTarget.value         = branch.EmsrFaxNumTelefono ?? '';
    this.inputEmailTarget.value       = branch.EmsrCorreoElectronico ?? '';
    this.inputAliasTarget.value       = branch.Alias ?? '';
    this.inputActiveTarget.checked    = Boolean(branch.Active);

    // Cargar selects en cascada
    this.#populateCantonSelect(branch.EmsrUbProvincia);
    this.#populateDistritoSelect(branch.EmsrUbCanton);
    this.#neighborhoodList = this.#getNeighborhoodByDistrict(
      branch.EmsrUbProvincia, branch.EmsrUbCanton, branch.EmsrUbDistrito
    );

    // Seleccionar valores
    this.selectProvinciaTarget.value = branch.EmsrUbProvincia ?? '';
    this.selectCantonTarget.value    = branch.EmsrUbCanton ?? '';
    this.selectDistritoTarget.value  = branch.EmsrUbDistrito ?? '';
    this.inputBarrioTarget.value     = branch.EmsrUbBarrio ?? '';

    this.#clearAllErrors();
  }

  // ── Cascada de ubicación ──────────────────────────────────────────────────

  onProvinciaChange(e) {
    const provinciaId = e.target.value;
    this.#provinceId  = provinciaId;
    this.#cantonId    = '';

    this.#populateCantonSelect(provinciaId);

    // Auto-seleccionar primer cantón → primer distrito → primer barrio
    const firstCanton = this.#getUniqueCantons(provinciaId)[0];
    if (firstCanton) {
      this.#cantonId = firstCanton.CantonId;
      this.selectCantonTarget.value = firstCanton.CantonId;
      this.#populateDistritoSelect(firstCanton.CantonId);

      const firstDistrito = this.#getUniqueDistritos(provinciaId, firstCanton.CantonId)[0];
      if (firstDistrito) {
        this.selectDistritoTarget.value = firstDistrito.DistrictId;
        this.#neighborhoodList = this.#getNeighborhoodByDistrict(
          provinciaId, firstCanton.CantonId, firstDistrito.DistrictId
        );
        this.inputBarrioTarget.value = this.#neighborhoodList[0]?.NeighborhoodName || '';
      }
    }
  }

  onCantonChange(e) {
    const cantonId   = e.target.value;
    this.#cantonId   = cantonId;

    this.#populateDistritoSelect(cantonId);

    const firstDistrito = this.#getUniqueDistritos(this.#provinceId, cantonId)[0];
    if (firstDistrito) {
      this.selectDistritoTarget.value = firstDistrito.DistrictId;
      this.#neighborhoodList = this.#getNeighborhoodByDistrict(
        this.#provinceId, cantonId, firstDistrito.DistrictId
      );
      this.inputBarrioTarget.value = this.#neighborhoodList[0]?.NeighborhoodName || '';
    }
  }

  onDistritoChange(e) {
    const districtId = e.target.value;
    this.#neighborhoodList = this.#getNeighborhoodByDistrict(
      this.#provinceId, this.#cantonId, districtId
    );
    this.inputBarrioTarget.value = this.#neighborhoodList[0]?.NeighborhoodName || '';
    this.barrioDropdownTarget.classList.add('hidden');
  }

  // ── Filtros de búsqueda ───────────────────────────────────────────────────

  onFilterProvinciaChange(e) {
    this.#populateFilterCantonSelect(e.target.value);
    this.#resetSelectTo(this.filterDistritoTarget, 'Todos');
  }

  onFilterCantonChange(e) {
    const provinciaId = this.filterProvinciaTarget.value;
    this.#populateFilterDistritoSelect(provinciaId, e.target.value);
  }

  /** Recarga desde el servidor con los filtros actuales y vuelve a la página 1. */
  search() {
    this.table?.setData();
  }

  #populateFilterProvinciaSelect() {
    const sel = this.filterProvinciaTarget;
    sel.innerHTML = '<option value="">Todas</option>';
    this.#provinces.forEach(p => {
      const opt = document.createElement('option');
      opt.value       = p.ProvinceId;
      opt.textContent = p.ProvinceName;
      sel.appendChild(opt);
    });
  }

  #populateFilterCantonSelect(provinciaId) {
    const sel = this.filterCantonTarget;
    sel.innerHTML = '<option value="">Todos</option>';
    if (provinciaId) {
      this.#getUniqueCantons(provinciaId).forEach(c => {
        const opt = document.createElement('option');
        opt.value       = c.CantonId;
        opt.textContent = c.CantonName;
        sel.appendChild(opt);
      });
    }
  }

  #populateFilterDistritoSelect(provinciaId, cantonId) {
    const sel = this.filterDistritoTarget;
    sel.innerHTML = '<option value="">Todos</option>';
    if (provinciaId && cantonId) {
      this.#getUniqueDistritos(provinciaId, cantonId).forEach(d => {
        const opt = document.createElement('option');
        opt.value       = d.DistrictId;
        opt.textContent = d.DistrictName;
        sel.appendChild(opt);
      });
    }
  }

  // ── Autocomplete barrio ───────────────────────────────────────────────────

  onBarrioInput(e) {
    const q = e.target.value.toLowerCase();
    const filtered = this.#neighborhoodList.filter(n =>
      n.NeighborhoodName.toLowerCase().includes(q)
    );
    this.#renderBarrioDropdown(filtered);
  }

  onBarrioFocus() {
    const q = this.inputBarrioTarget.value.toLowerCase();
    const filtered = this.#neighborhoodList.filter(n =>
      n.NeighborhoodName.toLowerCase().includes(q)
    );
    if (filtered.length) this.#renderBarrioDropdown(filtered);
  }

  onBarrioBlur() {
    // Delay para permitir click en el dropdown
    setTimeout(() => this.barrioDropdownTarget.classList.add('hidden'), 150);
  }

  #renderBarrioDropdown(items) {
    if (!items.length) {
      this.barrioDropdownTarget.classList.add('hidden');
      return;
    }
    this.barrioDropdownTarget.innerHTML = items
      .map(n => `<li class="px-3 py-2 hover:bg-blue-50 cursor-pointer" data-name="${n.NeighborhoodName}">${n.NeighborhoodName}</li>`)
      .join('');
    this.barrioDropdownTarget.classList.remove('hidden');

    this.barrioDropdownTarget.querySelectorAll('li').forEach(li => {
      li.addEventListener('mousedown', () => {
        this.inputBarrioTarget.value = li.dataset.name;
        this.barrioDropdownTarget.classList.add('hidden');
      });
    });
  }

  // ── Solo números ─────────────────────────────────────────────────────────

  onlyNumbers(e) {
    e.target.value = e.target.value.replace(/\D/g, '');
  }

  // ── Guardar ───────────────────────────────────────────────────────────────

  async saveFromPanel() {
    if (!this.#validate()) return;

    // Ni `Code` ni `CompanyId` viajan en el cuerpo: la llave va en el path y la
    // compañía sale de la sesión (CLAUDE.md §28). Los códigos de país del
    // teléfono y del fax los pone el servidor (506 fijo), porque el formulario
    // no los ofrece.
    const payload = {
      SucursalNum:           parseInt(this.inputSucursalNumTarget.value),
      EmsrUbProvincia:       this.selectProvinciaTarget.value,
      EmsrUbCanton:          this.selectCantonTarget.value,
      EmsrUbDistrito:        this.selectDistritoTarget.value,
      EmsrUbBarrio:          this.inputBarrioTarget.value,
      EmsrUbOtrasSenas:      this.inputOtrasSenasTarget.value.trim(),
      EmsrTlfNumTelefono:    this.inputTelefonoTarget.value.trim(),
      EmsrFaxNumTelefono:    this.inputFaxTarget.value.trim(),
      EmsrCorreoElectronico: this.inputEmailTarget.value.trim(),
      Active:                this.inputActiveTarget.checked,
      Alias:                 this.inputAliasTarget.value.trim(),
    };

    const code   = this.#editingBranch?.Code;
    const isEdit = code !== undefined && code !== null;
    const url    = isEdit ? `/api/branches/${code}` : '/api/branches';
    const method = isEdit ? 'PATCH' : 'POST';
    const msgErr = isEdit ? 'Error al actualizar la sucursal' : 'Error al crear la sucursal';

    this.#setLoading(true);
    try {
      const json = await this.#apiFetch(url, { method, body: JSON.stringify(payload) });
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: json.Message || 'Sucursal guardada exitosamente.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.closePanel();
      // `setData()` recarga desde el servidor con los filtros actuales; una
      // sucursal recién creada puede no entrar en ellos, y eso es correcto.
      this.table?.setData();
    } catch (err) {
      await Swal.fire({
        icon: 'error',
        title: msgErr,
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
    } finally {
      this.#setLoading(false);
    }
  }

  #setLoading(on) {
    this.saveBtnTarget.disabled = on;
    this.saveIconTarget.textContent = on ? 'hourglass_empty' : (this.#editingBranch ? 'refresh' : 'check');
  }

  // ── Validación ────────────────────────────────────────────────────────────

  #validate() {
    let valid = true;
    this.#clearAllErrors();

    const num = parseInt(this.inputSucursalNumTarget.value);
    if (!this.inputSucursalNumTarget.value.trim()) {
      this.errorSucursalNumTarget.classList.remove('hidden'); valid = false;
    } else if (isNaN(num) || num <= 0) {
      this.errorSucursalNumPatternTarget.classList.remove('hidden'); valid = false;
    }

    if (!this.selectProvinciaTarget.value) {
      this.errorProvinciaTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.selectCantonTarget.value) {
      this.errorCantonTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.selectDistritoTarget.value) {
      this.errorDistritoTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.inputBarrioTarget.value.trim()) {
      this.errorBarrioTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.inputOtrasSenasTarget.value.trim()) {
      this.errorOtrasSenasTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.inputTelefonoTarget.value.trim()) {
      this.errorTelefonoTarget.classList.remove('hidden'); valid = false;
    }

    const email = this.inputEmailTarget.value.trim();
    const emailRegex = /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,3}$/;
    if (!email) {
      this.errorEmailTarget.classList.remove('hidden'); valid = false;
    } else if (!emailRegex.test(email)) {
      this.errorEmailPatternTarget.classList.remove('hidden'); valid = false;
    }

    if (!this.inputAliasTarget.value.trim()) {
      this.errorAliasTarget.classList.remove('hidden'); valid = false;
    }

    return valid;
  }

  #clearAllErrors() {
    [
      'errorSucursalNum', 'errorSucursalNumPattern',
      'errorProvincia', 'errorCanton', 'errorDistrito', 'errorBarrio',
      'errorOtrasSenas', 'errorTelefono',
      'errorEmail', 'errorEmailPattern',
      'errorAlias',
    ].forEach(t => this[`${t}Target`]?.classList.add('hidden'));
  }

  // ── Helpers de ubicación ──────────────────────────────────────────────────

  #populateProvinceSelect() {
    const sel = this.selectProvinciaTarget;
    sel.innerHTML = '<option value="">Seleccione...</option>';
    this.#provinces.forEach(p => {
      const opt = document.createElement('option');
      opt.value       = p.ProvinceId;
      opt.textContent = p.ProvinceName;
      sel.appendChild(opt);
    });
  }

  #populateCantonSelect(provinciaId) {
    const cantons = this.#getUniqueCantons(provinciaId);
    const sel     = this.selectCantonTarget;
    sel.innerHTML = '<option value="">Seleccione...</option>';
    cantons.forEach(c => {
      const opt = document.createElement('option');
      opt.value       = c.CantonId;
      opt.textContent = c.CantonName;
      sel.appendChild(opt);
    });
    this.#resetSelectTo(this.selectDistritoTarget, 'Seleccione...');
    this.inputBarrioTarget.value = '';
    this.#neighborhoodList = [];
  }

  #populateDistritoSelect(cantonId) {
    const distritos = this.#getUniqueDistritos(this.#provinceId, cantonId);
    const sel       = this.selectDistritoTarget;
    sel.innerHTML = '<option value="">Seleccione...</option>';
    distritos.forEach(d => {
      const opt = document.createElement('option');
      opt.value       = d.DistrictId;
      opt.textContent = d.DistrictName;
      sel.appendChild(opt);
    });
    this.inputBarrioTarget.value = '';
    this.#neighborhoodList = [];
  }

  #getUniqueCantons(provinciaId) {
    const seen = new Set();
    return this.#country
      .filter(r => r.ProvinceId === provinciaId)
      .filter(r => {
        if (seen.has(r.CantonId)) return false;
        seen.add(r.CantonId);
        return true;
      })
      .map(r => ({ CantonId: r.CantonId, CantonName: r.CantonName }));
  }

  #getUniqueDistritos(provinciaId, cantonId) {
    const seen = new Set();
    return this.#country
      .filter(r => r.ProvinceId === provinciaId && r.CantonId === cantonId)
      .filter(r => {
        if (seen.has(r.DistrictId)) return false;
        seen.add(r.DistrictId);
        return true;
      })
      .map(r => ({ DistrictId: r.DistrictId, DistrictName: r.DistrictName }));
  }

  #getNeighborhoodByDistrict(provinciaId, cantonId, districtId) {
    const seen = new Set();
    return this.#country
      .filter(r => r.ProvinceId === provinciaId && r.CantonId === cantonId && r.DistrictId === districtId)
      .filter(r => {
        if (seen.has(r.NeighborhoodId)) return false;
        seen.add(r.NeighborhoodId);
        return true;
      })
      .map(r => ({ NeighborhoodId: r.NeighborhoodId, NeighborhoodName: r.NeighborhoodName }));
  }

  #getProvinceName(provinciaId) {
    return this.#provinces.find(p => p.ProvinceId === provinciaId)?.ProvinceName || provinciaId;
  }

  #getCantonName(provinciaId, cantonId) {
    return this.#country.find(r => r.ProvinceId === provinciaId && r.CantonId === cantonId)?.CantonName || cantonId;
  }

  #getDistritoName(provinciaId, cantonId, districtId) {
    return this.#country.find(r =>
      r.ProvinceId === provinciaId && r.CantonId === cantonId && r.DistrictId === districtId
    )?.DistrictName || districtId;
  }

  #resetSelectTo(sel, placeholder) {
    sel.innerHTML = `<option value="">${placeholder}</option>`;
  }

  // ── Badge de estado ───────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Nueva Sucursal" (nace deshabilitado/gris con tooltip de
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

  #statusBadge(status) {
    const map = {
      active:   { bg: '#e8f5ee', color: '#3a7d52', label: 'Activo'   },
      inactive: { bg: '#fdecea', color: '#c0392b', label: 'Inactivo' },
    };
    const { bg, color, label } = map[status] ?? { bg: '#f3f4f6', color: '#4b5563', label: status };
    return `<span style="background-color:${bg}; color:${color};"
                 class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${label}
    </span>`;
  }

  // ── apiFetch ──────────────────────────────────────────────────────────────

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

    const json = await response.json().catch(() => null);

    if (!response.ok) throw new Error(json?.Message || `HTTP ${response.status}`);

    return json ?? {};
  }
}

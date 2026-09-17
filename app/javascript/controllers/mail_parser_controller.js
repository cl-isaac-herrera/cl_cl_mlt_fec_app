import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * MailParserController — Gestión de procesadores de correo (Tabulator).
 *
 * Replica: /configurations/mail-parser-config (Angular MailParserConfigComponent)
 *
 * Funcionalidad:
 *   - Filtros: Email, Company, Status (2=Ambos/1=Activo/0=Inactivo),
 *              UseToken (2=Ambos/1=Sí/0=No)
 *   - Tabla: ID, Servidor, Correo, Puerto, Nombre Compañía, Usa Token, Automática, Activa
 *   - Acciones por fila: Editar (panel lateral), Ver Compañías Emisoras (panel lateral)
 *   - Panel lateral: crear/editar con validación y "Probar credenciales"
 *     - Campos base: ServerDirection, Email, CompanyId (autocomplete), Password, Port,
 *                    Status, IsAutomatic, UseToken (checkbox)
 *     - Campos token (condicional UseToken=true): TenantId, URL, GrantType, Scope,
 *                                                 ClientSecret, ClientId
 *     - Guardar deshabilitado hasta que se validen credenciales
 *   - Panel de Compañías Emisoras: lista filtrable de InboxProcessingTenant
 *     con toggle de estado activo/inactivo
 *
 * APIs (ApiAppUrl — default):
 *   GET  /api/mail-parser?mailServer=&mail=&status=&emsrNombre=&useToken=&startPost=&stepPost=
 *   POST /api/mail-parser
 *   PATCH /api/mail-parser
 *   POST /api/mail-parser/validate
 *   GET  /api/mail-parser/processing-tenants/{id}
 *   PATCH /api/mail-parser/processing-tenants/{tenantId}/status
 *   GET  /api/Companies/for-assignment
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,

    // Filtros
    // NOTA: 'filterServer' (Nombre del servidor) se eliminó de la vista (ver TODOS.md).
    // El parámetro mailServer se sigue enviando con valor por defecto hasta actualizar el API.
    'filterEmail', 'filterCompany', 'filterStatus', 'filterUseToken',

    // Toolbar
    'btnCreate', 'btnCreateWrap',

    // Panel lateral
    'panel', 'panelBackdrop', 'panelTitle',
    'saveBtn', 'btnValidate', 'validateIcon', 'validateLabel',

    // Campos del formulario
    'inputServer', 'errorServer',
    'inputEmail', 'errorEmail', 'errorEmailPattern',
    'inputCompany', 'companyDropdown',
    'passwordField', 'passwordRequired', 'inputPassword', 'errorPassword', 'passwordEyeIcon',
    'inputPort', 'errorPort',
    'tokenFields',
    'inputTenantId', 'errorTenantId',
    'inputUrl', 'errorUrl',
    'inputGrantType', 'errorGrantType',
    'inputScope', 'errorScope',
    'inputClientSecret', 'errorClientSecret', 'clientSecretEyeIcon',
    'inputClientId', 'errorClientId',
    'inputStatus', 'inputIsAutomatic', 'inputUseToken',

    // Panel de Compañías Emisoras
    'tableWrapper',
    'tenantsPanel', 'tenantsInboxEmail', 'tenantsSearch', 'tenantsLoading', 'tenantsList',

  ];

  static values = { ...TabulatorController.values };

  // ── Estado ────────────────────────────────────────────────────────────────

  #companyId    = null;
  #permissions  = [];
  #companiesList = [];       // IGetCompanyForAssignmentDto[]
  #selectedCompany = null;   // { Id, ComercialName }
  #editingRecord = null;     // null = crear, objeto = editar
  #isCredentialsValidated = false;
  #isValidating = false;
  #pageSize     = 10;
  #totalRecords = 0;

  // Panel de tenants
  #allTenants   = [];        // InboxProcessingTenant[]
  #selectedMailParserId = null;

  // Snapshot de credenciales (edición) — se actualiza tras validación exitosa
  #credentialSnapshot = null;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company    = SStore.get('CurrentCompany');
    this.#companyId  = company?.companyId ? parseInt(company.companyId) : null;
    this.#permissions = SStore.get('Permissions') || [];

    // Botón "Nueva Bandeja": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.hasBtnCreateTarget) {
      if (this.#hasPerm('Configurations_MailParser_Create')) {
        this.#enableCreateButton();
      } else if (this.hasBtnCreateWrapTarget) {
        this.#attachTooltip(this.btnCreateWrapTarget);
      }
    }

    super.connect(); // inicializa Tabulator; dispara ajaxRequestFunc con page=1 automáticamente
    this.#loadCompanies();
  }

  // ── Configuración Tabulator ────────────────────────────────────────────────

  getTableConfig() {
    // Excluir 'data' y 'maxHeight' del base para que Tabulator entre en modo ajax
    // (si 'data' key existe aunque sea undefined, Tabulator usa modo local y no muestra loader)
    const { data: _d, maxHeight: _m, ...base } = super.getTableConfig();
    return {
      ...base,
      height:    '100%',
      movableRows: false,
      layout: 'fitColumns',
      placeholder: 'No hay configuraciones registradas',
      pagination: true,
      paginationMode: 'remote',
      paginationSize: this.#pageSize,
      paginationSizeSelector: [5, 10, 15],
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs:  TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      ajaxURL: '/api/mail-parser',
      ajaxRequestFunc: (url, config, params) => this.#fetchPage(url, params),
      columns: this.getColumns(),
    };
  }

  getColumns() {
    return [
      { title: 'ID',           field: 'Id',         width: 60  },
      { title: 'Servidor',     field: 'MailServer',  minWidth: 140 },
      { title: 'Correo',       field: 'Email',       minWidth: 180 },
      { title: 'Puerto',       field: 'Port',        width: 80  },
      { title: 'Compañía',     field: 'EmsrNombre',  minWidth: 160 },
      {
        title: 'Autenticación por token',
        field: 'UseToken',
        width: 180,
        hozAlign: 'center',
        formatter: (cell) => this.#boolBadge(cell.getValue()),
      },
      {
        title: 'Automática',
        field: 'IsAutomatic',
        width: 110,
        hozAlign: 'center',
        formatter: (cell) => this.#boolBadge(cell.getValue()),
      },
      {
        title: 'Estado',
        field: 'Status',
        width: 90,
        formatter: (cell) => this.#statusBadge(cell.getValue() === 1 ? 'active' : 'inactive'),
      },
      {
        title: 'Acciones',
        field: '_actions',
        width: 110,
        hozAlign: 'center',
        headerSort: false,
        formatter: () => {
          // Editar sin permiso: deshabilitado + tooltip (CLAUDE.md §26). El
          // data-tooltip va en el <span> envolvente (un <button disabled> no
          // emite eventos de mouse); el setupTooltip base (tabla) lo detecta.
          const editBtn = this.#hasPerm('Configurations_MailParser_Update')
            ? `<button type="button" data-action-type="edit" data-tooltip="Editar"
                       class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
                 <span class="material-icons text-base">edit</span>
               </button>`
            : `<span data-tooltip="No cuenta con permisos para editar bandejas">
                 <button type="button" disabled
                         class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
                   <span class="material-icons text-base">edit</span>
                 </button>
               </span>`;
          return `
            ${editBtn}
            <button type="button"
                    data-action-type="view-companies"
                    data-tooltip="Ver Compañías"
                    class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
              <span class="material-icons text-base">business</span>
            </button>`;
        },
        cellClick: (_e, cell) => {
          const btn = _e.target.closest('[data-action-type]');
          if (!btn) return;
          const row = cell.getRow().getData();
          if (btn.dataset.actionType === 'edit') {
            this.#openEditPanel(row);
          } else if (btn.dataset.actionType === 'view-companies') {
            this.#openTenantsPanel(row);
          }
        },
      },
    ];
  }

  // ── Acciones públicas (data-action) ──────────────────────────────────────

  search() {
    // setData() recarga vía ajax y vuelve a la página 1
    this.table?.setData();
  }

  openCreatePanel() {
    // Defensa en profundidad: el botón se deshabilita sin permiso, pero
    // reverificamos aquí (ver CLAUDE.md §26).
    if (!this.#hasPerm('Configurations_MailParser_Create')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para crear bandejas.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingRecord = null;
    this.#isCredentialsValidated = false;
    this.#resetForm();
    this.panelTitleTarget.textContent = 'Nueva bandeja';
    this.#updateValidateButton();
    this.saveBtnTarget.disabled = true;
    this.#openPanel();
  }

  closePanel() {
    this.#closePanel();
  }

  onUseTokenChange() {
    const useToken = this.inputUseTokenTarget.checked;
    this.#toggleTokenFields(useToken);
    this.#isCredentialsValidated = false;
    this.#updateValidateButton();
    this.saveBtnTarget.disabled = true;
  }

  togglePassword() {
    const input = this.inputPasswordTarget;
    const icon  = this.passwordEyeIconTarget;
    if (input.type === 'password') {
      input.type = 'text';
      icon.textContent = 'visibility';
    } else {
      input.type = 'password';
      icon.textContent = 'visibility_off';
    }
  }

  toggleClientSecret() {
    const input = this.inputClientSecretTarget;
    const icon  = this.clientSecretEyeIconTarget;
    if (input.type === 'password') {
      input.type = 'text';
      icon.textContent = 'visibility';
    } else {
      input.type = 'password';
      icon.textContent = 'visibility_off';
    }
  }

  onCredentialChange() {
    if (!this.#credentialSnapshot) return; // nunca validado aún — save ya está deshabilitado
    const current = this.#getCredentialValues();
    const matches = this.#credentialsMatchSnapshot(current);
    if (matches) {
      this.#isCredentialsValidated = true;
      this.saveBtnTarget.disabled = false;
      this.#updateValidateButton(false, true);
    } else {
      this.#isCredentialsValidated = false;
      this.saveBtnTarget.disabled = true;
      this.#updateValidateButton(false, false);
    }
  }

  filterCompanies() {
    const q = this.inputCompanyTarget.value.toLowerCase();
    const filtered = this.#companiesList.filter(c =>
      c.ComercialName.toLowerCase().includes(q)
    );
    this.#renderCompanyDropdown(filtered);
  }

  showCompanyDropdown() {
    this.#renderCompanyDropdown(this.#companiesList);
  }

  closeCompanyDropdown() {
    // Delay para que el mousedown del item se registre antes de ocultarlo
    setTimeout(() => this.companyDropdownTarget.classList.add('hidden'), 150);
  }

  async validateCredentials() {
    if (this.#isValidating) return;
    if (!this.#validateForm()) return;

    this.#isValidating = true;
    this.#isCredentialsValidated = false;
    this.#updateValidateButton(true);
    this.saveBtnTarget.disabled = true;

    try {
      const payload = this.#buildPayload();
      await this.#apiFetch('/api/mail-parser/validate', {
        method: 'POST',
        body: JSON.stringify(payload),
      });
      this.#isCredentialsValidated = true;
      this.#credentialSnapshot = this.#getCredentialValues(); // actualizar snapshot al estado validado
      this.#updateValidateButton(false, true);
      this.saveBtnTarget.disabled = false;
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Credenciales validadas correctamente.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } catch (err) {
      // El endpoint puede devolver el cuerpo JSON crudo como texto del error si responde non-2xx
      let displayMessage = err.message || 'Error al validar las credenciales.';
      try {
        const parsed = JSON.parse(displayMessage);
        if (parsed?.errorInfo?.Message)      displayMessage = parsed.errorInfo.Message;
        else if (parsed?.Message)            displayMessage = parsed.Message;
      } catch { /* no es JSON, usar el mensaje tal cual */ }

      this.#isCredentialsValidated = false;
      this.#updateValidateButton(false, false);
      this.saveBtnTarget.disabled = true;
      Swal.fire({
        icon: 'error',
        title: 'Error al validar',
        text: displayMessage,
        confirmButtonText: 'Aceptar'
      });
    } finally {
      this.#isValidating = false;
    }
  }

  async save() {
    if (!this.#isCredentialsValidated) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Debe probar las credenciales antes de guardar.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    if (!this.#validateForm()) return;

    const payload = this.#buildPayload();
    const isEdit  = !!this.#editingRecord;

    try {
      if (isEdit) {
        await this.#apiFetch('/api/mail-parser', { method: 'PATCH', body: JSON.stringify(payload) });
      } else {
        await this.#apiFetch('/api/mail-parser', { method: 'POST', body: JSON.stringify(payload) });
      }
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Bandeja configurada correctamente.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.#closePanel();
      this.table?.setData();
    } catch (err) {
      Swal.fire({
        icon: 'error',
        title: 'Error al guardar',
        text: err.message || 'No se pudo guardar la configuración.',
        confirmButtonText: 'Aceptar'
      });
    }
  }

  // ── Panel de Compañías Emisoras ───────────────────────────────────────────

  closeTenantsPanel() {
    this.tenantsPanelTarget.classList.add('hidden');
    this.tenantsPanelTarget.classList.remove('flex');
    this.#selectedMailParserId = null;
  }

  filterTenants() {
    const term = this.tenantsSearchTarget.value.toLowerCase().trim();
    const filtered = term
      ? this.#allTenants.filter(t =>
          t.CompanyName.toLowerCase().includes(term) ||
          t.CompanyIdentification.toLowerCase().includes(term) ||
          String(t.CompanyId).includes(term)
        )
      : [...this.#allTenants];
    this.#renderTenants(filtered);
  }

  async toggleTenantStatus(event) {
    const btn    = event.currentTarget;
    const id     = parseInt(btn.dataset.tenantId);
    const active = btn.dataset.active === 'true';
    const newStatus = !active;

    const tenant = this.#allTenants.find(t => t.Id === id);
    if (!tenant) return;

    const action = newStatus
      ? `reanudar el procesamiento de correos de la compañía "${tenant.CompanyName}"`
      : `detener el procesamiento de correos de la compañía "${tenant.CompanyName}"`;
    const { isConfirmed } = await Swal.fire({
      title: 'Confirmar procesamiento de correos',
      text: `¿Está seguro que desea ${action}?`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonText: 'Confirmar',
      cancelButtonText: 'Cancelar'
    });
    if (!isConfirmed) return;

    try {
      await this.#apiFetch(`/api/mail-parser/processing-tenants/${id}/status`, {
        method: 'PATCH',
        body: JSON.stringify({ IsActive: newStatus }),
      });
      tenant.IsActive = newStatus;
      this.filterTenants();
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: `Se ${newStatus ? 'reanudó' : 'detuvo'} el procesamiento de correos de la compañía correctamente.`,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al cambiar el estado.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    }
  }

  // ── Métodos privados: datos ───────────────────────────────────────────────

  async #loadCompanies() {
    try {
      const data = await this.#apiFetch('/api/Companies/for-assignment');
      this.#companiesList = data.Data || [];
    } catch (_) {
      // no bloquear la carga de la página
    }
  }

  /**
   * Función de carga remota para Tabulator.
   * @param {string} url    ajaxURL configurada
   * @param {Object} params { page (1-indexed), size, ... }
   * @returns {Promise<{data: Array, last_page: number}>}
   */
  async #fetchPage(url, params) {
    const page = params.page || 1;
    const size = params.size || this.#pageSize;

    const qp = new URLSearchParams({
      // El filtro Nombre del servidor se eliminó de la vista — se envía vacío por defecto.
      // TODO (TODOS.md): quitar este parámetro cuando el API deje de requerirlo.
      mailServer: '',
      mail:       this.filterEmailTarget.value.trim(),
      emsrNombre: this.filterCompanyTarget.value.trim(),
      status:     this.filterStatusTarget.value,
      useToken:   this.filterUseTokenTarget.value,
      startPost:  String(page - 1),   // Tabulator 1-indexed → API 0-indexed
      stepPost:   String(size),
    });

    try {
      const json = await this.#apiFetch(`${url}?${qp}`);
      const records  = (json.Data || []).map(r => ({ ...r, EmsrNombre: r.EmsrNombre || '-' }));
      const total    = json.MaxQtyRowsFetch ?? records[0]?.MaxQtyRowsFetch ?? 0;
      this.#totalRecords = total;
      const lastPage = Math.max(1, Math.ceil(total / size));
      return { data: records, last_page: lastPage };
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al consultar los procesadores de correo.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return { data: [], last_page: 1 };
    }
  }

  async #openTenantsPanel(row) {
    this.#selectedMailParserId = row.Id;
    this.tenantsSearchTarget.value = '';
    this.#allTenants = [];
    this.tenantsListTarget.innerHTML = '';

    // Mostrar qué bandeja pertenece este panel
    this.tenantsInboxEmailTarget.textContent = row.Email || '';

    // Mostrar panel
    this.tenantsPanelTarget.classList.remove('hidden');
    this.tenantsPanelTarget.classList.add('flex');
    this.tenantsLoadingTarget.classList.remove('hidden');

    try {
      const data = await this.#apiFetch(`/api/mail-parser/processing-tenants/${row.Id}`);
      this.#allTenants = data.Data || [];
      if (this.#allTenants.length === 0) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'warning',
          title: 'No se encontraron compañías procesadas para esta bandeja.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      }
      this.#renderTenants(this.#allTenants);
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al obtener las compañías.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } finally {
      this.tenantsLoadingTarget.classList.add('hidden');
    }
  }

  // ── Métodos privados: panel lateral ──────────────────────────────────────

  #openEditPanel(row) {
    if (!this.#hasPerm('Configurations_MailParser_Update')) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No cuenta con permisos para editar bandejas.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }
    this.#editingRecord = row;
    this.#resetForm();
    this.panelTitleTarget.textContent = 'Editar bandeja';

    // Poblar formulario
    this.inputServerTarget.value    = row.MailServer  || '';
    this.inputEmailTarget.value     = row.Email       || '';
    this.inputPortTarget.value      = row.Port        || '';
    this.inputStatusTarget.checked  = row.Status === 1;
    this.inputIsAutomaticTarget.checked = !!row.IsAutomatic;
    this.inputUseTokenTarget.checked    = !!row.UseToken;

    // Empresa
    const company = this.#companiesList.find(c => c.Id === row.CompanyId);
    if (company) {
      this.#selectedCompany = company;
      this.inputCompanyTarget.value = company.ComercialName;
    }

    // Campos token
    this.#toggleTokenFields(row.UseToken);
    if (row.UseToken) {
      this.inputTenantIdTarget.value     = row.TenantId     || '';
      this.inputUrlTarget.value          = row.Url          || '';
      this.inputGrantTypeTarget.value    = row.GrantType    || '';
      this.inputScopeTarget.value        = row.Scope        || '';
      this.inputClientSecretTarget.value = row.ClientSecret || '';
      this.inputClientIdTarget.value     = row.ClientId     || '';
    }

    // Capturar snapshot de credenciales — contraseña siempre vacía (el servidor usa la guardada)
    this.#credentialSnapshot = this.#getCredentialValues();
    this.#isCredentialsValidated = true;
    this.#updateValidateButton(false, true);
    this.saveBtnTarget.disabled = false;
    this.#openPanel();
  }

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  #closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
    this.#editingRecord = null;
    this.#isCredentialsValidated = false;
  }

  #resetForm() {
    this.inputServerTarget.value      = '';
    this.inputEmailTarget.value       = '';
    this.inputCompanyTarget.value     = '';
    this.inputPasswordTarget.value    = '';
    this.inputPasswordTarget.type     = 'password';
    this.passwordEyeIconTarget.textContent = 'visibility_off';
    this.inputPortTarget.value        = '';
    this.inputStatusTarget.checked    = true;
    this.inputIsAutomaticTarget.checked = false;
    this.inputUseTokenTarget.checked  = false;
    // Limpiar campos token
    this.inputTenantIdTarget.value     = '';
    this.inputUrlTarget.value          = '';
    this.inputGrantTypeTarget.value    = '';
    this.inputScopeTarget.value        = '';
    this.inputClientSecretTarget.value = '';
    this.inputClientSecretTarget.type  = 'password';
    this.clientSecretEyeIconTarget.textContent = 'visibility_off';
    this.inputClientIdTarget.value     = '';
    this.#selectedCompany              = null;
    this.#credentialSnapshot           = null;
    this.#toggleTokenFields(false);
    this.#clearErrors();
    this.companyDropdownTarget.classList.add('hidden');
  }

  #toggleTokenFields(useToken) {
    if (useToken) {
      this.tokenFieldsTarget.classList.remove('hidden');
      this.passwordFieldTarget.classList.add('hidden');
    } else {
      this.tokenFieldsTarget.classList.add('hidden');
      this.passwordFieldTarget.classList.remove('hidden');
    }
  }

  // ── Métodos privados: validación ─────────────────────────────────────────

  #validateForm() {
    this.#clearErrors();
    let valid = true;
    const EMAIL_RE = /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,3}$/i;
    const useToken = this.inputUseTokenTarget.checked;
    const isEdit   = !!this.#editingRecord;

    if (!this.inputServerTarget.value.trim()) {
      this.errorServerTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.inputEmailTarget.value.trim()) {
      this.errorEmailTarget.classList.remove('hidden'); valid = false;
    } else if (!EMAIL_RE.test(this.inputEmailTarget.value)) {
      this.errorEmailPatternTarget.classList.remove('hidden'); valid = false;
    }
    if (!this.inputPortTarget.value) {
      this.errorPortTarget.classList.remove('hidden'); valid = false;
    }

    if (!useToken && !isEdit && !this.inputPasswordTarget.value) {
      this.errorPasswordTarget.classList.remove('hidden'); valid = false;
    }

    if (useToken) {
      if (!this.inputTenantIdTarget.value.trim())    { this.errorTenantIdTarget.classList.remove('hidden');    valid = false; }
      if (!this.inputUrlTarget.value.trim())         { this.errorUrlTarget.classList.remove('hidden');         valid = false; }
      if (!this.inputGrantTypeTarget.value.trim())   { this.errorGrantTypeTarget.classList.remove('hidden');   valid = false; }
      if (!this.inputScopeTarget.value.trim())       { this.errorScopeTarget.classList.remove('hidden');       valid = false; }
      if (!this.inputClientSecretTarget.value.trim()){ this.errorClientSecretTarget.classList.remove('hidden'); valid = false; }
      if (!this.inputClientIdTarget.value.trim())    { this.errorClientIdTarget.classList.remove('hidden');    valid = false; }
    }

    if (!valid) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Favor completar los espacios requeridos.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    }
    return valid;
  }

  #clearErrors() {
    const targets = [
      'errorServer', 'errorEmail', 'errorEmailPattern', 'errorPassword', 'errorPort',
      'errorTenantId', 'errorUrl', 'errorGrantType', 'errorScope', 'errorClientSecret', 'errorClientId',
    ];
    targets.forEach(t => { if (this[`${t}Target`]) this[`${t}Target`].classList.add('hidden'); });
  }

  // ── Métodos privados: construcción del payload ────────────────────────────

  #buildPayload() {
    const useToken = this.inputUseTokenTarget.checked;
    return {
      Id:           this.#editingRecord?.Id || 0,
      MailServer:   this.inputServerTarget.value.trim(),
      Email:        this.inputEmailTarget.value.trim(),
      Password:     this.inputPasswordTarget.value || '',
      Port:         String(this.inputPortTarget.value),
      IsAutomatic:  this.inputIsAutomaticTarget.checked,
      Status:       this.inputStatusTarget.checked ? 1 : 0,
      CompanyId:    this.#selectedCompany?.Id || null,
      UseToken:     useToken,
      TenantId:     useToken ? this.inputTenantIdTarget.value.trim()    : '',
      Url:          useToken ? this.inputUrlTarget.value.trim()         : '',
      GrantType:    useToken ? this.inputGrantTypeTarget.value.trim()   : '',
      Scope:        useToken ? this.inputScopeTarget.value.trim()       : '',
      ClientSecret: useToken ? this.inputClientSecretTarget.value.trim() : '',
      ClientId:     useToken ? this.inputClientIdTarget.value.trim()    : '',
    };
  }

  // ── Métodos privados: UI helpers ─────────────────────────────────────────

  #updateValidateButton(validating = false, validated = false) {
    const icon  = this.validateIconTarget;
    const label = this.validateLabelTarget;
    if (validating) {
      icon.textContent  = 'hourglass_empty';
      label.textContent = 'Probando...';
      this.btnValidateTarget.disabled = true;
    } else if (validated) {
      icon.textContent  = 'check_circle';
      label.textContent = 'Credenciales verificadas';
      this.btnValidateTarget.disabled = false;
    } else {
      icon.textContent  = 'wifi_tethering';
      label.textContent = 'Probar credenciales';
      this.btnValidateTarget.disabled = false;
    }
  }

  #renderCompanyDropdown(list) {
    const dropdown = this.companyDropdownTarget;
    dropdown.innerHTML = '';
    if (!list.length) { dropdown.classList.add('hidden'); return; }

    list.forEach(c => {
      const li = document.createElement('li');
      li.textContent = c.ComercialName;
      li.className = 'px-3 py-2 cursor-pointer hover:bg-blue-50';
      li.addEventListener('mousedown', () => {
        this.#selectedCompany = c;
        this.inputCompanyTarget.value = c.ComercialName;
        dropdown.classList.add('hidden');
        this.#isCredentialsValidated = false;
        this.#updateValidateButton();
        this.saveBtnTarget.disabled = true;
      });
      dropdown.appendChild(li);
    });
    dropdown.classList.remove('hidden');
  }

  #renderTenants(tenants) {
    const container = this.tenantsListTarget;
    if (!tenants.length) {
      container.innerHTML = `
        <div class="flex flex-col items-center justify-center py-8 text-gray-400 gap-2">
          <span class="material-icons text-3xl">business_off</span>
          <p class="text-sm">No hay compañías procesadas</p>
        </div>`;
      return;
    }

    const canToggle = this.#permissions.includes('Configurations_MailParser_UpdateAllProcessingTenantStatus')
                   || this.#permissions.includes('Configurations_MailParser_UpdateProcessingTenantStatus');

    container.innerHTML = tenants.map(t => `
      <div class="flex items-center justify-between p-3 border border-gray-100 rounded-lg ${t.IsActive ? '' : 'opacity-60'}">
        <div class="min-w-0 flex-1">
          <p class="text-sm font-medium text-gray-800 truncate">${t.CompanyName}</p>
          <p class="text-xs text-gray-500">${t.CompanyIdentification} · ID: ${t.CompanyId}</p>
        </div>
        <button type="button"
                ${canToggle ? 'data-action="click->mail-parser#toggleTenantStatus"' : ''}
                data-tenant-id="${t.Id}"
                data-active="${t.IsActive}"
                class="ml-2 flex-shrink-0 ${canToggle ? 'cursor-pointer' : 'cursor-default'}">
          ${this.#statusBadge(t.IsActive ? 'active' : 'inactive')}
        </button>
      </div>`).join('');
  }

  #boolBadge(value) {
    return value
      ? `<span class="material-icons text-base" style="color:#1a56db;">check_circle_outline</span>`
      : `<span class="material-icons text-base" style="color:#9ca3af;">radio_button_unchecked</span>`;
  }

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Nueva Bandeja" (nace deshabilitado/gris con tooltip de
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

  #statusBadge(status, labelOverride = null) {
    const map = {
      active:   { bg: '#e8f5ee', color: '#3a7d52', label: 'Activo'   },
      inactive: { bg: '#fdecea', color: '#c0392b', label: 'Inactivo' },
    };
    const { bg, color, label } = map[status] ?? { bg: '#f3f4f6', color: '#4b5563', label: status };
    return `<span style="background-color:${bg}; color:${color};"
                 class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${labelOverride ?? label}
    </span>`;
  }

  // ── Fetch helper ─────────────────────────────────────────────────────────

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

  // Retorna los valores actuales de los campos de credenciales según el modo activo
  #getCredentialValues() {
    const useToken = this.inputUseTokenTarget.checked;
    const base = {
      server: this.inputServerTarget.value.trim(),
      email:  this.inputEmailTarget.value.trim(),
      port:   this.inputPortTarget.value.trim(),
    };
    if (useToken) {
      return {
        ...base,
        useToken:     true,
        tenantId:     this.inputTenantIdTarget.value.trim(),
        url:          this.inputUrlTarget.value.trim(),
        grantType:    this.inputGrantTypeTarget.value.trim(),
        scope:        this.inputScopeTarget.value.trim(),
        clientSecret: this.inputClientSecretTarget.value.trim(),
        clientId:     this.inputClientIdTarget.value.trim(),
      };
    }
    return {
      ...base,
      useToken: false,
      password: this.inputPasswordTarget.value, // no trim — puede tener espacios válidos
    };
  }

  // Compara los valores actuales contra el snapshot
  #credentialsMatchSnapshot(current) {
    if (!this.#credentialSnapshot) return false;
    return JSON.stringify(current) === JSON.stringify(this.#credentialSnapshot);
  }
}

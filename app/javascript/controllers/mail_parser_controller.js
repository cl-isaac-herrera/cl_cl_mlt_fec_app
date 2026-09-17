import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * MailParserController — Bandejas de correo de RECEPCIÓN (/configurations/mail-parser).
 *
 * Reemplaza `MailParserConfig` del conector .NET legacy
 * (`legacy/reception/clvsfemailsconector`), del que `MailReceptionJob` lee los
 * documentos de los proveedores. Migrado a los endpoints REST nativos (CLAUDE.md
 * §28) con el mismo patrón que `email_senders_controller.js` (su sección
 * hermana de ENVÍO): panel lateral, prueba de credenciales obligatoria antes de
 * guardar por huella (`#verifiedFingerprint`), y sesión por cookie
 * (`getApiHeaders()`, sin el header `API`/token de proxy que usaba esta
 * pantalla contra el `/api/mail-parser` del .NET).
 *
 * Recortado respecto al legacy y a la versión anterior de esta pantalla: SIN
 * selector de compañía ni checkbox "Automático" en el panel de alta/edición, y
 * sin el filtro de compañía en la tabla. La relación con la compañía se
 * invirtió — ahora es `companies.reception_mailbox_id`, elegida desde el
 * formulario de compañías (`company_form_controller.js`) — y "automática" no
 * aplica porque `MailReceptionJob` corre siempre (`config/recurring.yml`).
 *
 * El panel "Ver Compañías Emisoras" (`InboxProcessingTenant` del legacy) NO se
 * tocó en este cambio: sigue llamando a `/api/mail-parser/processing-tenants/*`,
 * que todavía no existe del lado de Rails. Queda pendiente aparte.
 *
 * Endpoints (Rails nativo):
 *   GET   /api/reception_mailboxes?email=&use_token=&status=&page=&per_page=
 *   GET   /api/reception_mailboxes/assignable
 *   POST  /api/reception_mailboxes
 *   PATCH /api/reception_mailboxes/:id
 *   POST  /api/reception_mailbox_validations
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,

    // Filtros
    'filterEmail', 'filterStatus', 'filterUseToken',

    // Toolbar
    'btnCreate', 'btnCreateWrap',

    // Panel lateral
    'panel', 'panelBackdrop', 'panelTitle',
    'saveBtn', 'saveBtnWrap', 'saveLabel',
    'btnValidate', 'validateIcon', 'validateLabel',

    // Campos del formulario
    'inputServer',
    'inputEmail',
    'inputPassword', 'passwordField', 'passwordEyeIcon', 'passwordAsterisk', 'passwordHint',
    'inputPort',
    'inputUseToken', 'tokenFields',
    'inputUrl',
    'inputGrantType',
    'inputScope',
    'inputClientSecret', 'clientSecretEyeIcon', 'clientSecretAsterisk', 'clientSecretHint',
    'inputClientId',
    'inputActive', 'activeHint',

    // Panel de Compañías Emisoras — sin tocar (ver comentario de arriba)
    'tableWrapper',
    'tenantsPanel', 'tenantsInboxEmail', 'tenantsSearch', 'tenantsLoading', 'tenantsList',
  ];

  static values = { ...TabulatorController.values };

  // ── Estado ────────────────────────────────────────────────────────────────

  #permissions   = [];
  #totalRecords  = 0;        // total real del servidor (evita la sobreestimación de §17)
  #editingRecord = null;     // null = crear, objeto = editar

  // La prueba de credenciales es requisito para guardar. `#verifiedFingerprint`
  // guarda la huella de los valores con los que la prueba pasó: si alguno
  // cambia, la verificación deja de valer sin tener que escuchar campo por
  // campo (mismo patrón que `email_senders_controller.js`/`connections_controller.js`).
  #verifiedFingerprint = null;
  #isValidating = false;

  // Panel de tenants (sin tocar)
  #allTenants = [];
  #selectedMailParserId = null;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
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

    // El botón de guardar del panel también vive fuera de la tabla, así que el
    // `setupTooltip()` del base no lo cubre.
    if (this.hasSaveBtnWrapTarget) this.#attachTooltip(this.saveBtnWrapTarget);

    super.connect(); // inicializa Tabulator; dispara ajaxRequestFunc con page=1
  }

  // ── Configuración Tabulator ────────────────────────────────────────────────

  getTableConfig() {
    // Excluir 'data' y 'maxHeight' del base para que Tabulator entre en modo ajax
    // (si 'data' key existe aunque sea undefined, Tabulator usa modo local y no
    // muestra loader) y para que la tabla ocupe el alto del contenedor (§11).
    const { data: _d, maxHeight: _m, ...base } = super.getTableConfig();
    return {
      ...base,
      height:    '100%',
      movableRows: false,
      layout: 'fitColumns',
      placeholder: 'No hay bandejas registradas',
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [5, 10, 15, 25],
      paginationCounter: (pageSize, currentRow) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs:  TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      ajaxURL: '/api/reception_mailboxes',
      ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
      columns: this.getColumns(),
    };
  }

  getColumns() {
    return [
      { title: 'Correo',     field: 'Email',      minWidth: 180 },
      { title: 'Servidor',   field: 'MailServer', minWidth: 160 },
      { title: 'Puerto',     field: 'Port',        width: 90 },
      {
        title: 'Autenticación por token',
        field: 'UseToken',
        width: 180,
        hozAlign: 'center',
        formatter: (cell) => this.#boolBadge(cell.getValue()),
      },
      {
        title: 'Compañías',
        field: 'CompaniesCount',
        width: 100,
        hozAlign: 'center',
      },
      {
        title: 'Estado',
        field: 'Active',
        width: 100,
        formatter: (cell) => this.#statusBadge(cell.getValue() ? 'active' : 'inactive'),
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

  /** setData() recarga vía ajaxRequestFunc y vuelve a la página 1. */
  search() {
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
    this.#resetForm();
    this.panelTitleTarget.textContent = 'Nueva bandeja';
    this.saveLabelTarget.textContent  = 'Crear';
    this.#applyPanelMode();
    this.#openPanel();
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
    this.#editingRecord = null;
    this.#verifiedFingerprint = null;
  }

  togglePassword() {
    const input = this.inputPasswordTarget;
    input.type = input.type === 'password' ? 'text' : 'password';
    this.passwordEyeIconTarget.textContent = input.type === 'password' ? 'visibility_off' : 'visibility';
  }

  toggleClientSecret() {
    const input = this.inputClientSecretTarget;
    input.type = input.type === 'password' ? 'text' : 'password';
    this.clientSecretEyeIconTarget.textContent = input.type === 'password' ? 'visibility_off' : 'visibility';
  }

  onUseTokenChange() {
    this.#toggleTokenFields(this.inputUseTokenTarget.checked);
    this.onFormChange();
  }

  /**
   * Llamada desde `data-action="input-> change->"` del contenedor del panel.
   * No compara campo por campo: recalcula el estado de los dos botones a
   * partir de la huella, así que un campo nuevo no se puede olvidar de
   * invalidar la verificación.
   */
  onFormChange() {
    this.#syncValidateButton();
    this.#syncSaveButton();
  }

  async validateCredentials() {
    if (this.#isValidating) return;

    const blocked = this.#validateBlockedReason();
    if (blocked) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: blocked,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    const fingerprint = this.#fingerprint();
    this.#isValidating = true;
    this.#verifiedFingerprint = null;
    this.onFormChange();

    try {
      const useToken = this.inputUseTokenTarget.checked;
      const json = await this.#apiFetch('/api/reception_mailbox_validations', {
        method: 'POST',
        body: JSON.stringify({
          Id:           this.#editingRecord?.Id ?? null,
          MailServer:   this.inputServerTarget.value.trim(),
          Email:        this.inputEmailTarget.value.trim(),
          Port:         this.inputPortTarget.value,
          UseToken:     useToken,
          Password:     useToken ? '' : this.inputPasswordTarget.value,
          Url:          useToken ? this.inputUrlTarget.value.trim()          : '',
          GrantType:    useToken ? this.inputGrantTypeTarget.value.trim()    : '',
          Scope:        useToken ? this.inputScopeTarget.value.trim()        : '',
          ClientId:     useToken ? this.inputClientIdTarget.value.trim()     : '',
          ClientSecret: useToken ? this.inputClientSecretTarget.value        : '',
        }),
      });

      // Credenciales inválidas llegan como 200 con `Data: false` y el motivo en
      // `Message`: no es un error de la petición, es el resultado de la prueba.
      if (json?.Data === true) {
        this.#verifiedFingerprint = fingerprint;
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: json.Message || 'La conexión con la bandeja fue exitosa.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      } else {
        await Swal.fire({
          icon: 'error',
          title: 'No se pudo conectar la bandeja',
          text: json?.Message || 'El servidor de correo rechazó la configuración.',
          confirmButtonText: 'Aceptar'
        });
      }
    } catch (err) {
      await Swal.fire({
        icon: 'error',
        title: 'Error al probar la bandeja',
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
    } finally {
      this.#isValidating = false;
      this.onFormChange();
    }
  }

  async save() {
    // Defensa en profundidad: la UI ya deshabilita el botón, pero se puede
    // manipular (CLAUDE.md §26).
    const blocked = this.#saveBlockedReason();
    if (blocked) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: blocked,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    const isCreate = !this.#editingRecord;
    const url    = isCreate ? '/api/reception_mailboxes' : `/api/reception_mailboxes/${this.#editingRecord.Id}`;
    const method = isCreate ? 'POST' : 'PATCH';

    this.saveBtnTarget.disabled = true;
    try {
      const json = await this.#apiFetch(url, { method, body: JSON.stringify(this.#payload()) });
      this.closePanel();
      this.table?.setData();
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: json.Message || 'Bandeja guardada con éxito.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } catch (err) {
      // Error de escritura → modal, no toast (CLAUDE.md §9).
      await Swal.fire({
        icon: 'error',
        title: 'Error al guardar la bandeja',
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
      this.#syncSaveButton();
    }
  }

  // ── Panel de Compañías Emisoras — SIN TOCAR ──────────────────────────────
  //
  // Sigue llamando a `/api/mail-parser/processing-tenants/*`, que no existe
  // del lado de Rails todavía. Queda pendiente aparte.

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

  // ── Datos ─────────────────────────────────────────────────────────────────

  /**
   * Carga remota para Tabulator.
   * @param {Object} params `{ page (1-indexed), size }`
   * @returns {Promise<{data: Array, last_page: number}>}
   */
  async #fetchPage(params) {
    const page = params.page || 1;
    const size = params.size || 10;

    const query = new URLSearchParams({ page, per_page: size });
    const email = this.filterEmailTarget.value.trim();
    if (email) query.set('email', email);

    // Los `<select>` de Estado/Token usan '2' para "Ambos": un filtro ausente
    // no filtra, y no hace falta mandar ningún valor centinela.
    const status = this.#tristate(this.filterStatusTarget.value);
    if (status !== null) query.set('status', status);

    const useToken = this.#tristate(this.filterUseTokenTarget.value);
    if (useToken !== null) query.set('use_token', useToken);

    try {
      const json = await this.#apiFetch(`/api/reception_mailboxes?${query}`);
      const total = json.Data?.Total ?? 0;
      this.#totalRecords = total;
      return { data: json.Data?.Items ?? [], last_page: Math.max(1, Math.ceil(total / size)) };
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al buscar las bandejas.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.#totalRecords = 0;
      return { data: [], last_page: 1 };
    }
  }

  #tristate(value) {
    if (value === '1') return 'true';
    if (value === '0') return 'false';

    return null;
  }

  // ── Panel lateral ─────────────────────────────────────────────────────────

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

    this.panelTitleTarget.textContent = 'Modificar bandeja';
    this.saveLabelTarget.textContent  = 'Modificar';

    this.inputServerTarget.value    = row.MailServer || '';
    this.inputEmailTarget.value     = row.Email      || '';
    this.inputPortTarget.value      = row.Port ?? '';
    this.inputUseTokenTarget.checked = !!row.UseToken;
    this.inputActiveTarget.checked   = row.Active !== false;

    this.#toggleTokenFields(row.UseToken);
    if (row.UseToken) {
      this.inputUrlTarget.value       = row.Url       || '';
      this.inputGrantTypeTarget.value = row.GrantType || '';
      this.inputScopeTarget.value     = row.Scope     || '';
      this.inputClientIdTarget.value  = row.ClientId  || '';
    }
    // Password/ClientSecret NUNCA vienen del servidor (§38, mismo criterio que
    // `email_configs`): quedan en blanco, que es lo que significa "conservar
    // el guardado".

    this.#applyPanelMode();
    this.#openPanel();
  }

  /**
   * Lo que cambia entre crear y editar — mismo patrón que
   * `email_senders_controller.js#applyPanelMode`:
   *
   *  - la contraseña/el client secret dejan de ser obligatorios (en blanco =
   *    conservar el guardado);
   *  - el check "Bandeja activa" solo aparece al editar: dar de alta una
   *    bandeja inactiva no tiene sentido, y `is_active` nace en `true`;
   *  - el aviso de cuántas compañías la usan, que es el motivo por el que
   *    desactivarla puede fallar.
   */
  #applyPanelMode() {
    const isEdit = !!this.#editingRecord;

    this.passwordAsteriskTarget.classList.toggle('hidden', isEdit);
    this.passwordHintTarget.classList.toggle('hidden', !isEdit || !this.#editingRecord.HasPassword);
    this.clientSecretAsteriskTarget.classList.toggle('hidden', isEdit);
    this.clientSecretHintTarget.classList.toggle('hidden', !isEdit || !this.#editingRecord.HasClientSecret);
    this.inputActiveTarget.closest('[data-active-field]').classList.toggle('hidden', !isEdit);

    const inUse = isEdit ? (this.#editingRecord.CompaniesCount || 0) : 0;
    this.activeHintTarget.classList.toggle('hidden', inUse === 0);
    if (inUse > 0) {
      this.activeHintTarget.textContent = inUse === 1
        ? 'Una compañía usa esta bandeja: hay que reasignarla antes de poder desactivarla.'
        : `${inUse} compañías usan esta bandeja: hay que reasignarlas antes de poder desactivarla.`;
    }

    this.onFormChange();
  }

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  #resetForm() {
    this.inputServerTarget.value   = '';
    this.inputEmailTarget.value    = '';
    this.inputPortTarget.value     = '';
    this.inputPasswordTarget.value = '';
    this.inputPasswordTarget.type  = 'password';
    this.passwordEyeIconTarget.textContent = 'visibility_off';
    this.inputUseTokenTarget.checked = false;
    this.inputUrlTarget.value          = '';
    this.inputGrantTypeTarget.value    = '';
    this.inputScopeTarget.value        = '';
    this.inputClientIdTarget.value     = '';
    this.inputClientSecretTarget.value = '';
    this.inputClientSecretTarget.type  = 'password';
    this.clientSecretEyeIconTarget.textContent = 'visibility_off';
    this.inputActiveTarget.checked = true;
    this.#toggleTokenFields(false);
    this.#verifiedFingerprint = null;
  }

  #toggleTokenFields(useToken) {
    this.tokenFieldsTarget.classList.toggle('hidden', !useToken);
    this.passwordFieldTarget.classList.toggle('hidden', !!useToken);
  }

  // ── Validación y estado de los botones ────────────────────────────────────

  /**
   * Valores de los que depende el resultado de la prueba — mismo criterio que
   * `email_senders_controller.js#fingerprint`: `JSON.stringify` y no un
   * `join`, porque un separador puede aparecer dentro de una contraseña.
   */
  #fingerprint() {
    const useToken = this.inputUseTokenTarget.checked;
    const base = [this.inputServerTarget.value.trim(), this.inputEmailTarget.value.trim(),
                  this.inputPortTarget.value, useToken];

    return JSON.stringify(useToken
      ? [...base, this.inputUrlTarget.value.trim(),
         this.inputGrantTypeTarget.value.trim(), this.inputScopeTarget.value.trim(),
         this.inputClientIdTarget.value.trim(), this.inputClientSecretTarget.value]
      : [...base, this.inputPasswordTarget.value]);
  }

  #isVerified() {
    return this.#verifiedFingerprint !== null && this.#verifiedFingerprint === this.#fingerprint();
  }

  /**
   * Motivo por el que todavía no se puede PROBAR, o `null` si ya se puede.
   * Cada mensaje responde *¿cuándo SÍ podré usarlo?* (§2).
   */
  #validateBlockedReason() {
    const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    if (!this.inputServerTarget.value.trim()) return 'Ingrese el servidor de la bandeja para probarla';
    if (!this.inputEmailTarget.value.trim())  return 'Ingrese el correo de la bandeja para probarla';
    if (!EMAIL_RE.test(this.inputEmailTarget.value.trim())) return 'El correo de la bandeja no tiene un formato válido';
    if (!this.inputPortTarget.value)          return 'Ingrese el puerto de la bandeja para probarla';

    if (this.inputUseTokenTarget.checked) {
      if (!this.inputUrlTarget.value.trim())       return 'Ingrese la URL del token para probar la bandeja';
      if (!this.inputGrantTypeTarget.value.trim()) return 'Ingrese el Grant Type para probar la bandeja';
      if (!this.inputScopeTarget.value.trim())     return 'Ingrese el Scope para probar la bandeja';
      if (!this.inputClientIdTarget.value.trim())  return 'Ingrese el Client Id para probar la bandeja';
      // En edición el client secret guardado sirve: en blanco significa "el que ya está".
      if (!this.inputClientSecretTarget.value && !this.#editingRecord?.HasClientSecret) {
        return 'Ingrese el Client Secret para probar la bandeja';
      }
    } else if (!this.inputPasswordTarget.value && !this.#editingRecord?.HasPassword) {
      return 'Ingrese la contraseña de la bandeja para probarla';
    }

    return null;
  }

  /** Motivo por el que todavía no se puede GUARDAR, o `null`. */
  #saveBlockedReason() {
    const blocked = this.#validateBlockedReason();
    // Mientras falten campos, el motivo de no poder guardar es el mismo que el
    // de no poder probar — decir "pruebe las credenciales" con el servidor
    // vacío manda al usuario a un botón que tampoco funciona.
    if (blocked) return blocked;
    if (this.#isValidating) return 'Espere a que termine la prueba de la bandeja';
    if (!this.#isVerified()) return 'Debe probar la bandeja antes de guardarla';

    return null;
  }

  #syncValidateButton() {
    const blocked  = this.#validateBlockedReason();
    const verified = this.#isVerified();

    this.btnValidateTarget.disabled = this.#isValidating || !!blocked;

    if (this.#isValidating) {
      this.validateIconTarget.textContent  = 'hourglass_empty';
      this.validateLabelTarget.textContent = 'Probando...';
    } else if (verified) {
      this.validateIconTarget.textContent  = 'check_circle';
      this.validateLabelTarget.textContent = 'Credenciales verificadas';
    } else {
      this.validateIconTarget.textContent  = 'wifi_tethering';
      this.validateLabelTarget.textContent = 'Probar credenciales';
    }
  }

  /**
   * El botón de guardar nace deshabilitado y el motivo va en el
   * `data-tooltip` del <span> envolvente: un `<button disabled>` no emite
   * eventos de mouse (§2 y §26).
   */
  #syncSaveButton() {
    const blocked = this.#saveBlockedReason();
    const btn = this.saveBtnTarget;

    btn.disabled = !!blocked;
    btn.classList.toggle('pointer-events-none', !!blocked);
    if (this.hasSaveBtnWrapTarget) {
      this.saveBtnWrapTarget.dataset.tooltip = blocked || 'Guardar la bandeja';
    }
  }

  /**
   * El cuerpo del POST/PATCH: exactamente los campos que el formulario
   * ofrece. `Password`/`ClientSecret` en blanco NO se mandan: para el
   * servidor eso significa "conservar el guardado" — mandar la cadena vacía
   * sería pedirle que lo borre. `Active` solo al editar: el check no existe
   * al crear y `is_active` nace en `true` por el default de la columna.
   */
  #payload() {
    const useToken = this.inputUseTokenTarget.checked;
    const body = {
      MailServer: this.inputServerTarget.value.trim(),
      Email:      this.inputEmailTarget.value.trim(),
      Port:       this.inputPortTarget.value,
      UseToken:   useToken,
    };

    if (useToken) {
      body.Url       = this.inputUrlTarget.value.trim();
      body.GrantType = this.inputGrantTypeTarget.value.trim();
      body.Scope     = this.inputScopeTarget.value.trim();
      body.ClientId  = this.inputClientIdTarget.value.trim();
      if (this.inputClientSecretTarget.value) body.ClientSecret = this.inputClientSecretTarget.value;
    } else if (this.inputPasswordTarget.value) {
      body.Password = this.inputPasswordTarget.value;
    }

    if (this.#editingRecord) body.Active = this.inputActiveTarget.checked;

    return body;
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

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

  #boolBadge(value) {
    return value
      ? `<span class="material-icons text-base" style="color:#1a56db;">check_circle_outline</span>`
      : `<span class="material-icons text-base" style="color:#9ca3af;">radio_button_unchecked</span>`;
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

  // Tooltip flotante para un elemento fuera de Tabulator, que el
  // `setupTooltip()` base no cubre. Reposiciona dentro del viewport (§25).
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
      tip.style.left = `${left}px`;
      tip.style.top  = `${top}px`;
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

  // ── Fetch ─────────────────────────────────────────────────────────────────

  // Endpoints nativos: la sesión va en la cookie httpOnly, así que no se arma
  // header `Authorization` — `getApiHeaders()` pone lo único que hace falta
  // (CLAUDE.md §28). El panel de "Compañías Emisoras" sigue usando este mismo
  // helper aunque su endpoint todavía no exista del lado de Rails.
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

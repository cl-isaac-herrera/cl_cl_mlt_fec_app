/**
 * UsersController — Gestión de Usuarios (/configurations/users)
 *
 * Pantalla sin tabs: ES la lista de usuarios (perm: Configurations_Users_ListAccess).
 * Todo lo que se le concede a un usuario —rol, permisos globales y compañías— vive
 * en el panel "Gestionar accesos", que es una acción de fila.
 *
 * De los tres tabs del Angular original quedó uno:
 *   · "Completar registro" activaba usuarios pendientes de confirmar su correo.
 *     Lo resuelve el IdP: no hay contraseña propia ni correo que confirmar, y el
 *     alta nace activa. Se eliminó junto con `/configurations/users/register`.
 *   · "Asignación de compañías" era un segundo buscador de usuarios, peor que esta
 *     tabla. Es el sub-tab "Compañías" del panel de accesos.
 *
 * ── Endpoints ────────────────────────────────────────────────────────────────
 * Todos nativos, con nombrado REST (CLAUDE.md §28). La pantalla ya NO toca el .NET.
 *   - GET   /api/users?name=&email=&page=&per_page=   (listado paginado)
 *   - GET   /api/users/:id                            (detalle)
 *   - POST  /api/users                                (alta)
 *   - PATCH /api/users/:id                            (edición)
 *   - GET   /api/users/:id/companies                  (compañías del usuario)
 *   - PUT   /api/users/:id/companies                  (reemplazar sus compañías)
 *   - GET   /api/users/:id/role                       (rol en la compañía activa)
 *   - PUT   /api/users/:id/role                       (asignar rol)
 *   - GET   /api/users/:id/permissions                (permisos globales del usuario)
 *   - PUT   /api/users/:id/permissions                (reemplazar sus permisos globales)
 *   - GET   /api/permissions/catalog?type=global      (catálogo de permisos globales)
 *   - GET   /api/profile/companies                    (compañías del administrador)
 *   - GET   /api/companies/assignable                 (las que puede asignar)
 *   - GET   /api/roles                                (catálogo de roles)
 *   - POST  /api/sap_credential_validations           (probar credenciales de SAP)
 */

import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

// ── Compañías que requieren campo Tipo de OC ──────────────────────────────────
const COMPANIES_WITH_OC = new Set([186, 1206]);

// Sub-tabs del panel "Gestionar accesos". El label se usa en el diálogo de
// cambios sin guardar; el orden acá no importa.
const ACCESS_TAB_LABELS = {
  roles:     'Roles',
  global:    'Permisos globales',
  companies: 'Compañías',
};

export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    // Toolbar de la lista
    'searchName', 'searchEmail', 'createBtn', 'createBtnWrap',
    // Edit panel
    'editPanel', 'editBackdrop', 'editLoadingOverlay',
    'editFullName', 'editFullNameError',
    'editSapUser', 'editSapUserError',
    'editSapPass', 'editPassIcon',
    'editCredentialCompany',
    'editActiveCheck',
    'editTestCredBtn', 'editTestCredIcon', 'editTestCredLabel',
    'editSubmitBtn',
    // Create panel
    'createPanel', 'createBackdrop', 'createLoadingOverlay',
    'createCompanySelect',
    'createFullName', 'createFullNameError',
    'createEmail', 'createEmailError',
    'createOcTypeWrapper', 'createOcType', 'createOcTypeError',
    'createSubmitBtn',
    // Gestionar accesos panel
    'accessPanel', 'accessBackdrop', 'accessLoader', 'accessUserLabel',
    'accessTabBtn', 'accessTabContent',
    'accessRoleSearch', 'accessRoleList', 'accessRoleEmpty', 'accessRoleError',
    'accessGlobalSearch', 'accessGlobalSelectAll',
    'accessGlobalList', 'accessGlobalEmpty',
    'accessCompanySearch', 'accessCompanySelectAll',
    'accessCompanyList', 'accessCompanyEmpty',
    'accessFooterNote', 'accessSaveBtn',
  ];

  // ── Estado ──────────────────────────────────────────────────────────────────

  // La compañía activa ya no se guarda acá: los endpoints nativos la leen de la
  // session cookie, y `getApiHeaders()` arma el `cl-company-id` cuando hace falta.
  #permissions  = [];

  // Tabla principal: la gestiona TabulatorController.
  // Total real de filas que reporta el servidor. Tabulator solo conoce `last_page`,
  // así que sin esto el contador miente en la última página (CLAUDE.md §17).
  #totalRecords = 0;

  // Edit panel
  // Ya no se guarda el registro completo: el PATCH manda solo los campos
  // editables y el id va en el path, así que no hay nada que re-enviar tal cual.
  #editUserId           = null;
  #credentialsDirty     = false;
  #credentialsValidated = false;

  // Create panel
  #createDataLoaded = false;

  // Gestionar accesos (panel por usuario)
  #globalAccessAllowed   = false;   // permiso para el tab de permisos globales
  #companyAccessAllowed  = false;   // permiso para el tab de compañías
  #accessUser            = null;    // usuario seleccionado (fila de la tabla)
  #accessActiveTab       = 'roles';
  // Roles tab
  #accessRoles           = [];
  #accessInitialRolId    = null;
  #accessCurrentRolId    = null;
  #accessRoleFilter      = '';
  // Permisos globales tab
  #accessGlobalPerms     = [];      // catálogo global (cacheado entre usuarios)
  #accessGlobalInitial   = new Set();
  #accessGlobalCurrent   = new Set();
  #accessGlobalFilter    = '';
  #accessGlobalLoaded    = false;   // asignados del usuario actual ya cargados
  // Compañías tab
  #accessCompanies       = [];      // catálogo asignable (cacheado entre usuarios)
  #accessCompaniesInitial = new Set();
  #accessCompaniesCurrent = new Set();
  // Compañías que el usuario tiene asignadas pero que YO no administro: se
  // muestran marcadas y deshabilitadas (§26 — no se ocultan) y nunca viajan en el
  // guardado, porque el servidor tampoco las toca.
  #accessCompaniesLocked = [];
  #accessCompanyFilter   = '';
  #accessCompaniesLoaded = false;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  connect() {
    this.#permissions = SStore.get('Permissions') || [];
    this.#globalAccessAllowed  = this.#hasPerm('Configurations_Permissions_GlobalAccess');
    this.#companyAccessAllowed = this.#hasPerm('Configurations_Users_CompanyAssignment');

    // Sin tabs: el permiso de la pantalla es el de la lista. Antes lo gateaba el
    // `data-perm` del botón del tab; ahora se verifica acá directamente.
    if (!this.#hasPerm('Configurations_Users_ListAccess')) {
      Turbo.visit('/home');
      return;
    }

    // Botón "Nuevo Usuario": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    // El permiso es `Configurations_Users_Create` y ya no `S_RegUser`: es el que
    // exige POST /api/users y el que sigue la convención §4.4 del estándar.
    if (this.hasCreateBtnTarget) {
      if (this.#hasPerm('Configurations_Users_Create')) {
        this.#enableCreateButton();
      } else if (this.hasCreateBtnWrapTarget) {
        this.#attachTooltip(this.createBtnWrapTarget);
      }
    }

    // TabulatorController inicializa la tabla en el target "table". Ya no hace
    // falta activar un tab antes: el contenedor siempre está visible, que era el
    // motivo del orden anterior (Tabulator daba null en offsetWidth si nacía oculto).
    super.connect();   // construye la tabla y dispara la carga vía ajaxRequestFunc
  }

  // ── Configuración Tabulator ─────────────────────────────────────────────────

  getTableConfig() {
    return {
      ...super.getTableConfig(),
      data: undefined,   // evita que el [] heredado suprima la carga via ajaxRequestFunc
      height: '100%',
      maxHeight: undefined,  // anula el tope de 500px del config base
      layout: 'fitColumns',
      placeholder: 'No hay usuarios',
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 25, 50],
      // El total real lo reporta el servidor; `'rows'` lo inferiría de
      // last_page × pageSize y mentiría en la última página (CLAUDE.md §17).
      paginationCounter: (pageSize, currentRow) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: true },
      columns: this.getColumns(),
      // Paginación remota: el servidor recorta la página y devuelve el total.
      ajaxURL: '/api/users',
      ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
      ajaxResponse:    (_url, _params, response) => response,
    };
  }

  getColumns() {
    const canEdit         = this.#hasPerm('Configurations_Users_Update');
    const canManageAccess = this.#hasPerm('Configurations_Users_ManageAccess');
    return [
      { title: 'Nombre Completo',    field: 'FullName',         flexGrow: 2, minWidth: 150 },
      { title: 'Correo Electrónico', field: 'Email',            flexGrow: 2, minWidth: 180 },
      { title: 'Usuario SAP',        field: 'SapUser',          flexGrow: 1, minWidth: 110 },
      {
        title: 'Fecha de Creación',
        field: 'CreateDate',
        flexGrow: 1, minWidth: 150,
        formatter: (cell) => this.#formatDateTime(cell.getValue()),
      },
      // "Correo Confirmado" se eliminó: `users` no tiene esa columna. El correo lo
      // verifica el proveedor OIDC, no esta aplicación.
      {
        title: 'Estado',
        field: 'Active',
        width: 100, hozAlign: 'center',
        formatter: (cell) => this.#statusBadge(cell.getValue() ? 'active' : 'inactive'),
      },
      {
        title: 'Acciones',
        field: '_actions',
        width: 110, hozAlign: 'center', headerSort: false,
        // Acciones sin permiso: deshabilitadas + tooltip explicativo (CLAUDE.md §26),
        // no se ocultan. El data-tooltip lo detecta el setupTooltip base (tabla).
        formatter: () => `
          <div class="flex items-center justify-center gap-1">
            ${this.#rowActionButton({
              canDo: canEdit, type: 'edit', icon: 'edit',
              enabledTip: 'Editar', disabledTip: 'No cuenta con permisos para editar usuarios',
            })}
            ${this.#rowActionButton({
              canDo: canManageAccess, type: 'manage-access', icon: 'admin_panel_settings',
              enabledTip: 'Gestionar accesos', disabledTip: 'No cuenta con permisos para gestionar accesos',
            })}
          </div>`,
        cellClick: (e, cell) => {
          const data = cell.getRow().getData();
          if (e.target.closest('[data-action-type="edit"]')) {
            this.#onEditClick(data);
          } else if (e.target.closest('[data-action-type="manage-access"]')) {
            this.#openAccessPanel(data);
          }
        },
      },
    ];
  }

  // Botón de acción de fila: habilitado (azul) o deshabilitado (gris + tooltip
  // envuelto en <span>, porque un <button disabled> no emite eventos de mouse).
  #rowActionButton({ canDo, type, icon, enabledTip, disabledTip }) {
    if (canDo) {
      return `<button type="button" data-action-type="${type}" data-tooltip="${enabledTip}"
                class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
        <span class="material-icons text-base">${icon}</span>
      </button>`;
    }
    return `<span data-tooltip="${disabledTip}">
      <button type="button" disabled
              class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
        <span class="material-icons text-base">${icon}</span>
      </button>
    </span>`;
  }

  // ── Carga de datos ────────────────────────────────────────────────────────────

  // Trae una página del servidor. Lo invoca ajaxRequestFunc, de modo que Tabulator
  // muestra dataLoaderLoading (spinner a nivel de tabla) durante el fetch.
  async #fetchPage(params) {
    const size  = params?.size ?? 10;
    const query = new URLSearchParams({ page: params?.page ?? 1, per_page: size });

    const name  = this.searchNameTarget.value.trim();
    const email = this.searchEmailTarget.value.trim();
    if (name)  query.set('name',  name);
    if (email) query.set('email', email);

    try {
      const json  = await this.#railsFetch(`/api/users?${query}`);
      const total = json.Data?.Total ?? 0;
      const items = json.Data?.Items ?? [];

      this.#totalRecords = total;
      if (!total) showToast('No se encontraron usuarios.', 'warning');

      return { data: items, last_page: Math.max(1, Math.ceil(total / size)) };
    } catch (err) {
      this.#totalRecords = 0;
      showToast(err.message || 'Error al cargar usuarios.', 'error');
      return { data: [], last_page: 1 };
    }
  }

  // setData() recarga desde el servidor y vuelve a la página 1.
  searchUsers() {
    this.table?.setData();
  }

  #onEditClick(row) {
    if (!this.#hasPerm('Configurations_Users_Update')) {
      showToast('No cuenta con permisos para editar usuarios.', 'info');
      return;
    }
    this.#openEditPanel(row.Id);
  }

  // ── Edit panel ────────────────────────────────────────────────────────────────

  #openEditPanel(userId) {
    this.#editUserId = userId;
    this.editBackdropTarget.classList.remove('hidden');
    this.editPanelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
    this.#loadEditUser(userId);
  }

  closeEditPanel() {
    this.editPanelTarget.classList.add('translate-x-full');
    this.editBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
    this.#editUserId = null;
  }

  async #loadEditUser(userId) {
    this.editLoadingOverlayTarget.classList.remove('hidden');
    try {
      const [userRes, companiesRes] = await Promise.all([
        this.#railsFetch(`/api/users/${encodeURIComponent(userId)}`),
        this.#railsFetch(`/api/users/${encodeURIComponent(userId)}/companies`),
      ]);
      if (!userRes.Data) {
        showAlert({ type: ALERT_TYPES.ERROR, title: 'Error', message: 'No se encontró el usuario.' });
        this.closeEditPanel();
        return;
      }
      this.#fillEditForm(userRes.Data);
      this.#populateEditCompanies(companiesRes.Data || []);
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al cargar usuario', message: err.message });
      this.closeEditPanel();
    } finally {
      this.editLoadingOverlayTarget.classList.add('hidden');
    }
  }

  #fillEditForm(user) {
    this.editFullNameTarget.value       = user.FullName || '';
    this.editSapUserTarget.value        = user.SapUser  || '';
    this.editSapPassTarget.value        = '';
    this.editActiveCheckTarget.checked  = !!user.Active;
    this.#credentialsDirty     = false;
    this.#credentialsValidated = false;
    this.editFullNameErrorTarget.classList.add('hidden');
    this.editSapUserErrorTarget.classList.add('hidden');
    this.#updateEditTestCredBtn();
    this.#updateEditSubmitBtn();
  }

  #populateEditCompanies(companies) {
    this.editCredentialCompanyTarget.innerHTML = '<option value="">-- Seleccione --</option>';
    companies.forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.Id;
      opt.textContent = c.Name;
      this.editCredentialCompanyTarget.appendChild(opt);
    });
  }

  toggleEditPassVisibility() {
    const isPass = this.editSapPassTarget.type === 'password';
    this.editSapPassTarget.type = isPass ? 'text' : 'password';
    this.editPassIconTarget.textContent = isPass ? 'visibility' : 'visibility_off';
  }

  onEditSapFieldChange() {
    this.#credentialsDirty     = true;
    this.#credentialsValidated = false;
    this.#updateEditTestCredBtn();
    this.#updateEditSubmitBtn();
  }

  onEditCredentialCompanyChange() {
    this.#credentialsValidated = false;
    this.#updateEditTestCredBtn();
    this.#updateEditSubmitBtn();
  }

  #updateEditTestCredBtn() {
    const canTest = this.#credentialsDirty && !!this.editCredentialCompanyTarget.value;
    this.editTestCredBtnTarget.disabled = !canTest;
    if (this.#credentialsValidated) {
      this.editTestCredIconTarget.textContent  = 'check_circle';
      this.editTestCredLabelTarget.textContent = 'Credenciales verificadas';
      this.editTestCredBtnTarget.classList.add('text-green-600', 'border-green-400');
      this.editTestCredBtnTarget.classList.remove('text-gray-700', 'border-gray-300');
    } else {
      this.editTestCredIconTarget.textContent  = 'wifi_tethering';
      this.editTestCredLabelTarget.textContent = 'Probar credenciales';
      this.editTestCredBtnTarget.classList.remove('text-green-600', 'border-green-400');
      this.editTestCredBtnTarget.classList.add('text-gray-700', 'border-gray-300');
    }
  }

  #updateEditSubmitBtn() {
    this.editSubmitBtnTarget.disabled = this.#credentialsDirty && !this.#credentialsValidated;
  }

  async testEditCredentials() {
    const sapUser   = this.editSapUserTarget.value.trim();
    const sapPass   = this.editSapPassTarget.value;
    const companyId = parseInt(this.editCredentialCompanyTarget.value);

    if (!sapUser || !sapPass) {
      showToast('Complete Usuario y Contraseña de SAP antes de probar.', 'warning');
      return;
    }
    if (!companyId) {
      showToast('Seleccione una compañía para probar las credenciales.', 'warning');
      return;
    }

    this.editTestCredBtnTarget.disabled = true;
    this.editTestCredIconTarget.textContent  = 'hourglass_empty';
    this.editTestCredLabelTarget.textContent = 'Probando...';

    try {
      // `UserId` distingue este caso del perfil propio: son las credenciales de
      // OTRO usuario, así que el endpoint exige `Configurations_Users_Update` y
      // valida la compañía contra las asignaciones de ese usuario, no las mías.
      const res = await this.#railsFetch('/api/sap_credential_validations', {
        method: 'POST',
        body: JSON.stringify({
          UserId: this.#editUserId, SapUser: sapUser, SapPass: sapPass, CompanyId: companyId,
        }),
      });
      if (res.Data === true) {
        this.#credentialsValidated = true;
        showToast('Credenciales válidas', 'success');
      } else {
        this.#credentialsValidated = false;
        showAlert({ type: ALERT_TYPES.ERROR, title: 'Credenciales inválidas', message: res.Message || 'No se pudo conectar a SAP.' });
      }
    } catch (err) {
      this.#credentialsValidated = false;
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al validar', message: err.message });
    } finally {
      this.#updateEditTestCredBtn();
      this.#updateEditSubmitBtn();
    }
  }

  async saveEditUser() {
    if (!this.#runEditValidation()) return;

    this.editLoadingOverlayTarget.classList.remove('hidden');
    this.editSubmitBtnTarget.disabled = true;

    // Solo los campos editables: el id va en el path y `SapPass` en blanco
    // significa "no la cambies" — el servidor no la toca si no viene con valor.
    const payload = {
      FullName: this.editFullNameTarget.value.trim(),
      SapUser:  this.editSapUserTarget.value.trim(),
      SapPass:  this.editSapPassTarget.value || '',
      Active:   this.editActiveCheckTarget.checked,
    };

    try {
      await this.#railsFetch(`/api/users/${encodeURIComponent(this.#editUserId)}`, {
        method: 'PATCH', body: JSON.stringify(payload),
      });
      showToast('Usuario actualizado con éxito', 'success');
      this.closeEditPanel();
      this.table?.setData();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al actualizar usuario', message: err.message });
      this.editSubmitBtnTarget.disabled = false;
    } finally {
      this.editLoadingOverlayTarget.classList.add('hidden');
    }
  }

  #runEditValidation() {
    let valid = true;
    const check = (target, errorTarget, condition) => {
      const ok = condition();
      errorTarget.classList.toggle('hidden', ok);
      if (!ok) valid = false;
    };
    check(this.editFullNameTarget, this.editFullNameErrorTarget, () => !!this.editFullNameTarget.value.trim());
    check(this.editSapUserTarget,  this.editSapUserErrorTarget,  () => !!this.editSapUserTarget.value.trim());
    return valid;
  }

  // ── Create panel ──────────────────────────────────────────────────────────────

  openCreatePanel() {
    // Defensa en profundidad: el botón se deshabilita sin permiso, pero
    // reverificamos aquí (ver CLAUDE.md §26).
    if (!this.#hasPerm('Configurations_Users_Create')) {
      showToast('No cuenta con permisos para crear usuarios.', 'info');
      return;
    }
    this.createBackdropTarget.classList.remove('hidden');
    this.createPanelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
    this.#resetCreateForm();
    if (!this.#createDataLoaded) this.#loadCreateData();
  }

  closeCreatePanel() {
    this.createPanelTarget.classList.add('translate-x-full');
    this.createBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // Compañías del administrador: son las únicas a las que puede asignar al usuario
  // nuevo, y es lo mismo que valida POST /api/users.
  //
  // El .NET pedía además `GET /api/Group/GetGroupsByUser` para el select "Cuenta".
  // No se migró: no hay grupos en esta versión (CLAUDE.md §31), así que el campo se
  // eliminó del formulario junto con la consulta que lo alimentaba (CLAUDE.md §24).
  async #loadCreateData() {
    this.createLoadingOverlayTarget.classList.remove('hidden');
    try {
      const companiesRes = await this.#railsFetch('/api/profile/companies');
      const companies    = companiesRes.Data || [];

      this.createCompanySelectTarget.innerHTML = '';
      companies.forEach(c => {
        const opt = document.createElement('option');
        opt.value = c.Id;
        opt.textContent = c.Name;
        this.createCompanySelectTarget.appendChild(opt);
      });

      if (companies.length) this.#toggleCreateOCType(parseInt(companies[0].Id));
      this.#createDataLoaded = true;
      this.#validateCreateFormState();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al cargar datos', message: err.message });
    } finally {
      this.createLoadingOverlayTarget.classList.add('hidden');
    }
  }

  onCreateCompanyChange() {
    this.#toggleCreateOCType(parseInt(this.createCompanySelectTarget.value));
    this.#validateCreateFormState();
  }

  // Action pública: re-evalúa el estado del botón Registrar ante cambios de campos
  validateCreateForm() {
    this.#validateCreateFormState();
  }

  #toggleCreateOCType(companyId) {
    const show = COMPANIES_WITH_OC.has(companyId);
    this.createOcTypeWrapperTarget.classList.toggle('hidden', !show);
    if (!show) {
      this.createOcTypeTarget.value = '';
      this.createOcTypeErrorTarget.classList.add('hidden');
    }
  }

  #validateCreateFormState() {
    const isOCVisible = !this.createOcTypeWrapperTarget.classList.contains('hidden');
    const emailRegex  = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;

    const valid =
      this.createFullNameTarget.value.trim() &&
      emailRegex.test(this.createEmailTarget.value.trim()) &&
      this.createCompanySelectTarget.value &&
      (!isOCVisible || this.createOcTypeTarget.value);

    this.createSubmitBtnTarget.disabled = !valid;
  }

  #resetCreateForm() {
    this.createFullNameTarget.value = '';
    this.createEmailTarget.value    = '';
    this.createOcTypeTarget.value   = '';
    this.createFullNameErrorTarget.classList.add('hidden');
    this.createEmailErrorTarget.classList.add('hidden');
    this.createOcTypeErrorTarget.classList.add('hidden');
    this.createSubmitBtnTarget.disabled = true;
  }

  async createUser() {
    if (!this.#runCreateValidation()) return;

    this.createLoadingOverlayTarget.classList.remove('hidden');
    this.createSubmitBtnTarget.disabled = true;

    // Solo lo que existe como columna. El .NET recibía además `UserName`,
    // `EmailConfirmed`, `Owner`, `passwordHash`/`password` y `Active: false`: la
    // contraseña y la confirmación de correo las resuelve ahora el proveedor OIDC,
    // y el usuario nace activo (si naciera inactivo, el default_scope de
    // SoftDeletable lo escondería del listado apenas se guarda).
    const isOCVisible = !this.createOcTypeWrapperTarget.classList.contains('hidden');
    const payload = {
      CompanyId:           parseInt(this.createCompanySelectTarget.value),
      FullName:            this.createFullNameTarget.value.trim(),
      Email:               this.createEmailTarget.value.trim(),
      DocNumberPreference: isOCVisible ? (this.createOcTypeTarget.value || '') : '',
    };

    try {
      await this.#railsFetch('/api/users', { method: 'POST', body: JSON.stringify(payload) });
      showToast('Usuario registrado exitosamente', 'success');
      this.closeCreatePanel();
      this.table?.setData();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al registrar usuario', message: err.message });
      this.createSubmitBtnTarget.disabled = false;
    } finally {
      this.createLoadingOverlayTarget.classList.add('hidden');
    }
  }

  #runCreateValidation() {
    let valid = true;
    const emailRegex  = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;
    const isOCVisible = !this.createOcTypeWrapperTarget.classList.contains('hidden');

    const check = (errorTarget, condition) => {
      const ok = condition();
      errorTarget.classList.toggle('hidden', ok);
      if (!ok) valid = false;
    };

    check(this.createFullNameErrorTarget, () => !!this.createFullNameTarget.value.trim());
    check(this.createEmailErrorTarget,    () => emailRegex.test(this.createEmailTarget.value.trim()));
    if (isOCVisible) check(this.createOcTypeErrorTarget, () => !!this.createOcTypeTarget.value);

    return valid;
  }

  // ── Gestionar accesos (panel por usuario) ──────────────────────────────────────
  //
  // Tab "Roles" (nativo): un rol por usuario y compañía.
  //   - GET /api/roles                → catálogo de roles del producto
  //   - GET /api/users/:id/role       → rol del usuario en la compañía activa
  //   - PUT /api/users/:id/role       → asignar (reemplaza el rol anterior)
  // La compañía la pone la sesión: ya no viaja como parámetro, y el servidor
  // resuelve solo si el guardado es alta o cambio (el .NET exigía mandarle el id
  // de la asignación existente en `RolByUser`).
  //
  // Tab "Permisos globales" (nativo, solo si Configurations_Permissions_GlobalAccess):
  //   - GET /api/permissions/catalog?type=global → catálogo de permisos globales
  //   - GET /api/users/:id/permissions           → asignados al usuario
  //   - PUT /api/users/:id/permissions           → reemplaza el conjunto completo
  // El .NET obligaba a calcular el delta acá y mandar DOS peticiones (POST de
  // altas + DELETE de bajas) que podían quedar a medias si la segunda fallaba.
  //   - GET    /api/Permission/global-permissions       → catálogo global
  //   - GET    /api/User/global-permissions?userId=X     → asignados al usuario
  //   - POST   /api/Permission/bulk-global-permissions   → asignar
  //   - DELETE /api/Permission/bulk-global-permissions   → desasignar

  async #openAccessPanel(row) {
    if (!row) return;
    if (!this.#hasPerm('Configurations_Users_ManageAccess')) return;

    this.#accessUser = row;
    this.#accessActiveTab = 'roles';
    this.#accessGlobalFilter = '';
    this.#accessCompanyFilter = '';
    this.#accessRoleFilter = '';

    // Estado por-usuario: reiniciar al abrir para otro usuario (evita asteriscos
    // de cambios "fantasma" heredados del usuario anterior).
    this.#accessInitialRolId  = '';
    this.#accessCurrentRolId  = '';
    this.#accessGlobalInitial = new Set();
    this.#accessGlobalCurrent = new Set();
    this.#accessGlobalLoaded  = false;
    this.accessGlobalListTarget.innerHTML = '';
    this.#accessCompaniesInitial = new Set();
    this.#accessCompaniesCurrent = new Set();
    this.#accessCompaniesLocked  = [];
    this.#accessCompaniesLoaded  = false;
    this.accessCompanyListTarget.innerHTML = '';

    this.accessUserLabelTarget.textContent = row.FullName || row.Email || '';
    this.accessGlobalSearchTarget.value = '';
    this.accessCompanySearchTarget.value = '';
    this.accessRoleSearchTarget.value = '';

    // Cada tab opcional se muestra solo si el usuario actual tiene su permiso.
    this.accessTabBtnTargets.forEach(btn => {
      if (btn.dataset.accessTab === 'global') {
        btn.classList.toggle('hidden', !this.#globalAccessAllowed);
      }
      if (btn.dataset.accessTab === 'companies') {
        btn.classList.toggle('hidden', !this.#companyAccessAllowed);
      }
    });

    this.#activateAccessTab('roles');

    // Abrir panel
    this.accessBackdropTarget.classList.remove('hidden');
    this.accessPanelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';

    await this.#loadAccessRoles();
  }

  // Cierre por X o backdrop (puede ser accidental): confirma si hay cambios sin
  // guardar en CUALQUIERA de los tabs.
  async requestCloseAccessPanel() {
    if (this.#anyAccessChanges()) {
      const ok = await confirm(
        'Hay cambios sin guardar que se perderán si cierra el panel. ¿Desea cerrar de todos modos?',
        'Cambios sin guardar'
      );
      if (!ok) return;
    }
    this.closeAccessPanel();
  }

  // Cancelar es un descarte explícito del tab activo: no confirma por esos
  // cambios. Solo confirma por los OTROS tabs, que se perderían sin que el
  // usuario los estuviera mirando — y los nombra, para que sepa qué está por
  // tirar. Con tres tabs ya no alcanza con mirar "el otro".
  async cancelAccessPanel() {
    const pending = this.#tabsWithChanges().filter(name => name !== this.#accessActiveTab);

    if (pending.length) {
      const labels = pending.map(name => ACCESS_TAB_LABELS[name]).join(' y ');
      const ok = await confirm(
        `Hay cambios sin guardar en ${labels} que se perderán si cierra el panel. ¿Desea cerrar de todos modos?`,
        'Cambios sin guardar'
      );
      if (!ok) return;
    }
    this.closeAccessPanel();
  }

  closeAccessPanel() {
    this.accessPanelTarget.classList.add('translate-x-full');
    this.accessBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
    this.#accessUser = null;
  }

  switchAccessTab(event) {
    const name = event.currentTarget.dataset.accessTab;
    if (name === this.#accessActiveTab) return;
    this.#activateAccessTab(name);

    // Carga perezosa: los datos del tab se traen la primera vez que se entra,
    // una vez por usuario.
    if (name === 'global'    && !this.#accessGlobalLoaded)    this.#loadAccessGlobalPerms();
    if (name === 'companies' && !this.#accessCompaniesLoaded) this.#loadAccessCompanies();
  }

  #activateAccessTab(name) {
    this.#accessActiveTab = name;

    this.accessTabBtnTargets.forEach(btn => {
      const isActive = btn.dataset.accessTab === name;
      btn.classList.toggle('border-blue-600', isActive);
      btn.classList.toggle('text-blue-600',   isActive);
      btn.classList.toggle('border-transparent', !isActive);
      btn.classList.toggle('text-gray-500',   !isActive);
    });

    this.accessTabContentTargets.forEach(panel => {
      panel.classList.toggle('hidden', panel.dataset.accessTab !== name);
    });

    this.#updateAccessSaveBtn();
  }

  // ── Tab Roles ───────────────────────────────────────────────────────────────

  async #loadAccessRoles() {
    this.accessLoaderTarget.classList.remove('hidden');
    this.accessRoleErrorTarget.classList.add('hidden');

    try {
      const [rolesRes, assignRes] = await Promise.all([
        this.#railsFetch('/api/roles'),
        this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/role`),
      ]);

      this.#accessRoles = (rolesRes.Data || []).filter(r => r.Active && r.Name !== 'OWNER');

      // Asignación actual del usuario en la compañía activa (Data es null si no tiene)
      const assigned = assignRes.Data;
      this.#accessInitialRolId = assigned ? String(assigned.RoleId) : '';
      this.#accessCurrentRolId = this.#accessInitialRolId;

      this.#renderAccessRoleList();
      this.#updateAccessSaveBtn();
    } catch (err) {
      showToast(err.message || 'Error al cargar los roles del usuario', 'error');
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  #filteredAccessRoles() {
    const q = this.#accessRoleFilter.trim().toLowerCase();
    if (!q) return this.#accessRoles;
    return this.#accessRoles.filter(r => (r.Name || '').toLowerCase().includes(q));
  }

  #renderAccessRoleList() {
    const roles = this.#filteredAccessRoles();
    this.accessRoleListTarget.innerHTML = '';

    if (roles.length === 0) {
      this.accessRoleEmptyTarget.classList.remove('hidden');
      this.accessRoleEmptyTarget.classList.add('flex');
      return;
    }
    this.accessRoleEmptyTarget.classList.add('hidden');
    this.accessRoleEmptyTarget.classList.remove('flex');

    roles.forEach(role => {
      const checked = String(role.Id) === String(this.#accessCurrentRolId);
      const label = document.createElement('label');
      label.className =
        'flex items-center gap-3 p-3 border rounded-lg cursor-pointer transition-colors ' +
        (checked ? 'border-blue-200 bg-blue-50/50' : 'border-gray-200 hover:bg-gray-50');
      label.innerHTML = `
        <input type="radio" name="access-role" data-action="change->users#selectAccessRole" data-rol-id="${role.Id}"
               ${checked ? 'checked' : ''}
               class="h-4 w-4 border-gray-300 text-blue-600 focus:ring-blue-500 cursor-pointer">
        <div class="flex flex-col flex-1 gap-0.5 min-w-0">
          <span class="font-medium text-gray-800 text-sm">${this.#escapeHtml(role.Name)}</span>
        </div>`;
      this.accessRoleListTarget.appendChild(label);
    });
  }

  selectAccessRole(event) {
    this.#accessCurrentRolId = event.target.dataset.rolId;
    this.accessRoleErrorTarget.classList.add('hidden');
    this.#renderAccessRoleList();   // refleja la selección (un solo rol activo)
    this.#updateAccessSaveBtn();
  }

  onAccessRoleSearch(event) {
    this.#accessRoleFilter = event.target.value || '';
    this.#renderAccessRoleList();
  }

  async #saveAccessRole() {
    if (!this.#accessCurrentRolId) {
      this.accessRoleErrorTarget.classList.remove('hidden');
      return;
    }

    this.accessLoaderTarget.classList.remove('hidden');
    try {
      // PUT: el cuerpo lleva el estado final (un rol) y reemplaza el anterior.
      // Ni el id del usuario ni el de la compañía viajan en el cuerpo: uno está en
      // el path y la otra sale de la sesión.
      await this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/role`, {
        method: 'PUT',
        body: JSON.stringify({ RoleId: parseInt(this.#accessCurrentRolId) }),
      });
      showToast('Asignación realizada correctamente.', 'success');
      this.#accessInitialRolId = this.#accessCurrentRolId;
      this.#updateAccessSaveBtn();
      this.#afterAccessSave();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar la asignación', message: err.message });
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  // ── Tab Permisos globales ─────────────────────────────────────────────────────

  async #loadAccessGlobalPerms() {
    this.accessLoaderTarget.classList.remove('hidden');

    try {
      const requests = [
        this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/permissions`),
      ];
      // El catálogo es el mismo para todos: se pide una sola vez por sesión.
      if (this.#accessGlobalPerms.length === 0) {
        requests.push(this.#railsFetch('/api/permissions/catalog?type=global'));
      }

      const [assignedRes, catalogRes] = await Promise.all(requests);

      if (catalogRes) {
        if (catalogRes.Data && catalogRes.Data.length) {
          this.#accessGlobalPerms = catalogRes.Data;
        } else {
          showToast(catalogRes.Message || 'No hay permisos globales disponibles', 'warning');
        }
      }

      const assignedIds = (assignedRes.Data && Array.isArray(assignedRes.Data))
        ? assignedRes.Data.map(p => p.Id)
        : [];
      this.#accessGlobalInitial = new Set(assignedIds);
      this.#accessGlobalCurrent = new Set(assignedIds);
      this.#accessGlobalLoaded  = true;

      this.#renderAccessGlobalList();
      this.#updateAccessSaveBtn();
    } catch (err) {
      showToast(err.message || 'Error al cargar los permisos globales', 'error');
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  #filteredAccessGlobal() {
    const q = this.#accessGlobalFilter.trim().toLowerCase();
    if (!q) return this.#accessGlobalPerms;
    return this.#accessGlobalPerms.filter(p =>
      (p.Description || '').toLowerCase().includes(q) ||
      (p.Name || '').toLowerCase().includes(q));
  }

  #renderAccessGlobalList() {
    const perms = this.#filteredAccessGlobal();
    this.accessGlobalListTarget.innerHTML = '';

    if (perms.length === 0) {
      this.accessGlobalEmptyTarget.classList.remove('hidden');
      this.accessGlobalEmptyTarget.classList.add('flex');
      return;
    }
    this.accessGlobalEmptyTarget.classList.add('hidden');
    this.accessGlobalEmptyTarget.classList.remove('flex');

    perms.forEach(perm => {
      const checked = this.#accessGlobalCurrent.has(perm.Id);
      const label = document.createElement('label');
      label.className =
        'flex items-center gap-3 p-3 border rounded-lg cursor-pointer transition-colors ' +
        (checked ? 'border-blue-200 bg-blue-50/50' : 'border-gray-200 hover:bg-gray-50');
      label.innerHTML = `
        <input type="checkbox" data-action="change->users#toggleAccessGlobalPerm" data-perm-id="${perm.Id}"
               ${checked ? 'checked' : ''}
               class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 cursor-pointer">
        <div class="flex flex-col flex-1 gap-0.5 min-w-0">
          <span class="font-medium text-gray-800 text-sm">${this.#escapeHtml(perm.Description)}</span>
          ${perm.Name ? `<span class="text-[11px] text-gray-400 font-mono truncate">${this.#escapeHtml(perm.Name)}</span>` : ''}
        </div>`;
      this.accessGlobalListTarget.appendChild(label);
    });
  }

  toggleAccessGlobalPerm(event) {
    const id = parseInt(event.target.dataset.permId, 10);
    if (Number.isNaN(id)) return;

    if (event.target.checked) this.#accessGlobalCurrent.add(id);
    else this.#accessGlobalCurrent.delete(id);

    const label = event.target.closest('label');
    if (label) {
      const checked = event.target.checked;
      label.className =
        'flex items-center gap-3 p-3 border rounded-lg cursor-pointer transition-colors ' +
        (checked ? 'border-blue-200 bg-blue-50/50' : 'border-gray-200 hover:bg-gray-50');
    }

    this.#updateAccessSaveBtn();
  }

  onAccessGlobalSearch(event) {
    this.#accessGlobalFilter = event.target.value || '';
    this.#renderAccessGlobalList();
    this.#updateAccessSaveBtn();
  }

  toggleAccessGlobalAll(event) {
    const select = event.target.checked;
    this.#filteredAccessGlobal().forEach(perm => {
      if (select) this.#accessGlobalCurrent.add(perm.Id);
      else this.#accessGlobalCurrent.delete(perm.Id);
    });
    this.#renderAccessGlobalList();
    this.#updateAccessSaveBtn();
  }

  async #saveAccessGlobal() {
    if (!this.#tabHasChanges('global')) {
      showToast('No hay cambios para guardar', 'info');
      return;
    }

    this.accessLoaderTarget.classList.remove('hidden');
    try {
      // Un solo PUT con el conjunto final: el servidor calcula el delta en una
      // transacción. Antes eran dos peticiones (altas y bajas) y si la segunda
      // fallaba el usuario quedaba con la mitad de los cambios aplicados.
      await this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/permissions`, {
        method: 'PUT',
        body: JSON.stringify({ PermissionIds: [...this.#accessGlobalCurrent] }),
      });

      showToast('Permisos globales actualizados exitosamente', 'success');
      this.#accessGlobalInitial = new Set(this.#accessGlobalCurrent);
      this.#updateAccessSaveBtn();
      this.#afterAccessSave();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al aplicar cambios', message: err.message });
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  // ── Tab Compañías ─────────────────────────────────────────────────────────────
  //
  // Reemplaza al tab "Asignación de compañías", que era un segundo buscador de
  // usuarios peor que la tabla de la Lista. Acá el usuario ya está elegido.
  //
  //   - GET /api/companies/assignable → las que YO puedo asignar (no todas)
  //   - GET /api/users/:id/companies  → las que el usuario tiene hoy
  //   - PUT /api/users/:id/companies  → reemplaza el conjunto
  //
  // El catálogo se cachea entre usuarios; las asignadas no, obviamente.

  async #loadAccessCompanies() {
    this.accessLoaderTarget.classList.remove('hidden');

    try {
      const requests = [
        this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/companies`),
      ];
      if (this.#accessCompanies.length === 0) {
        requests.push(this.#railsFetch('/api/companies/assignable'));
      }

      const [assignedRes, catalogRes] = await Promise.all(requests);

      if (catalogRes) {
        this.#accessCompanies = catalogRes.Data || [];
        if (this.#accessCompanies.length === 0) {
          showToast('No hay compañías que usted pueda asignar.', 'warning');
        }
      }

      // Las asignadas que NO están en el catálogo son de compañías fuera de mi
      // alcance: se muestran marcadas y deshabilitadas para que el administrador
      // sepa que existen (§26: no se ocultan, se explica por qué no se tocan) y
      // quedan fuera del conjunto editable.
      const assigned    = assignedRes.Data || [];
      const catalogIds  = new Set(this.#accessCompanies.map(c => c.Id));
      const editableIds = assigned.filter(c => catalogIds.has(c.Id)).map(c => c.Id);

      this.#accessCompaniesLocked  = assigned.filter(c => !catalogIds.has(c.Id));
      this.#accessCompaniesInitial = new Set(editableIds);
      this.#accessCompaniesCurrent = new Set(editableIds);
      this.#accessCompaniesLoaded  = true;

      this.#renderAccessCompanyList();
      this.#updateAccessSaveBtn();
    } catch (err) {
      showToast(err.message || 'Error al cargar las compañías del usuario', 'error');
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  #filteredAccessCompanies() {
    const q = this.#accessCompanyFilter.trim().toLowerCase();
    if (!q) return this.#accessCompanies;
    return this.#accessCompanies.filter(c => (c.Name || '').toLowerCase().includes(q));
  }

  #renderAccessCompanyList() {
    const companies = this.#filteredAccessCompanies();
    const locked    = this.#accessCompanyFilter.trim()
      ? this.#accessCompaniesLocked.filter(c =>
          (c.Name || '').toLowerCase().includes(this.#accessCompanyFilter.trim().toLowerCase()))
      : this.#accessCompaniesLocked;

    this.accessCompanyListTarget.innerHTML = '';

    if (companies.length === 0 && locked.length === 0) {
      this.accessCompanyEmptyTarget.classList.remove('hidden');
      this.accessCompanyEmptyTarget.classList.add('flex');
      return;
    }
    this.accessCompanyEmptyTarget.classList.add('hidden');
    this.accessCompanyEmptyTarget.classList.remove('flex');

    companies.forEach(company => {
      const checked = this.#accessCompaniesCurrent.has(company.Id);
      const label = document.createElement('label');
      label.className = this.#accessRowClass(checked);
      label.innerHTML = `
        <input type="checkbox" data-action="change->users#toggleAccessCompany" data-company-id="${company.Id}"
               ${checked ? 'checked' : ''}
               class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 cursor-pointer">
        <div class="flex flex-col flex-1 gap-0.5 min-w-0">
          <span class="font-medium text-gray-800 text-sm">${this.#escapeHtml(company.Name)}</span>
        </div>`;
      this.accessCompanyListTarget.appendChild(label);
    });

    // Asignadas fuera de mi alcance: visibles, marcadas y bloqueadas.
    locked.forEach(company => {
      const div = document.createElement('div');
      div.className = 'flex items-center gap-3 p-3 border border-gray-200 rounded-lg bg-gray-50';
      div.setAttribute('data-tooltip',
        'Ya tiene acceso a esta compañía, pero usted no la administra y no puede quitársela');
      div.innerHTML = `
        <input type="checkbox" checked disabled
               class="h-4 w-4 rounded border-gray-300 text-gray-400 cursor-not-allowed">
        <div class="flex flex-col flex-1 gap-0.5 min-w-0">
          <span class="font-medium text-gray-500 text-sm">${this.#escapeHtml(company.Name)}</span>
          <span class="text-[11px] text-gray-400">Fuera de su alcance</span>
        </div>
        <span class="material-icons text-base text-gray-400">lock</span>`;
      this.accessCompanyListTarget.appendChild(div);
    });
  }

  #accessRowClass(checked) {
    return 'flex items-center gap-3 p-3 border rounded-lg cursor-pointer transition-colors ' +
      (checked ? 'border-blue-200 bg-blue-50/50' : 'border-gray-200 hover:bg-gray-50');
  }

  toggleAccessCompany(event) {
    const id = parseInt(event.target.dataset.companyId, 10);
    if (Number.isNaN(id)) return;

    if (event.target.checked) this.#accessCompaniesCurrent.add(id);
    else this.#accessCompaniesCurrent.delete(id);

    const label = event.target.closest('label');
    if (label) label.className = this.#accessRowClass(event.target.checked);

    this.#updateAccessSaveBtn();
  }

  onAccessCompanySearch(event) {
    this.#accessCompanyFilter = event.target.value || '';
    this.#renderAccessCompanyList();
    this.#updateAccessSaveBtn();
  }

  toggleAccessCompanyAll(event) {
    const select = event.target.checked;
    this.#filteredAccessCompanies().forEach(company => {
      if (select) this.#accessCompaniesCurrent.add(company.Id);
      else this.#accessCompaniesCurrent.delete(company.Id);
    });
    this.#renderAccessCompanyList();
    this.#updateAccessSaveBtn();
  }

  async #saveAccessCompanies() {
    if (!this.#tabHasChanges('companies')) {
      showToast('No hay cambios para guardar', 'info');
      return;
    }

    this.accessLoaderTarget.classList.remove('hidden');
    try {
      // Solo viaja lo editable: las compañías fuera de alcance no van en el cuerpo
      // y el servidor tampoco las revoca — si viajaran, las rechazaría con 403.
      await this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/companies`, {
        method: 'PUT',
        body: JSON.stringify({ CompanyIds: [...this.#accessCompaniesCurrent] }),
      });

      showToast('Compañías actualizadas exitosamente', 'success');
      this.#accessCompaniesInitial = new Set(this.#accessCompaniesCurrent);
      this.#updateAccessSaveBtn();
      this.#afterAccessSave();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al aplicar cambios', message: err.message });
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  // ── Guardar (despacha según el tab activo) ────────────────────────────────────

  saveAccess() {
    if (this.#accessActiveTab === 'roles')     return this.#saveAccessRole();
    if (this.#accessActiveTab === 'companies') return this.#saveAccessCompanies();
    return this.#saveAccessGlobal();
  }

  // Cambios pendientes de un tab específico ('roles' | 'global' | 'companies').
  #tabHasChanges(name) {
    if (name === 'roles') {
      return !!this.#accessCurrentRolId && this.#accessCurrentRolId !== this.#accessInitialRolId;
    }
    if (name === 'global') {
      return this.#setsDiffer(this.#accessGlobalInitial, this.#accessGlobalCurrent);
    }
    if (name === 'companies') {
      return this.#setsDiffer(this.#accessCompaniesInitial, this.#accessCompaniesCurrent);
    }
    return false;
  }

  // Dos conjuntos difieren si cambió el tamaño o si alguno del segundo no está en
  // el primero: con tamaños iguales e inclusión en un sentido, son idénticos.
  #setsDiffer(initial, current) {
    if (initial.size !== current.size) return true;
    for (const id of current) {
      if (!initial.has(id)) return true;
    }
    return false;
  }

  #tabsWithChanges() {
    return Object.keys(ACCESS_TAB_LABELS).filter(name => this.#tabHasChanges(name));
  }

  #anyAccessChanges() {
    return this.#tabsWithChanges().length > 0;
  }

  // Tras guardar un tab: cierra el panel solo si NINGÚN otro tab quedó con
  // cambios pendientes. Si los tiene, lo deja abierto — el asterisco rojo ya
  // indica cuál. Antes recibía "el otro tab"; con tres hay que mirarlos todos, y
  // el tab recién guardado ya no tiene cambios, así que basta con preguntar por
  // los que quedan.
  #afterAccessSave() {
    if (!this.#anyAccessChanges()) {
      this.closeAccessPanel();
    }
  }

  // Marca con asterisco rojo los tabs con cambios sin guardar.
  #updateAccessTabIndicators() {
    this.accessTabBtnTargets.forEach(btn => {
      const dot = btn.querySelector('[data-access-dot]');
      if (dot) dot.classList.toggle('hidden', !this.#tabHasChanges(btn.dataset.accessTab));
    });
  }

  #updateAccessSaveBtn() {
    // Estado del "Seleccionar todos/todas" de cada tab: marcado solo si TODO lo
    // visible bajo el filtro actual está seleccionado.
    if (this.hasAccessGlobalSelectAllTarget) {
      const visible = this.#filteredAccessGlobal();
      this.accessGlobalSelectAllTarget.checked =
        visible.length > 0 && visible.every(p => this.#accessGlobalCurrent.has(p.Id));
    }
    if (this.hasAccessCompanySelectAllTarget) {
      const visible = this.#filteredAccessCompanies();
      this.accessCompanySelectAllTarget.checked =
        visible.length > 0 && visible.every(c => this.#accessCompaniesCurrent.has(c.Id));
    }

    this.#updateAccessFooterNote();
    this.accessSaveBtnTarget.disabled = !this.#tabHasChanges(this.#accessActiveTab);
    this.#updateAccessTabIndicators();
  }

  // El pie cuenta lo del tab activo. En Roles no hay nada que contar (es uno solo).
  #updateAccessFooterNote() {
    if (!this.hasAccessFooterNoteTarget) return;

    const locked  = this.#accessCompaniesLocked.length;
    const lockedNote = locked ? ` (+${locked} fuera de su alcance)` : '';

    const notes = {
      roles:     '',
      global:    `${this.#accessGlobalCurrent.size} permiso(s) global(es) asignado(s)`,
      companies: `${this.#accessCompaniesCurrent.size} compañía(s) asignada(s)${lockedNote}`,
    };
    this.accessFooterNoteTarget.textContent = notes[this.#accessActiveTab] ?? '';
  }

  #escapeHtml(str) {
    const div = document.createElement('div');
    div.appendChild(document.createTextNode(str || ''));
    return div.innerHTML;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Nuevo Usuario" (nace deshabilitado/gris con tooltip de
  // "sin permisos" en su <span> envolvente). Ver CLAUDE.md §26.
  #enableCreateButton() {
    const btn = this.createBtnTarget;
    btn.disabled = false;
    btn.classList.remove('bg-gray-300', 'text-gray-500', 'cursor-not-allowed', 'pointer-events-none');
    btn.classList.add('bg-blue-600', 'text-white', 'hover:bg-blue-700');
    if (this.hasCreateBtnWrapTarget) this.createBtnWrapTarget.removeAttribute('data-tooltip');
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

  #statusBadge(status, customLabel = null) {
    const map = {
      active:    { bg: '#e8f5ee', color: '#3a7d52', label: 'Activo'    },
      inactive:  { bg: '#fdecea', color: '#c0392b', label: 'Inactivo'  },
      confirmed: { bg: '#e8f0fe', color: '#1a56db', label: 'Sí'        },
      pending:   { bg: '#fffbeb', color: '#b45309', label: 'No'        },
    };
    const cfg = map[status] ?? { bg: '#f3f4f6', color: '#4b5563', label: status };
    const label = customLabel ?? cfg.label;
    return `<span style="background-color:${cfg.bg}; color:${cfg.color};"
               class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${label}
    </span>`;
  }

  #formatDateTime(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  // ── fetch ─────────────────────────────────────────────────────────────────────
  //
  // Un solo cliente: la pantalla ya no habla con el .NET. Los endpoints nativos
  // autentican con la session cookie, así que NO llevan `Authorization` ni el
  // header `API` del proxy (CLAUDE.md §28). El `#apiFetch` que armaba el Bearer se
  // borró con el último tab que lo usaba.

  async #railsFetch(url, options = {}) {
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

    // Las escrituras pueden responder 204 sin cuerpo: parsear a ciegas revienta
    // con "Unexpected end of JSON input" aunque la operación haya salido bien.
    const hasBody = response.status !== 204 &&
                    response.headers.get('content-length') !== '0' &&
                    response.headers.get('content-type')?.includes('application/json');
    return hasBody ? response.json() : { Message: null };
  }

}

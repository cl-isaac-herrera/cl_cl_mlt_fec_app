/**
 * UsersController — Gestión de Usuarios (/configurations/users)
 *
 * Pantalla sin tabs: ES la lista de usuarios (perm: Configurations_Users_ListAccess).
 * Todo lo que se le concede a un usuario —rol de instalación y compañías (cada
 * una con su rol de compañía)— vive en el panel "Gestionar accesos", que es una
 * acción de fila (docs/PLAN-ROLES-POR-ALCANCE.md).
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
 *   - GET   /api/users/:id/companies                  (compañías del usuario, con su rol)
 *   - PUT   /api/users/:id/companies                  (reemplazar sus compañías y roles)
 *   - GET   /api/users/:id/installation_role           (rol de instalación del usuario)
 *   - PUT   /api/users/:id/installation_role           (asignar/quitar el rol de instalación)
 *   - GET   /api/roles?scope=installation|company     (catálogo de roles por alcance)
 *   - GET   /api/profile/companies                    (compañías del administrador)
 *   - GET   /api/companies/assignable                 (las que puede asignar)
 *   - POST  /api/sap_credential_validations           (probar credenciales de SAP)
 */

import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

// Sub-tabs del panel "Gestionar accesos". El label se usa en el diálogo de
// cambios sin guardar; el orden acá no importa.
const ACCESS_TAB_LABELS = {
  installation_role: 'Rol de instalación',
  companies:          'Compañías',
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
    'createSubmitBtn',
    // Gestionar accesos panel
    'accessPanel', 'accessBackdrop', 'accessLoader', 'accessUserLabel',
    'accessTabBtn', 'accessTabContent',
    'accessRoleSelect',
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
  #companyAccessAllowed  = false;   // permiso para el tab de compañías
  #accessUser            = null;    // usuario seleccionado (fila de la tabla)
  #accessActiveTab       = 'installation_role';
  // Rol de instalación
  #accessRoles           = [];      // catálogo de roles de instalación (scope=installation)
  #accessInitialRolId    = '';
  #accessCurrentRolId    = '';
  // Compañías tab — cada compañía marcada lleva su rol de compañía.
  #accessCompanies        = [];             // catálogo asignable (cacheado entre usuarios)
  #accessCompanyRoles     = [];             // catálogo de roles de compañía (cacheado entre usuarios)
  #accessCompaniesInitial = new Map();      // CompanyId -> RoleId
  #accessCompaniesCurrent = new Map();      // CompanyId -> RoleId
  // Compañías que el usuario tiene asignadas pero que YO no administro: se
  // muestran marcadas y deshabilitadas (§26 — no se ocultan) y nunca viajan en el
  // guardado, porque el servidor tampoco las toca.
  #accessCompaniesLocked = [];
  #accessCompanyFilter   = '';
  #accessCompaniesLoaded = false;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  connect() {
    this.#permissions = SStore.get('Permissions') || [];
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
      if (!total) Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'No se encontraron usuarios.', showConfirmButton: false, timer: 3000, timerProgressBar: true });

      return { data: items, last_page: Math.max(1, Math.ceil(total / size)) };
    } catch (err) {
      this.#totalRecords = 0;
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message || 'Error al cargar usuarios.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      return { data: [], last_page: 1 };
    }
  }

  // setData() recarga desde el servidor y vuelve a la página 1.
  searchUsers() {
    this.table?.setData();
  }

  #onEditClick(row) {
    if (!this.#hasPerm('Configurations_Users_Update')) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'info', title: 'No cuenta con permisos para editar usuarios.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
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
        Swal.fire({ icon: 'error', title: 'Error', text: 'No se encontró el usuario.', confirmButtonText: 'Aceptar' });
        this.closeEditPanel();
        return;
      }
      this.#fillEditForm(userRes.Data);
      this.#populateEditCompanies(companiesRes.Data || []);
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al cargar usuario', text: err.message, confirmButtonText: 'Aceptar' });
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
      Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'Complete Usuario y Contraseña de SAP antes de probar.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      return;
    }
    if (!companyId) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'Seleccione una compañía para probar las credenciales.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
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
        Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Credenciales válidas', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      } else {
        this.#credentialsValidated = false;
        Swal.fire({ icon: 'error', title: 'Credenciales inválidas', text: res.Message || 'No se pudo conectar a SAP.', confirmButtonText: 'Aceptar' });
      }
    } catch (err) {
      this.#credentialsValidated = false;
      Swal.fire({ icon: 'error', title: 'Error al validar', text: err.message, confirmButtonText: 'Aceptar' });
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
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Usuario actualizado con éxito', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      this.closeEditPanel();
      this.table?.setData();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al actualizar usuario', text: err.message, confirmButtonText: 'Aceptar' });
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
      Swal.fire({ toast: true, position: 'top-end', icon: 'info', title: 'No cuenta con permisos para crear usuarios.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
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

      this.#createDataLoaded = true;
      this.#validateCreateFormState();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al cargar datos', text: err.message, confirmButtonText: 'Aceptar' });
    } finally {
      this.createLoadingOverlayTarget.classList.add('hidden');
    }
  }

  onCreateCompanyChange() {
    this.#validateCreateFormState();
  }

  // Action pública: re-evalúa el estado del botón Registrar ante cambios de campos
  validateCreateForm() {
    this.#validateCreateFormState();
  }

  #validateCreateFormState() {
    const emailRegex = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;

    const valid =
      this.createFullNameTarget.value.trim() &&
      emailRegex.test(this.createEmailTarget.value.trim()) &&
      this.createCompanySelectTarget.value;

    this.createSubmitBtnTarget.disabled = !valid;
  }

  #resetCreateForm() {
    this.createFullNameTarget.value = '';
    this.createEmailTarget.value    = '';
    this.createFullNameErrorTarget.classList.add('hidden');
    this.createEmailErrorTarget.classList.add('hidden');
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
    const payload = {
      CompanyId: parseInt(this.createCompanySelectTarget.value),
      FullName:  this.createFullNameTarget.value.trim(),
      Email:     this.createEmailTarget.value.trim(),
    };

    try {
      await this.#railsFetch('/api/users', { method: 'POST', body: JSON.stringify(payload) });
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Usuario registrado exitosamente', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      this.closeCreatePanel();
      this.table?.setData();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al registrar usuario', text: err.message, confirmButtonText: 'Aceptar' });
      this.createSubmitBtnTarget.disabled = false;
    } finally {
      this.createLoadingOverlayTarget.classList.add('hidden');
    }
  }

  #runCreateValidation() {
    let valid = true;
    const emailRegex = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;

    const check = (errorTarget, condition) => {
      const ok = condition();
      errorTarget.classList.toggle('hidden', ok);
      if (!ok) valid = false;
    };

    check(this.createFullNameErrorTarget, () => !!this.createFullNameTarget.value.trim());
    check(this.createEmailErrorTarget,    () => emailRegex.test(this.createEmailTarget.value.trim()));

    return valid;
  }

  // ── Gestionar accesos (panel por usuario) ──────────────────────────────────────
  //
  // Tab "Rol de instalación" (nativo): un rol de instalación por usuario, sin
  // depender de ninguna compañía activa.
  //   - GET /api/roles?scope=installation           → catálogo de roles de instalación
  //   - GET /api/users/:id/installation_role         → rol de instalación del usuario (o null)
  //   - PUT /api/users/:id/installation_role         → asignar (RoleId) o quitar (RoleId: null)
  //
  // Tab "Compañías" (nativo, solo si Configurations_Users_CompanyAssignment):
  //   - GET /api/companies/assignable       → catálogo de compañías que YO puedo asignar
  //   - GET /api/roles?scope=company          → catálogo de roles de compañía
  //   - GET /api/users/:id/companies         → compañías del usuario, cada una con su RoleId
  //   - PUT /api/users/:id/companies         → reemplaza el conjunto completo (con su rol)

  async #openAccessPanel(row) {
    if (!row) return;
    if (!this.#hasPerm('Configurations_Users_ManageAccess')) return;

    this.#accessUser = row;
    this.#accessActiveTab = 'installation_role';
    this.#accessCompanyFilter = '';

    // Estado por-usuario: reiniciar al abrir para otro usuario (evita asteriscos
    // de cambios "fantasma" heredados del usuario anterior).
    this.#accessInitialRolId  = '';
    this.#accessCurrentRolId  = '';
    this.#accessCompaniesInitial = new Map();
    this.#accessCompaniesCurrent = new Map();
    this.#accessCompaniesLocked  = [];
    this.#accessCompaniesLoaded  = false;
    this.accessCompanyListTarget.innerHTML = '';

    this.accessUserLabelTarget.textContent = row.FullName || row.Email || '';
    this.accessCompanySearchTarget.value = '';

    // El tab "Compañías" se muestra solo si el usuario actual tiene su permiso.
    // "Rol de instalación" siempre está visible: abrir el panel ya exige
    // Configurations_Users_ManageAccess.
    this.accessTabBtnTargets.forEach(btn => {
      if (btn.dataset.accessTab === 'companies') {
        btn.classList.toggle('hidden', !this.#companyAccessAllowed);
      }
    });

    this.#activateAccessTab('installation_role');

    // Abrir panel
    this.accessBackdropTarget.classList.remove('hidden');
    this.accessPanelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';

    await this.#loadAccessInstallationRole();
  }

  // Cierre por X o backdrop (puede ser accidental): confirma si hay cambios sin
  // guardar en CUALQUIERA de los tabs.
  async requestCloseAccessPanel() {
    if (this.#anyAccessChanges()) {
      const { isConfirmed } = await Swal.fire({
        title: 'Cambios sin guardar',
        text: 'Hay cambios sin guardar que se perderán si cierra el panel. ¿Desea cerrar de todos modos?',
        icon: 'warning',
        showCancelButton: true,
        confirmButtonText: 'Confirmar',
        cancelButtonText: 'Cancelar'
      });
      if (!isConfirmed) return;
    }
    this.closeAccessPanel();
  }

  // Cancelar es un descarte explícito del tab activo: no confirma por esos
  // cambios. Solo confirma por los OTROS tabs, que se perderían sin que el
  // usuario los estuviera mirando — y los nombra, para que sepa qué está por
  // tirar.
  async cancelAccessPanel() {
    const pending = this.#tabsWithChanges().filter(name => name !== this.#accessActiveTab);

    if (pending.length) {
      const labels = pending.map(name => ACCESS_TAB_LABELS[name]).join(' y ');
      const { isConfirmed } = await Swal.fire({
        title: 'Cambios sin guardar',
        text: `Hay cambios sin guardar en ${labels} que se perderán si cierra el panel. ¿Desea cerrar de todos modos?`,
        icon: 'warning',
        showCancelButton: true,
        confirmButtonText: 'Confirmar',
        cancelButtonText: 'Cancelar'
      });
      if (!isConfirmed) return;
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

  // ── Tab Rol de instalación ────────────────────────────────────────────────────

  async #loadAccessInstallationRole() {
    this.accessLoaderTarget.classList.remove('hidden');

    try {
      const [rolesRes, assignRes] = await Promise.all([
        this.#railsFetch('/api/roles?scope=installation'),
        this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/installation_role`),
      ]);

      this.#accessRoles = (rolesRes.Data || []).filter(r => r.Active && r.Name !== 'OWNER');

      // `Data` es `null` si el usuario no tiene rol de instalación asignado —
      // es un estado válido, no un error.
      const assigned = assignRes.Data;
      this.#accessInitialRolId = assigned ? String(assigned.RoleId) : '';
      this.#accessCurrentRolId = this.#accessInitialRolId;

      this.#renderAccessRoleSelect();
      this.#updateAccessSaveBtn();
    } catch (err) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message || 'Error al cargar el rol de instalación', showConfirmButton: false, timer: 3000, timerProgressBar: true });
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  #renderAccessRoleSelect() {
    const select = this.accessRoleSelectTarget;
    select.innerHTML = '<option value="">-- Sin rol --</option>' +
      this.#accessRoles.map(role => `<option value="${role.Id}">${this.#escapeHtml(role.Name)}</option>`).join('');
    select.value = this.#accessCurrentRolId || '';
  }

  onAccessInstallationRoleChange(event) {
    this.#accessCurrentRolId = event.target.value;
    this.#updateAccessSaveBtn();
  }

  async #saveAccessRole() {
    this.accessLoaderTarget.classList.remove('hidden');
    try {
      // `RoleId: null` quita el rol de instalación — acá "sin rol" es un estado
      // legítimo, a diferencia del rol de compañía que siempre exige uno.
      const roleId = this.#accessCurrentRolId ? parseInt(this.#accessCurrentRolId, 10) : null;
      await this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/installation_role`, {
        method: 'PUT',
        body: JSON.stringify({ RoleId: roleId }),
      });
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Asignación realizada correctamente.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      this.#accessInitialRolId = this.#accessCurrentRolId;
      this.#updateAccessSaveBtn();
      this.#afterAccessSave();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al guardar la asignación', text: err.message, confirmButtonText: 'Aceptar' });
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  // ── Tab Compañías ─────────────────────────────────────────────────────────────
  //
  // Reemplaza al tab "Asignación de compañías", que era un segundo buscador de
  // usuarios peor que la tabla de la Lista. Acá el usuario ya está elegido, y
  // cada compañía marcada lleva su propio rol de compañía
  // (docs/PLAN-ROLES-POR-ALCANCE.md).
  //
  //   - GET /api/companies/assignable → las que YO puedo asignar (no todas)
  //   - GET /api/roles?scope=company    → catálogo de roles de compañía
  //   - GET /api/users/:id/companies   → las que el usuario tiene hoy, con su rol
  //   - PUT /api/users/:id/companies   → reemplaza el conjunto { CompanyId, RoleId }
  //
  // Los catálogos se cachean entre usuarios; las asignadas no, obviamente.

  async #loadAccessCompanies() {
    this.accessLoaderTarget.classList.remove('hidden');

    try {
      // `Promise.all` acepta valores no-promesa: si el catálogo ya está
      // cacheado, el `null` resuelve al instante y el destructuring de abajo
      // simplemente no lo usa.
      const assignedPromise = this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/companies`);
      const catalogPromise  = this.#accessCompanies.length === 0
        ? this.#railsFetch('/api/companies/assignable')
        : null;
      const rolesPromise    = this.#accessCompanyRoles.length === 0
        ? this.#railsFetch('/api/roles?scope=company')
        : null;

      const [assignedRes, catalogRes, rolesRes] = await Promise.all([assignedPromise, catalogPromise, rolesPromise]);

      if (catalogRes) {
        this.#accessCompanies = catalogRes.Data || [];
        if (this.#accessCompanies.length === 0) {
          Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'No hay compañías que usted pueda asignar.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
        }
      }

      if (rolesRes) {
        this.#accessCompanyRoles = (rolesRes.Data || []).filter(r => r.Active && r.Name !== 'OWNER');
        if (this.#accessCompanyRoles.length === 0) {
          Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'No hay roles de compañía disponibles.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
        }
      }

      // Las asignadas que NO están en el catálogo son de compañías fuera de mi
      // alcance: se muestran marcadas y deshabilitadas para que el administrador
      // sepa que existen (§26: no se ocultan, se explica por qué no se tocan) y
      // quedan fuera del conjunto editable.
      const assigned   = assignedRes.Data || [];
      const catalogIds = new Set(this.#accessCompanies.map(c => c.Id));
      const editable   = assigned.filter(c => catalogIds.has(c.Id));

      this.#accessCompaniesLocked  = assigned.filter(c => !catalogIds.has(c.Id));
      this.#accessCompaniesInitial = new Map(editable.map(c => [c.Id, c.RoleId]));
      this.#accessCompaniesCurrent = new Map(this.#accessCompaniesInitial);
      this.#accessCompaniesLoaded  = true;

      this.#renderAccessCompanyList();
      this.#updateAccessSaveBtn();
    } catch (err) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message || 'Error al cargar las compañías del usuario', showConfirmButton: false, timer: 3000, timerProgressBar: true });
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
    const q = this.#accessCompanyFilter.trim().toLowerCase();
    const locked = q
      ? this.#accessCompaniesLocked.filter(c => (c.Name || '').toLowerCase().includes(q))
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
      const roleId  = this.#accessCompaniesCurrent.get(company.Id) ?? '';
      const row = document.createElement('div');
      row.className = this.#accessRowClass(checked);
      row.innerHTML = `
        <input type="checkbox" data-action="change->users#toggleAccessCompany" data-company-id="${company.Id}"
               ${checked ? 'checked' : ''}
               class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 cursor-pointer">
        <div class="flex flex-col flex-1 gap-0.5 min-w-0">
          <span class="font-medium text-gray-800 text-sm">${this.#escapeHtml(company.Name)}</span>
        </div>
        <select data-action="change->users#onAccessCompanyRoleChange" data-company-id="${company.Id}"
                ${checked ? '' : 'disabled'}
                class="border border-gray-300 rounded-lg px-2 py-1 text-xs bg-white focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100 disabled:text-gray-400 flex-shrink-0">
          <option value="">-- Rol --</option>
          ${this.#accessCompanyRoles.map(r => `<option value="${r.Id}" ${String(r.Id) === String(roleId) ? 'selected' : ''}>${this.#escapeHtml(r.Name)}</option>`).join('')}
        </select>`;
      this.accessCompanyListTarget.appendChild(row);
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
          <span class="text-[11px] text-gray-400">Fuera de su alcance${company.RoleName ? ` · ${this.#escapeHtml(company.RoleName)}` : ''}</span>
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

    if (event.target.checked) {
      // Si ya tenía un rol asignado (estaba marcada y se desmarcó sin guardar),
      // se restaura ese rol; si es la primera vez, nace sin rol y el usuario
      // tiene que elegir uno antes de poder guardar.
      this.#accessCompaniesCurrent.set(id, this.#accessCompaniesInitial.get(id) ?? null);
    } else {
      this.#accessCompaniesCurrent.delete(id);
    }

    // El checkbox cambia si el <select> queda habilitado: re-renderizar toda
    // la fila es más simple que mutar el `disabled` a mano.
    this.#renderAccessCompanyList();
    this.#updateAccessSaveBtn();
  }

  onAccessCompanyRoleChange(event) {
    const id = parseInt(event.target.dataset.companyId, 10);
    if (Number.isNaN(id)) return;
    if (!this.#accessCompaniesCurrent.has(id)) return;

    const roleId = event.target.value ? parseInt(event.target.value, 10) : null;
    this.#accessCompaniesCurrent.set(id, roleId);
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
      if (select) {
        this.#accessCompaniesCurrent.set(company.Id, this.#accessCompaniesInitial.get(company.Id) ?? null);
      } else {
        this.#accessCompaniesCurrent.delete(company.Id);
      }
    });
    this.#renderAccessCompanyList();
    this.#updateAccessSaveBtn();
  }

  // Todas las compañías marcadas tienen que tener un rol elegido antes de poder
  // guardar (§22 patrón de "botón deshabilitado hasta completar").
  #accessCompaniesReady() {
    for (const roleId of this.#accessCompaniesCurrent.values()) {
      if (roleId === null || roleId === undefined || roleId === '') return false;
    }
    return true;
  }

  async #saveAccessCompanies() {
    if (!this.#tabHasChanges('companies')) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'info', title: 'No hay cambios para guardar', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      return;
    }
    if (!this.#accessCompaniesReady()) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'Seleccione un rol de compañía para cada compañía marcada.', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      return;
    }

    this.accessLoaderTarget.classList.remove('hidden');
    try {
      // Solo viaja lo editable: las compañías fuera de alcance no van en el cuerpo
      // y el servidor tampoco las revoca — si viajaran, las rechazaría con 403.
      const assignments = [...this.#accessCompaniesCurrent.entries()]
        .map(([CompanyId, RoleId]) => ({ CompanyId, RoleId }));

      await this.#railsFetch(`/api/users/${encodeURIComponent(this.#accessUser.Id)}/companies`, {
        method: 'PUT',
        body: JSON.stringify({ Assignments: assignments }),
      });

      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Compañías actualizadas exitosamente', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      this.#accessCompaniesInitial = new Map(this.#accessCompaniesCurrent);
      this.#updateAccessSaveBtn();
      this.#afterAccessSave();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al aplicar cambios', text: err.message, confirmButtonText: 'Aceptar' });
    } finally {
      this.accessLoaderTarget.classList.add('hidden');
    }
  }

  // ── Guardar (despacha según el tab activo) ────────────────────────────────────

  saveAccess() {
    if (this.#accessActiveTab === 'installation_role') return this.#saveAccessRole();
    return this.#saveAccessCompanies();
  }

  // Cambios pendientes de un tab específico ('installation_role' | 'companies').
  #tabHasChanges(name) {
    if (name === 'installation_role') {
      return this.#accessCurrentRolId !== this.#accessInitialRolId;
    }
    if (name === 'companies') {
      return this.#mapsDiffer(this.#accessCompaniesInitial, this.#accessCompaniesCurrent);
    }
    return false;
  }

  // Dos mapas (CompanyId -> RoleId) difieren si cambió el tamaño o si alguna
  // llave del actual no está en el inicial, o su valor cambió.
  #mapsDiffer(initial, current) {
    if (initial.size !== current.size) return true;
    for (const [id, roleId] of current) {
      if (!initial.has(id) || initial.get(id) !== roleId) return true;
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
  // indica cuál.
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
    // Estado del "Seleccionar todas" del tab Compañías: marcado solo si TODO lo
    // visible bajo el filtro actual está seleccionado.
    if (this.hasAccessCompanySelectAllTarget) {
      const visible = this.#filteredAccessCompanies();
      this.accessCompanySelectAllTarget.checked =
        visible.length > 0 && visible.every(c => this.#accessCompaniesCurrent.has(c.Id));
    }

    this.#updateAccessFooterNote();

    // Guardar además exige que, en Compañías, cada fila marcada tenga su rol
    // elegido — sin eso el PUT se rechazaría igual, pero el botón lo anticipa.
    let canSave = this.#tabHasChanges(this.#accessActiveTab);
    if (this.#accessActiveTab === 'companies' && canSave) {
      canSave = this.#accessCompaniesReady();
    }
    this.accessSaveBtnTarget.disabled = !canSave;
    this.#updateAccessTabIndicators();
  }

  // El pie cuenta lo del tab activo. En Rol de instalación no hay nada que contar.
  #updateAccessFooterNote() {
    if (!this.hasAccessFooterNoteTarget) return;

    const locked  = this.#accessCompaniesLocked.length;
    const lockedNote = locked ? ` (+${locked} fuera de su alcance)` : '';

    const notes = {
      installation_role: '',
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

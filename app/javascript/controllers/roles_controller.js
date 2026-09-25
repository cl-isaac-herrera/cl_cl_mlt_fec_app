import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { getApiHeaders } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * RolesController — Gestión de roles y de sus permisos (Tabulator + paneles).
 *
 * Endpoints nativos de Rails (ver CLAUDE.md §28):
 *   - GET   /api/roles?scope=installation|company     (listado, filtrado por alcance)
 *   - POST  /api/roles                                (crear; exige Scope en el body)
 *   - PATCH /api/roles/:id                             (renombrar)
 *   - GET   /api/roles/:id/permissions                (permisos vigentes del rol)
 *   - PUT   /api/roles/:id/permissions                (reasignación completa)
 *   - GET   /api/permissions/catalog?scope=…          (catálogo, filtrado por el alcance del rol)
 *
 * Un rol solo puede contener permisos de su propio alcance
 * (docs/PLAN-ROLES-POR-ALCANCE.md), así que la pantalla separa dos tabs: "Roles
 * de instalación" y "Roles de compañía". El tab activo decide con qué `Scope`
 * se filtra el listado, con qué `Scope` se crea un rol nuevo, y — al abrir el
 * panel de permisos de un rol — con qué `Scope` se pide el catálogo (el del rol
 * que se está editando, no necesariamente el del tab activo en ese momento).
 *
 * ⚠️ El listado ya NO se filtra por compañía. En el esquema propio `roles` no
 * tiene `company_id`: el rol de compañía se asigna vía `users_by_companies`.
 * El .NET pedía `GetRoles?companyId=N`; ver TODOS.md → Seguridad.
 *
 * Layout full-height: la tabla ocupa toda la altura del contenedor con scroll interno
 * de filas y paginador al pie (height: "100%").
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'scopeTabBtn',
    'panel',
    'panelBackdrop',
    'nameInput',
    'nameError',
    'submitBtn',
    'submitIcon',
    'submitLabel',
    // Panel de permisos del rol
    'permsPanel',
    'permsBackdrop',
    'permsTitle',
    'permsLoader',
    'permsList',
    'permsEmpty',
    'permsSearch',
    'permsSelectAll',
    'permsCount',
    'permsSaveBtn',
  ];

  static values = { ...TabulatorController.values };

  // ── Estado interno ─────────────────────────────────────────────────────────

  /** Lista de roles cargados desde la API */
  #roles = [];

  /** Rol en edición (null si es creación) */
  #editingRole = null;

  /**
   * Alcance del tab activo ('installation' | 'company'): decide qué lista
   * trae el índice y con qué Scope se crea un rol nuevo — el usuario no elige
   * el alcance a mano, lo determina el tab que tenía abierto (CLAUDE.md §20/§21).
   */
  #activeScope = 'installation';

  // ── Estado del panel de permisos ────────────────────────────────────────────

  /** Rol cuyos permisos se gestionan en el panel */
  #permsRole = null;

  /**
   * Catálogo de permisos, cacheado POR ALCANCE: un rol de instalación y uno de
   * compañía nunca comparten catálogo (`RolePermission` rechaza un permiso de
   * otro alcance), así que un solo array global mostraría el catálogo
   * equivocado al alternar entre roles de distinto alcance.
   */
  #permsCatalogByScope = { installation: [], company: [] };

  /** Catálogo del rol actualmente abierto en el panel (apunta al de su alcance) */
  #allPerms = [];

  /** Ids asignados al rol al abrir el panel (estado inicial) */
  #initialPermIds = new Set();

  /** Ids asignados según la edición actual del usuario */
  #currentPermIds = new Set();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    this.#activateScopeTab(this.#activeScope);
    // Sin companyId: los roles no se filtran por compañía (ver la nota de arriba).
    super.connect();   // construye la tabla y dispara ajaxRequestFunc automáticamente
  }

  // ── Tabs de alcance ───────────────────────────────────────────────────────

  switchScopeTab(event) {
    const scope = event.currentTarget.dataset.scope;
    if (scope === this.#activeScope) return;
    this.#activeScope = scope;
    this.#activateScopeTab(scope);
    this.table?.setData();   // recarga vía ajaxRequestFunc con el nuevo scope
  }

  #activateScopeTab(scope) {
    this.scopeTabBtnTargets.forEach(btn => {
      const isActive = btn.dataset.scope === scope;
      btn.classList.toggle('border-blue-600', isActive);
      btn.classList.toggle('text-blue-600',   isActive);
      btn.classList.toggle('border-transparent', !isActive);
      btn.classList.toggle('text-gray-500',   !isActive);
    });
  }

  // ── Configuración Tabulator ─────────────────────────────────────────────────

  getTableConfig() {
    return {
      ...super.getTableConfig(),
      data: undefined,       // evita que el [] heredado suprima la carga vía ajaxRequestFunc
      height: '100%',        // llena el contenedor; scroll interno solo si se requiere
      maxHeight: undefined,  // anula el tope de 500px del config base
      movableRows: false,
      layout: 'fitColumns',
      placeholder: 'No hay roles registrados',
      pagination: true,
      paginationSize: 10,
      paginationSizeSelector: [10, 20, 50, 100],
      paginationCounter: 'rows',
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      columns: this.getColumns(),
      ajaxURL: '/api/roles',
      ajaxRequestFunc: () => this.#loadRoles(),
      ajaxResponse:    (_url, _params, response) => response,
    };
  }

  getColumns() {
    return [
      { title: 'Nombre del Rol', field: 'Name', widthGrow: 3 },
      {
        title: 'Estado',
        field: 'Active',
        width: 130,
        hozAlign: 'left',
        formatter: (cell) => this.#statusBadge(cell.getValue()),
      },
      {
        title: 'Acciones',
        field: 'Id',
        width: 140,
        hozAlign: 'center',
        formatter: () => this.#rowActions(),
        cellClick: (e, cell) => {
          const data = cell.getRow().getData();
          if (e.target.closest('[data-action-type="edit"]')) {
            this.#editRole(data);
          } else if (e.target.closest('[data-action-type="perms"]')) {
            this.#openPermsPanel(data);
          }
        },
      },
    ];
  }

  // ── API ───────────────────────────────────────────────────────────────────

  // Invocado por ajaxRequestFunc — Tabulator muestra dataLoaderLoading automáticamente.
  // Filtra siempre por el alcance del tab activo: no hay un listado "sin filtrar".
  async #loadRoles() {
    const json = await this.#apiFetch(`/api/roles?scope=${encodeURIComponent(this.#activeScope)}`);

    if (!json.Data) {
      Swal.fire({
        icon: 'error',
        title: 'Se produjo un error al obtener los roles',
        text: json.Message || 'Error desconocido',
        confirmButtonText: 'Aceptar'
      });
      return [];
    }

    this.#roles = json.Data;
    return json.Data;
  }

  // El payload pierde `GroupId` (no existe la tabla `groups` en la base propia),
  // `Active` (no se edita desde esta pantalla) y `companyId` (los roles no son
  // por compañía). Queda el nombre y el `Scope` del tab activo — el usuario no
  // lo elige a mano, el servidor lo exige y lo rechaza con 422 si falta.
  async #createRole(name) {
    return this.#apiFetch('/api/roles', {
      method: 'POST',
      body: JSON.stringify({ Name: name, Scope: this.#activeScope }),
    });
  }

  // El id va en el path, no en el cuerpo como pedía el .NET (CLAUDE.md §28).
  async #updateRole(id, name) {
    return this.#apiFetch(`/api/roles/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ Name: name }),
    });
  }

  // ── Render helpers (formatters Tabulator) ───────────────────────────────────

  #statusBadge(active) {
    return active
      ? `<span style="background-color:#e8f5ee; color:#3a7d52;" class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">Activo</span>`
      : `<span style="background-color:#fdecea; color:#c0392b;" class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">Inactivo</span>`;
  }

  #rowActions() {
    return `
      <div class="flex items-center justify-center gap-1">
        <button type="button" data-action-type="edit" data-tooltip="Editar"
                class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
          <span class="material-icons text-base">edit</span>
        </button>
        <button type="button" data-action-type="perms" data-tooltip="Permisos"
                class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
          <span class="material-icons text-base">verified_user</span>
        </button>
      </div>`;
  }

  // ── Handlers de eventos ───────────────────────────────────────────────────

  openCreateModal() {
    this.#editingRole = null;
    this.#resetModal();
    this.submitIconTarget.textContent  = 'check';
    this.submitLabelTarget.textContent = 'Crear';
    this.#openPanel();
  }

  #editRole(role) {
    if (!role) return;

    if (role.Name === 'OWNER') {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'Este rol no permite su edición',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    this.#editingRole = role;
    this.#resetModal();
    this.nameInputTarget.value         = role.Name;
    this.submitBtnTarget.disabled      = false;
    this.submitIconTarget.textContent  = 'autorenew';
    this.submitLabelTarget.textContent = 'Modificar';
    this.#openPanel();
  }

  onNameInput() {
    const hasValue = this.nameInputTarget.value.trim().length > 0;
    this.submitBtnTarget.disabled = !hasValue;
    this.nameErrorTarget.classList.toggle('hidden', hasValue);
  }

  async onSubmit() {
    const name = this.nameInputTarget.value.trim();
    if (!name) return;

    try {
      if (this.#editingRole) {
        await this.#updateRole(this.#editingRole.Id, name);
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Se actualizó el rol correctamente!!!',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      } else {
        await this.#createRole(name);
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'success',
          title: 'Se creó el rol correctamente!!!',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      }
      this.closeModal();
      this.table?.setData();   // recarga via ajaxRequestFunc (loader a nivel de tabla)
    } catch (err) {
      const action = this.#editingRole ? 'actualizar' : 'registrar';
      Swal.fire({
        icon: 'error',
        title: `Se produjo un error al ${action} el rol`,
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
    }
  }

  closeModal() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // ── Helpers de UI ─────────────────────────────────────────────────────────

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
    this.nameInputTarget.focus();
  }

  #resetModal() {
    this.nameInputTarget.value    = '';
    this.submitBtnTarget.disabled = true;
    this.nameErrorTarget.classList.add('hidden');
  }

  // ── Panel de permisos del rol ───────────────────────────────────────────────

  /** Texto del filtro de búsqueda de permisos */
  #permsFilter = '';

  async #openPermsPanel(role) {
    if (!role) return;

    if (role.Name === 'OWNER') {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'Este rol administra todos los permisos y no es editable',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    this.#permsRole = role;
    this.#permsFilter = '';
    this.#initialPermIds = new Set();
    this.#currentPermIds = new Set();

    this.permsTitleTarget.textContent = role.Name;
    this.permsSearchTarget.value = '';
    this.permsListTarget.innerHTML = '';
    this.permsEmptyTarget.classList.add('hidden');
    this.permsSaveBtnTarget.disabled = true;

    this.permsBackdropTarget.classList.remove('hidden');
    this.permsPanelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';

    await this.#loadRolePerms();
  }

  // Cierre solicitado por el usuario (X, backdrop, Cancelar): confirma si hay
  // cambios sin guardar.
  async requestClosePermsPanel() {
    if (this.#hasPermsChanges()) {
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
    this.closePermsPanel();
  }

  closePermsPanel() {
    this.permsPanelTarget.classList.add('translate-x-full');
    this.permsBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
    this.#permsRole = null;
  }

  async #loadRolePerms() {
    this.permsLoaderTarget.classList.remove('hidden');

    // El catálogo se filtra por el ALCANCE DEL ROL que se está editando, no por
    // el tab activo en la tabla: un rol solo puede contener permisos de su
    // propio alcance (`RolePermission`), así que mostrar el catálogo completo
    // dejaría marcar un permiso que el PUT rechazaría con 422.
    const scope = this.#permsRole.Scope;

    try {
      // El catálogo de cada alcance se carga una sola vez y se reutiliza entre
      // roles del mismo alcance.
      const requests = [
        this.#apiFetch(`/api/roles/${this.#permsRole.Id}/permissions`),
      ];
      if (!this.#permsCatalogByScope[scope]?.length) {
        requests.push(this.#apiFetch(`/api/permissions/catalog?scope=${encodeURIComponent(scope)}`));
      }

      const [byRolRes, allPermsRes] = await Promise.all(requests);

      if (allPermsRes) {
        if (allPermsRes.Data && allPermsRes.Data.length) {
          this.#permsCatalogByScope[scope] = allPermsRes.Data;
        } else {
          Swal.fire({
            toast: true,
            position: 'top-end',
            icon: 'warning',
            title: allPermsRes.Message || 'No se pudieron cargar los permisos',
            showConfirmButton: false,
            timer: 3000,
            timerProgressBar: true
          });
        }
      }

      this.#allPerms = this.#permsCatalogByScope[scope] || [];

      // El endpoint devuelve los registros de permiso, no una lista de ids como
      // el .NET: acá interesan solo los ids para marcar los checkboxes.
      const assigned = Array.isArray(byRolRes.Data) ? byRolRes.Data : [];
      const assignedIds = assigned.map((p) => p.Id);
      this.#initialPermIds = new Set(assignedIds);
      this.#currentPermIds = new Set(assignedIds);

      this.#renderPermsList();
      this.#updatePermsUI();
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al cargar los permisos del rol',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
    } finally {
      this.permsLoaderTarget.classList.add('hidden');
    }
  }

  #filteredPerms() {
    const q = this.#permsFilter.trim().toLowerCase();
    if (!q) return this.#allPerms;
    return this.#allPerms.filter((p) =>
      (p.Description || '').toLowerCase().includes(q) ||
      (p.Name || '').toLowerCase().includes(q));
  }

  #renderPermsList() {
    const perms = this.#filteredPerms();
    this.permsListTarget.innerHTML = '';

    if (perms.length === 0) {
      this.permsEmptyTarget.classList.remove('hidden');
      this.permsEmptyTarget.classList.add('flex');
      return;
    }
    this.permsEmptyTarget.classList.add('hidden');
    this.permsEmptyTarget.classList.remove('flex');

    perms.forEach((perm) => {
      const checked = this.#currentPermIds.has(perm.Id);
      const label = document.createElement('label');
      label.dataset.testid = `role-perm-${perm.Id}`;
      label.className =
        'flex items-center gap-3 p-3 border rounded-lg cursor-pointer transition-colors ' +
        (checked ? 'border-blue-200 bg-blue-50/50' : 'border-gray-200 hover:bg-gray-50');

      label.innerHTML = `
        <input type="checkbox" data-action="change->roles#togglePerm" data-perm-id="${perm.Id}"
               ${checked ? 'checked' : ''}
               class="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 cursor-pointer">
        <div class="flex flex-col flex-1 gap-0.5 min-w-0">
          <span class="font-medium text-gray-800 text-sm">${this.#escapeHtml(perm.Description)}</span>
          ${perm.Name ? `<span class="text-[11px] text-gray-400 font-mono truncate">${this.#escapeHtml(perm.Name)}</span>` : ''}
        </div>`;

      this.permsListTarget.appendChild(label);
    });
  }

  togglePerm(event) {
    const id = parseInt(event.target.dataset.permId, 10);
    if (Number.isNaN(id)) return;

    if (event.target.checked) {
      this.#currentPermIds.add(id);
    } else {
      this.#currentPermIds.delete(id);
    }

    // Refleja el estilo de la fila sin re-renderizar toda la lista
    const label = event.target.closest('label');
    if (label) {
      const checked = event.target.checked;
      label.className =
        'flex items-center gap-3 p-3 border rounded-lg cursor-pointer transition-colors ' +
        (checked ? 'border-blue-200 bg-blue-50/50' : 'border-gray-200 hover:bg-gray-50');
    }

    this.#updatePermsUI();
  }

  onPermsSearch(event) {
    this.#permsFilter = event.target.value || '';
    this.#renderPermsList();
    this.#updatePermsUI();
  }

  toggleSelectAllPerms(event) {
    const select = event.target.checked;
    // Aplica solo a los permisos visibles según el filtro actual
    this.#filteredPerms().forEach((perm) => {
      if (select) this.#currentPermIds.add(perm.Id);
      else this.#currentPermIds.delete(perm.Id);
    });
    this.#renderPermsList();
    this.#updatePermsUI();
  }

  #updatePermsUI() {
    // Contador de asignados (sobre el total, no solo lo filtrado)
    this.permsCountTarget.textContent = this.#currentPermIds.size;

    // Estado del checkbox "Seleccionar todos" según lo visible
    const visible = this.#filteredPerms();
    const allVisibleChecked = visible.length > 0 && visible.every((p) => this.#currentPermIds.has(p.Id));
    this.permsSelectAllTarget.checked = allVisibleChecked;

    // Habilitar Guardar solo si hay cambios respecto al estado inicial
    this.permsSaveBtnTarget.disabled = !this.#hasPermsChanges();
  }

  #hasPermsChanges() {
    if (this.#initialPermIds.size !== this.#currentPermIds.size) return true;
    for (const id of this.#currentPermIds) {
      if (!this.#initialPermIds.has(id)) return true;
    }
    return false;
  }

  async savePermissions() {
    if (!this.#permsRole || !this.#hasPermsChanges()) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'info',
        title: 'No hay cambios para guardar',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    this.permsLoaderTarget.classList.remove('hidden');

    try {
      // Reemplazo completo: el servidor revoca lo que no venga en la lista. Por
      // eso es PUT y basta con los ids — el .NET pedía armar a mano las filas
      // de la tabla puente ({ Id, PermId, RolId, Active }).
      await this.#apiFetch(`/api/roles/${this.#permsRole.Id}/permissions`, {
        method: 'PUT',
        body: JSON.stringify({ PermissionIds: Array.from(this.#currentPermIds) }),
      });

      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Permisos asignados con éxito!!!',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.#initialPermIds = new Set(this.#currentPermIds);
      this.#updatePermsUI();
      this.closePermsPanel();
    } catch (err) {
      Swal.fire({
        icon: 'error',
        title: 'Error al guardar los permisos',
        text: err.message || 'Error desconocido',
        confirmButtonText: 'Aceptar'
      });
    } finally {
      this.permsLoaderTarget.classList.add('hidden');
    }
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

    return response.json();
  }

  #escapeHtml(str) {
    const div = document.createElement('div');
    div.appendChild(document.createTextNode(str || ''));
    return div.innerHTML;
  }
}

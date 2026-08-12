import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * RolesController — Gestión de roles y de sus permisos (Tabulator + paneles).
 *
 * Endpoints nativos de Rails (ver CLAUDE.md §28):
 *   - GET   /api/roles                        (listado)
 *   - POST  /api/roles                        (crear)
 *   - PATCH /api/roles/:id                    (renombrar)
 *   - GET   /api/roles/:id/permissions        (permisos vigentes del rol)
 *   - PUT   /api/roles/:id/permissions        (reasignación completa)
 *   - GET   /api/permissions/catalog          (catálogo para pintar los checkboxes)
 *
 * ⚠️ El listado ya NO se filtra por compañía. En el esquema propio `roles` no
 * tiene `company_id`: el rol existe para todo el producto y la compañía vive en
 * `user_roles`. El .NET pedía `GetRoles?companyId=N`; ver TODOS.md → Seguridad.
 *
 * Layout full-height: la tabla ocupa toda la altura del contenedor con scroll interno
 * de filas y paginador al pie (height: "100%").
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
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

  // ── Estado del panel de permisos ────────────────────────────────────────────

  /** Rol cuyos permisos se gestionan en el panel */
  #permsRole = null;

  /** Catálogo completo de permisos (cargado una vez y reutilizado) */
  #allPerms = [];

  /** Ids asignados al rol al abrir el panel (estado inicial) */
  #initialPermIds = new Set();

  /** Ids asignados según la edición actual del usuario */
  #currentPermIds = new Set();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    // Sin companyId: los roles no se filtran por compañía (ver la nota de arriba).
    super.connect();   // construye la tabla y dispara ajaxRequestFunc automáticamente
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
  async #loadRoles() {
    const json = await this.#apiFetch('/api/roles');

    if (!json.Data) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Se produjo un error al obtener los roles', message: json.Message || 'Error desconocido' });
      return [];
    }

    this.#roles = json.Data;
    return json.Data;
  }

  // El payload pierde `GroupId` (no existe la tabla `groups` en la base propia),
  // `Active` (no se edita desde esta pantalla) y `companyId` (los roles no son
  // por compañía). Queda solo el nombre, que es lo único que el formulario pide.
  async #createRole(name) {
    return this.#apiFetch('/api/roles', {
      method: 'POST',
      body: JSON.stringify({ Name: name }),
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
      showToast('Este rol no permite su edición', 'info');
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
        showToast('Se actualizó el rol correctamente!!!', 'success');
      } else {
        await this.#createRole(name);
        showToast('Se creó el rol correctamente!!!', 'success');
      }
      this.closeModal();
      this.table?.setData();   // recarga via ajaxRequestFunc (loader a nivel de tabla)
    } catch (err) {
      const action = this.#editingRole ? 'actualizar' : 'registrar';
      showAlert({ type: ALERT_TYPES.ERROR, title: `Se produjo un error al ${action} el rol`, message: err.message });
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
      showToast('Este rol administra todos los permisos y no es editable', 'info');
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
      const ok = await confirm(
        'Hay cambios sin guardar que se perderán si cierra el panel. ¿Desea cerrar de todos modos?',
        'Cambios sin guardar'
      );
      if (!ok) return;
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

    try {
      // El catálogo de permisos se carga una sola vez y se reutiliza entre roles.
      const requests = [
        this.#apiFetch(`/api/roles/${this.#permsRole.Id}/permissions`),
      ];
      if (this.#allPerms.length === 0) {
        requests.push(this.#apiFetch('/api/permissions/catalog'));
      }

      const [byRolRes, allPermsRes] = await Promise.all(requests);

      if (allPermsRes) {
        if (allPermsRes.Data && allPermsRes.Data.length) {
          this.#allPerms = allPermsRes.Data;
        } else {
          showToast(allPermsRes.Message || 'No se pudieron cargar los permisos', 'warning');
        }
      }

      // El endpoint devuelve los registros de permiso, no una lista de ids como
      // el .NET: acá interesan solo los ids para marcar los checkboxes.
      const assigned = Array.isArray(byRolRes.Data) ? byRolRes.Data : [];
      const assignedIds = assigned.map((p) => p.Id);
      this.#initialPermIds = new Set(assignedIds);
      this.#currentPermIds = new Set(assignedIds);

      this.#renderPermsList();
      this.#updatePermsUI();
    } catch (err) {
      showToast(err.message || 'Error al cargar los permisos del rol', 'error');
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
      showToast('No hay cambios para guardar', 'info');
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

      showToast('Permisos asignados con éxito!!!', 'success');
      this.#initialPermIds = new Set(this.#currentPermIds);
      this.#updatePermsUI();
      this.closePermsPanel();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar los permisos', message: err.message || 'Error desconocido' });
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

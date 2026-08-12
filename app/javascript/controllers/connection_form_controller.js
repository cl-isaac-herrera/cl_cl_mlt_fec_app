import { Controller } from '@hotwired/stimulus';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES } from 'vendor/clavisco/alerts';

/**
 * ConnectionFormController — Crear / Editar una conexión SAP.
 *
 * Formulario de navegación (`/configurations/connections/new` y `/:id/edit`),
 * orfanado por el panel lateral del listado pero todavía ruteado. Se mantiene en
 * sync con las otras dos copias del formulario (ver CLAUDE.md §22).
 *
 * Modos:
 *   - create: connectionIdValue = 0  → botón "Crear"
 *   - edit:   connectionIdValue > 0  → botón "Actualizar", carga data vía GET
 *
 * Endpoints nativos de Rails (ver CLAUDE.md §28):
 *   - GET   /api/connections/:id   (modo edición)
 *   - POST  /api/connections       (crear)
 *   - PATCH /api/connections/:id   (actualizar)
 */
export default class extends Controller {
  static values = { connectionId: Number };

  static targets = [
    'name',  'nameError',
    'slUrl', 'slUrlError',
    'slType',
    'submitBtn', 'submitIcon', 'submitLabel',
  ];

  // ── Estado interno ─────────────────────────────────────────────────────────

  #isEditMode  = false;
  #permissions = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    this.#onLoad();
  }

  // ── Inicialización ────────────────────────────────────────────────────────

  #onLoad() {
    const perms = SStore.get('Permissions');
    this.#permissions = Array.isArray(perms) ? perms : [];

    this.#isEditMode = this.connectionIdValue > 0;

    if (this.#isEditMode) {
      this.#initEditMode();
    } else {
      this.#initCreateMode();
    }
  }

  async #initCreateMode() {
    if (!this.#hasPerm('Configurations_Connections_Create')) {
      await showAlert({ type: ALERT_TYPES.WARNING, title: 'Acceso Denegado', message: 'No cuenta con permisos para crear conexiones.' });
      Turbo.visit('/configurations/connections');
      return;
    }

    this.submitIconTarget.textContent  = 'check';
    this.submitLabelTarget.textContent = 'Crear';
    this.refreshSubmitState();
  }

  async #initEditMode() {
    if (!this.#hasPerm('Configurations_Connections_Update')) {
      await showAlert({ type: ALERT_TYPES.WARNING, title: 'Acceso Denegado', message: 'No cuenta con permisos para actualizar conexiones.' });
      Turbo.visit('/configurations/connections');
      return;
    }

    this.submitIconTarget.textContent  = 'autorenew';
    this.submitLabelTarget.textContent = 'Actualizar';

    this.#loadConnection();
  }

  // ── API ───────────────────────────────────────────────────────────────────

  async #loadConnection() {
    try {
      const json = await this.#apiFetch(`/api/connections/${this.connectionIdValue}`);

      if (!json.Data) {
        showToast(json.Message || 'No se encontró la conexión', 'error');
        setTimeout(() => Turbo.visit('/configurations/connections'), 2000);
        return;
      }

      this.#fillForm(json.Data);
    } catch (err) {
      showToast(err.message || 'Error al cargar la conexión', 'error');
      setTimeout(() => Turbo.visit('/configurations/connections'), 2000);
    }
  }

  #fillForm(conn) {
    this.nameTarget.value  = conn.Name  ?? '';
    this.slUrlTarget.value = conn.SlUrl ?? '';
    this.#applySelectValue(this.slTypeTarget, conn.SlType ?? '');
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

  // ── Handlers de eventos ───────────────────────────────────────────────────

  /** Habilita el botón de guardar solo cuando todos los campos requeridos están completos. */
  refreshSubmitState() {
    this.submitBtnTarget.disabled = !this.#isFormValid();
  }

  /** ¿Están completos los campos obligatorios? El motor (SlType) es opcional. */
  #isFormValid() {
    return this.nameTarget.value.trim() !== '' && this.#isSlUrlValid();
  }

  /** La URL tiene que ser http(s), igual que valida el modelo del servidor. */
  #isSlUrlValid() {
    return /^https?:\/\//i.test(this.slUrlTarget.value.trim());
  }

  async save() {
    if (!this.#validate()) return;

    const payload  = this.#buildPayload();
    const isCreate = !this.#isEditMode;

    try {
      // Crear va a la colección; actualizar, al recurso: el id viaja en el path,
      // no en el cuerpo como pedía el .NET (CLAUDE.md §28).
      const json = await this.#apiFetch(
        isCreate ? '/api/connections' : `/api/connections/${this.connectionIdValue}`,
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

      const msg = isCreate ? 'Conexión creada con éxito' : 'Conexión actualizada con éxito';
      showToast(msg, 'success');

      setTimeout(() => Turbo.visit('/configurations/connections'), 1500);
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error', message: err.message });
    }
  }

  cancel() {
    Turbo.visit('/configurations/connections');
  }

  // ── Validación ────────────────────────────────────────────────────────────

  #validate() {
    const nameEmpty  = !this.nameTarget.value.trim();
    const urlInvalid = !this.#isSlUrlValid();

    this.nameErrorTarget.classList.toggle('hidden', !nameEmpty);
    this.slUrlErrorTarget.classList.toggle('hidden', !urlInvalid);

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
      Name:   this.nameTarget.value.trim(),
      SlUrl:  this.slUrlTarget.value.trim(),
      SlType: this.slTypeTarget.value.trim(),
    };
  }

  // ── Helpers generales ─────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
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
}

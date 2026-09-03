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
 *   - GET   /api/connections/:id           (modo edición)
 *   - POST  /api/connections               (crear)
 *   - PATCH /api/connections/:id           (actualizar)
 *   - POST  /api/sap_license_validations   (comprobar credenciales)
 */
export default class extends Controller {
  static values = { connectionId: Number };

  static targets = [
    'name',  'nameError',
    'slUrl', 'slUrlError',
    'sapLicense', 'sapLicensePassword', 'sapLicensePasswordHint', 'eyeIcon',
    'companyDb', 'companyDbList',
    'btnTestLicense', 'testLicenseIcon', 'testLicenseLabel',
    'submitBtn', 'submitIcon', 'submitLabel',
  ];

  // ── Estado interno ─────────────────────────────────────────────────────────

  #isEditMode  = false;
  #permissions = [];

  // Prueba de credenciales de licencia. La contraseña es de solo escritura: el
  // servidor no la devuelve, solo si existe (`HasSapLicensePassword`).
  #hasStoredPassword = false;
  #isTesting = false;
  /** Huella de los valores con los que la prueba salió bien (ver #licenseFingerprint). */
  #verifiedFingerprint = null;

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
    this.nameTarget.value       = conn.Name       ?? '';
    this.slUrlTarget.value      = conn.SlUrl      ?? '';
    this.sapLicenseTarget.value = conn.SapLicense ?? '';

    // La contraseña no viene nunca — solo si existe. El campo queda en blanco y
    // el hint explica que dejarlo así la conserva.
    this.#hasStoredPassword = conn.HasSapLicensePassword === true;
    this.sapLicensePasswordHintTarget.classList.toggle('hidden', !this.#hasStoredPassword);

    this.#fillSapDbOptions(conn.SapDbs ?? []);

    this.refreshSubmitState();
  }

  /**
   * Sugerencias para la base de la prueba: las bases de SAP de las compañías que
   * ya usan esta conexión. Con una sola se preselecciona — es la única respuesta
   * posible y hacerla escribir no aporta nada.
   */
  #fillSapDbOptions(dbs) {
    this.companyDbListTarget.replaceChildren(
      ...dbs.map((db) => {
        const opt = document.createElement('option');
        opt.value = db;
        return opt;
      }),
    );

    if (dbs.length === 1) this.companyDbTarget.value = dbs[0];
  }

  // ── Handlers de eventos ───────────────────────────────────────────────────

  /**
   * Habilita el botón de guardar solo cuando todos los campos requeridos están
   * completos, y sincroniza el botón de la prueba. Lo llama el `input->`/`change->`
   * del contenedor del formulario, así que corre con cualquier tecla.
   */
  refreshSubmitState() {
    this.submitBtnTarget.disabled = !this.#isFormValid();
    this.#syncTestLicenseBtn();
  }

  /**
   * ¿Están completos los campos obligatorios? Las credenciales de licencia son
   * opcionales: sin ellas la conexión sigue sirviendo para las pantallas (que
   * usan las credenciales personales de quien está en sesión) y lo único que no
   * corre es la sincronización de fondo.
   */
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

  // Solo las columnas que existen en la tabla. El Id ya no viaja en el cuerpo:
  // para actualizar va en el path (CLAUDE.md §28).
  //
  // `SapLicensePassword` se manda siempre, incluso en blanco: el servidor lee el
  // blanco como "conservar la guardada", salvo que además se haya vaciado el
  // usuario, que es la forma explícita de quitar las credenciales.
  #buildPayload() {
    return {
      Name:               this.nameTarget.value.trim(),
      SlUrl:              this.slUrlTarget.value.trim(),
      SapLicense:         this.sapLicenseTarget.value.trim(),
      SapLicensePassword: this.sapLicensePasswordTarget.value,
    };
  }

  // ── Credenciales de licencia — prueba contra el Service Layer ──────────────

  /** Toggle de visibilidad de la contraseña de licencia (CLAUDE.md §4). */
  toggleLicensePassword() {
    const input = this.sapLicensePasswordTarget;
    const shown = input.type === 'text';
    input.type = shown ? 'password' : 'text';
    this.eyeIconTarget.textContent = shown ? 'visibility_off' : 'visibility';
  }

  /**
   * Comprueba las credenciales de licencia contra el Service Layer.
   *
   * Prueba lo que está EN EL FORMULARIO, no lo guardado. La única excepción es la
   * contraseña, que el servidor no devuelve — en blanco usa la guardada.
   */
  async testLicense() {
    if (this.#isTesting) return;

    const problem = this.#licenseTestBlocker();
    if (problem) {
      showToast(problem, 'warning');
      return;
    }

    const fingerprint = this.#licenseFingerprint();

    this.#isTesting           = true;
    this.#verifiedFingerprint = null;
    this.#syncTestLicenseBtn();

    try {
      // Responde 200 con Data true/false; el motivo del rechazo viene en Message.
      const json = await this.#apiFetch('/api/sap_license_validations', {
        method: 'POST',
        body: JSON.stringify({
          ConnectionId:       this.#isEditMode ? this.connectionIdValue : null,
          SlUrl:              this.slUrlTarget.value.trim(),
          SapLicense:         this.sapLicenseTarget.value.trim(),
          SapLicensePassword: this.sapLicensePasswordTarget.value,
          CompanyDb:          this.companyDbTarget.value.trim(),
        }),
      });

      if (json?.Data === true) {
        this.#verifiedFingerprint = fingerprint;
      } else {
        showAlert({
          type:    ALERT_TYPES.ERROR,
          title:   'Credenciales de licencia inválidas',
          message: json?.Message || 'No se pudo conectar al Service Layer de SAP.',
        });
      }
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al comprobar las credenciales', message: err.message });
    } finally {
      this.#isTesting = false;
      this.#syncTestLicenseBtn();
    }
  }

  /**
   * Motivo por el que todavía no se puede probar, o `null` si ya se puede. Es lo
   * mismo que alimenta el tooltip del botón deshabilitado (CLAUDE.md §2).
   */
  #licenseTestBlocker() {
    if (!this.#isSlUrlValid())                return 'Ingrese la URL del Service Layer para probar las credenciales';
    if (!this.sapLicenseTarget.value.trim())  return 'Ingrese el usuario de licencia para probar las credenciales';
    if (!this.sapLicensePasswordTarget.value && !this.#hasStoredPassword) {
      return 'Ingrese la contraseña de licencia para probar las credenciales';
    }
    if (!this.companyDbTarget.value.trim())   return 'Indique la base de datos de SAP para probar las credenciales';

    return null;
  }

  /**
   * Valores de los que depende el resultado de la prueba. Se serializa con
   * `JSON.stringify` y no con un `join`: cualquier separador puede aparecer
   * dentro de una contraseña, y dos combinaciones distintas darían la misma
   * huella — el botón se quedaría en "verificadas" con otros valores.
   */
  #licenseFingerprint() {
    return JSON.stringify([
      this.slUrlTarget.value.trim(),
      this.sapLicenseTarget.value.trim(),
      this.sapLicensePasswordTarget.value,
      this.companyDbTarget.value.trim(),
    ]);
  }

  /** Tres estados: probando / verificadas / por probar. */
  #syncTestLicenseBtn() {
    const btn   = this.btnTestLicenseTarget;
    const icon  = this.testLicenseIconTarget;
    const label = this.testLicenseLabelTarget;

    const blocker  = this.#licenseTestBlocker();
    const verified = this.#verifiedFingerprint !== null &&
                     this.#verifiedFingerprint === this.#licenseFingerprint();

    btn.disabled = this.#isTesting || blocker !== null;

    if (this.#isTesting) {
      icon.textContent  = 'hourglass_empty';
      label.textContent = 'Comprobando...';
      btn.classList.remove('btn-verified');
      this.#setTip(btn, 'Comprobando las credenciales contra el Service Layer, espere por favor');
      return;
    }

    if (verified) {
      icon.textContent  = 'check_circle';
      label.textContent = 'Credenciales verificadas';
      btn.classList.add('btn-verified');
      this.#setTip(btn, 'Las credenciales de licencia ya se comprobaron contra el Service Layer');
      return;
    }

    icon.textContent  = 'wifi_tethering';
    label.textContent = 'Comprobar credenciales de SAP';
    btn.classList.remove('btn-verified');
    this.#setTip(btn, blocker || 'Comprobar las credenciales de licencia contra el Service Layer');
  }

  /**
   * `data-tooltip` (convención §2) y `title` (fallback nativo) sincronizados. Esta
   * pantalla no tiene tabla Tabulator, así que el `title` es lo que el usuario
   * llega a ver (§33): un botón deshabilitado tiene que decir qué falta.
   */
  #setTip(el, text) {
    if (!el) return;
    el.dataset.tooltip = text;
    el.setAttribute('title', text);
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

import { Controller } from '@hotwired/stimulus';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';

/**
 * UserProfileController — Actualización de información de perfil del usuario.
 *
 * Replica la funcionalidad del componente Angular UpdateUserInfoComponent:
 * - Carga inicial: GET /api/profile + GET /api/companies (paralelo)
 * - Toggle visibilidad de contraseña
 * - credentialsDirty tracking (SapUser / SapPass changes)
 * - Botón "Probar credenciales" con 3 estados (default / validating / verified)
 * - El botón también se habilita SIN cambios en el formulario cuando el usuario
 *   ya tiene usuario y contraseña de SAP guardados: permite reverificar lo
 *   guardado sin pasar por "Actualizar". El servidor prueba las credenciales
 *   YA guardadas (`UseSavedCredentials: true`) y persiste el resultado de una
 *   vez — no hay ningún cambio pendiente que guardar en ese caso.
 * - Ícono `verified` en el campo de usuario: verde si las credenciales están
 *   certificadas (`SapCredentialsVerified`), gris tenue si no
 * - PATCH /api/profile con los campos editables del perfil (nombre, usuario y
 *   contraseña de SAP). Probar las
 *   credenciales NO es requisito para guardar: el servidor decide si las
 *   guardadas quedan certificadas comparándolas con la última prueba exitosa.
 *
 * Todos sus endpoints son nativos de Rails: ya no pasa por el proxy al .NET.
 */
export default class extends Controller {
  static targets = [
    'form',
    'nameInput',
    'sapUserInput',
    'sapUserError',
    'verifiedBadge',
    'sapPassInput',
    'togglePasswordBtn',
    'eyeIcon',
    'companySelect',
    'btnTestCredentials',
    'testCredentialsIcon',
    'testCredentialsLabel',
    'btnUpdate',
    'cardLoader',
  ];

  // ── Estado interno ─────────────────────────────────────────────────────────

  /** Datos completos del usuario recibidos de la API */
  #userInfo = null;

  /** true si SapUser o SapPass fueron modificados desde la última carga/actualización */
  #credentialsDirty = false;

  /** true si las credenciales fueron validadas exitosamente */
  #credentialsValidated = false;

  /** Indica si la validación de credenciales está en curso */
  #isValidating = false;

  /** ID de compañía actualmente seleccionado en el storage */
  #selectedCompanyFromStorage = null;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    this.#onLoad();
  }

  // ── Inicialización ────────────────────────────────────────────────────────

  async #onLoad() {
    this.#showCardLoader();
    this.#resetCredentialState();
    this.#readSelectedCompanyFromStorage();
    try {
      await Promise.all([
        this.#loadInitialData(),
        this.#loadAssignableCompanies(),
      ]);
      // Recién con `#userInfo` y las compañías cargadas se puede decidir si el
      // select y el botón de prueba nacen habilitados (`#hasSavedCredentials`).
      this.#syncButtonStates();
    } finally {
      this.#hideCardLoader();
    }
  }

  #showCardLoader() {
    this.cardLoaderTarget?.classList.remove('hidden');
  }

  #hideCardLoader() {
    this.cardLoaderTarget?.classList.add('hidden');
  }

  #readSelectedCompanyFromStorage() {
    const company = SStore.get('CurrentCompany');
    this.#selectedCompanyFromStorage = company?.companyId ?? null;
  }

  /**
   * GET /api/profile — perfil del usuario de la sesión. No lleva id: el servidor
   * lo toma de la cookie, así que no hay forma de pedir el perfil de otro.
   *
   * La llamada a GetGroupsByUser que hacía el Angular se eliminó: su respuesta se
   * descartaba (ningún campo de esta pantalla depende de los grupos).
   */
  async #loadInitialData() {
    try {
      const res = await this.#get('/api/profile');

      this.#userInfo = res.Data ?? null;

      if (this.#userInfo) this.#fillForm(this.#userInfo);
    } catch (err) {
      await Swal.fire({
        icon: 'error',
        title: 'Se produjo un error al obtener la información',
        text: this.#extractError(err),
        confirmButtonText: 'Aceptar',
      });
    }
  }

  /**
   * GET /api/profile/companies — solo las compañías asignadas al usuario. Es el
   * mismo universo contra el que el servidor acepta probar credenciales, así que
   * el select no puede ofrecer una que después rechace con 403.
   */
  async #loadAssignableCompanies() {
    try {
      const data = await this.#get('/api/profile/companies');
      const companies = data.Data ?? [];

      // Limpiar opciones previas (excepto placeholder)
      while (this.companySelectTarget.options.length > 1) {
        this.companySelectTarget.remove(1);
      }

      companies.forEach(c => {
        const option = document.createElement('option');
        option.value = c.Id;
        option.textContent = c.Name;
        this.companySelectTarget.appendChild(option);
      });

      // Pre-seleccionar compañía del storage
      if (this.#selectedCompanyFromStorage) {
        this.companySelectTarget.value = String(this.#selectedCompanyFromStorage);
      }
    } catch {
      // Error silencioso — el usuario puede seleccionar manualmente
    }
  }

  // ── Form helpers ──────────────────────────────────────────────────────────

  #fillForm({ Name, SapUser }) {
    this.nameInputTarget.value    = Name ?? '';
    this.sapUserInputTarget.value = SapUser ?? '';
    this.sapPassInputTarget.value = '';
  }

  #resetCredentialState() {
    this.#credentialsDirty = false;
    this.#credentialsValidated = false;
    this.#isValidating = false;
    this.#syncButtonStates();
  }

  // ── Event handlers ────────────────────────────────────────────────────────

  /**
   * Disparado por cambios en SapUser o SapPass.
   * Activa credentialsDirty; el select de compañías y el botón de prueba se
   * habilitan/deshabilitan de forma centralizada en `#syncButtonStates`.
   */
  onCredentialChange() {
    this.#credentialsDirty = true;
    this.#credentialsValidated = false;
    this.#syncButtonStates();
  }

  /**
   * Disparado por cambio en el select de compañías.
   * Resetea credentialsValidated (hay que revalidar con la nueva compañía).
   */
  onCompanyChange() {
    if (this.#credentialsDirty) {
      this.#credentialsValidated = false;
      this.#syncButtonStates();
    }
  }

  /** Toggle visibilidad contraseña SAP */
  togglePasswordVisibility() {
    const input = this.sapPassInputTarget;
    const icon  = this.eyeIconTarget;

    if (input.type === 'password') {
      input.type = 'text';
      icon.textContent = 'visibility';
    } else {
      input.type = 'password';
      icon.textContent = 'visibility_off';
    }
  }

  /** true si el perfil ya tiene usuario y contraseña de SAP guardados. Es lo
   * que habilita "Probar credenciales" aunque el formulario no tenga cambios:
   * hay algo guardado que reverificar. */
  #hasSavedCredentials() {
    return !!(this.#userInfo?.SapUser && this.#userInfo?.HasSapPassword);
  }

  /**
   * Click en "Probar credenciales".
   *
   * Dos modos, según si el formulario tiene cambios:
   *   - Dirty: prueba lo ESCRITO. El resultado solo queda persistido si
   *     después se guarda con "Actualizar" (`Sap::CredentialVerification`
   *     en el servidor compara la huella de la sesión contra lo guardado).
   *   - No dirty (nada editado): reverifica lo YA guardado
   *     (`UseSavedCredentials: true`). El servidor prueba la contraseña que
   *     tiene en la base — el campo siempre carga en blanco, así que el
   *     cliente no la tiene — y persiste el resultado de una vez: no hay
   *     ningún cambio pendiente que "Actualizar" vaya a guardar después.
   */
  async testCredentials() {
    const selectedCompanyId = Number(this.companySelectTarget.value);

    if (!selectedCompanyId) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Seleccione una compañía para probar las credenciales.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return;
    }

    const verifyingSaved = !this.#credentialsDirty;
    let body;

    if (verifyingSaved) {
      // El botón solo llega habilitado en este modo si `#hasSavedCredentials()`
      // ya era true (ver `#syncTestCredentialsBtn`), pero se revalida acá por
      // si el estado cambió entre renders.
      if (!this.#hasSavedCredentials()) return;
      body = { CompanyId: selectedCompanyId, UseSavedCredentials: true };
    } else {
      const sapUser = this.sapUserInputTarget.value.trim();
      const sapPass = this.sapPassInputTarget.value;

      if (!sapUser || !sapPass) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'warning',
          title: 'Complete el Usuario y Contraseña de SAP antes de probar.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
        return;
      }

      body = { SapUser: sapUser, SapPass: sapPass, CompanyId: selectedCompanyId };
    }

    this.#isValidating = true;
    this.#credentialsValidated = false;
    this.#syncButtonStates();

    try {
      // POST /api/sap_credential_validations — hace el /Login contra el Service
      // Layer de esa compañía. Responde 200 con Data true/false; el motivo del
      // rechazo viene en Message.
      const data = await this.#post('/api/sap_credential_validations', body);

      if (data?.Data === true) {
        this.#credentialsValidated = true;
        if (verifyingSaved) {
          // El servidor ya marcó `sap_credentials_verified` en la base: reflejar
          // el nuevo estado acá evita un GET /api/profile solo para refrescar
          // el ícono.
          if (this.#userInfo) this.#userInfo.SapCredentialsVerified = true;
          Swal.fire({
            toast: true,
            position: 'top-end',
            icon: 'success',
            title: 'Credenciales de SAP verificadas.',
            showConfirmButton: false,
            timer: 3000,
            timerProgressBar: true
          });
        }
      } else {
        this.#credentialsValidated = false;
        if (verifyingSaved && this.#userInfo) this.#userInfo.SapCredentialsVerified = false;
        const message = data?.Message || 'No se pudo conectar a SAP Service Layer.';
        await Swal.fire({
          icon: 'error',
          title: 'Credenciales inválidas',
          text: message,
          confirmButtonText: 'Aceptar',
        });
      }
    } catch (err) {
      this.#credentialsValidated = false;
      if (verifyingSaved && this.#userInfo) this.#userInfo.SapCredentialsVerified = false;
      await Swal.fire({
        icon: 'error',
        title: 'Error al validar credenciales',
        text: this.#extractError(err),
        confirmButtonText: 'Aceptar',
      });
    } finally {
      this.#isValidating = false;
      this.#syncButtonStates();
    }
  }

  /** Submit del formulario — equivale a OnSubmitUpdateUserInfo */
  async onSubmit(event) {
    event.preventDefault();

    if (!this.#validateForm()) return;

    // Solo los campos editables: el endpoint identifica al usuario por la
    // sesión, así que reenviarle el resto del perfil no aportaba nada.
    // SapPass vacío significa "sin cambio" — el formulario siempre carga el campo
    // en blanco porque el servidor nunca devuelve la contraseña guardada.
    const payload = {
      Name:    this.nameInputTarget.value.trim(),
      SapUser: this.sapUserInputTarget.value.trim(),
      SapPass: this.sapPassInputTarget.value,
    };

    this.btnUpdateTarget.disabled = true;

    try {
      await this.#patch('/api/profile', payload);
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Información actualizada con éxito!!!',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.#onLoad();
    } catch (err) {
      await Swal.fire({
        icon: 'error',
        title: 'Error al actualizar perfil',
        text: this.#extractError(err),
        confirmButtonText: 'Aceptar',
      });
    } finally {
      this.btnUpdateTarget.disabled = false;
    }
  }

  // ── Estado de botones ─────────────────────────────────────────────────────

  #syncButtonStates() {
    this.#syncCompanySelect();
    this.#syncTestCredentialsBtn();
    this.#syncUpdateBtn();
    this.#syncVerifiedBadge();
  }

  /**
   * Ícono del campo de usuario. Sin cambios en el formulario refleja lo guardado
   * (`SapCredentialsVerified`); con cambios, refleja la prueba de lo que está
   * escrito — lo guardado ya no describe lo que el usuario ve.
   */
  #syncVerifiedBadge() {
    const badge = this.verifiedBadgeTarget;
    let verified;
    let tip;

    if (!this.#credentialsDirty) {
      verified = !!this.#userInfo?.SapCredentialsVerified;
      tip = verified
        ? 'Credenciales de SAP verificadas'
        : 'Credenciales de SAP sin verificar. Ingrese la contraseña y use «Probar credenciales» para verificarlas';
    } else {
      verified = this.#credentialsValidated;
      tip = verified
        ? 'Credenciales de SAP verificadas. Guarde los cambios para conservar la verificación'
        : 'Credenciales de SAP sin verificar. Pruébelas antes de guardar para que queden verificadas';
    }

    badge.classList.toggle('text-green-600', verified);
    badge.classList.toggle('text-gray-300', !verified);
    this.#setTip(badge, tip);
  }

  /**
   * El select de compañías se habilita en dos casos: hay cambios que probar
   * (`credentialsDirty`), o no hay cambios pero ya existe algo guardado que
   * reverificar (`#hasSavedCredentials`).
   */
  #syncCompanySelect() {
    const enabled = this.#credentialsDirty || this.#hasSavedCredentials();
    this.companySelectTarget.disabled = !enabled;

    const tip = enabled
      ? 'Seleccione la compañía con la que desea probar las credenciales'
      : 'Modifique el usuario o la contraseña de SAP para habilitar la selección de compañía';
    this.#setTip(this.companySelectTarget, tip);
  }

  #syncTestCredentialsBtn() {
    const btn   = this.btnTestCredentialsTarget;
    const icon  = this.testCredentialsIconTarget;
    const label = this.testCredentialsLabelTarget;

    const companySelected = !!this.companySelectTarget.value;
    // Sin cambios en el formulario, el botón igual se habilita si hay algo
    // guardado que reverificar.
    const verifyingSaved  = !this.#credentialsDirty && this.#hasSavedCredentials();
    const canTest = (this.#credentialsDirty || verifyingSaved) && companySelected && !this.#isValidating;

    btn.disabled = !canTest;

    if (this.#isValidating) {
      icon.textContent  = 'hourglass_empty';
      label.textContent = 'Probando...';
      btn.classList.remove('btn-verified');
      this.#setTip(btn, 'Validando las credenciales de SAP, espere por favor');
    } else if (this.#credentialsValidated) {
      icon.textContent  = 'check_circle';
      label.textContent = 'Credenciales verificadas';
      btn.classList.add('btn-verified');
      this.#setTip(btn, 'Las credenciales de SAP ya fueron verificadas correctamente');
    } else {
      icon.textContent  = 'wifi_tethering';
      label.textContent = 'Probar credenciales';
      btn.classList.remove('btn-verified');
      // Tooltip accionable según la condición que mantiene el botón deshabilitado
      if (!this.#credentialsDirty && !verifyingSaved) {
        this.#setTip(btn, 'Modifique el usuario o la contraseña de SAP para probar las credenciales');
      } else if (!companySelected) {
        this.#setTip(btn, 'Seleccione una compañía para probar las credenciales');
      } else if (verifyingSaved) {
        this.#setTip(btn, 'Verificar las credenciales de SAP ya guardadas en la compañía seleccionada');
      } else {
        this.#setTip(btn, 'Probar las credenciales de SAP en la compañía seleccionada');
      }
    }
  }

  #syncUpdateBtn() {
    const formInvalid = !this.sapUserInputTarget.value.trim();
    this.btnUpdateTarget.disabled = formInvalid;

    // Tooltip accionable según la condición que mantiene el botón deshabilitado
    if (formInvalid) {
      this.#setTip(this.btnUpdateTarget, 'Ingrese el usuario de SAP para guardar los cambios');
    } else {
      this.#setTip(this.btnUpdateTarget, 'Guardar los cambios del perfil');
    }
  }

  /**
   * Mantiene sincronizados los dos atributos de tooltip de un control:
   * `data-tooltip` (convención §2) y `title` (fallback nativo del navegador).
   * Todo botón/control deshabilitado debe describir la condición para habilitarlo.
   */
  #setTip(el, text) {
    if (!el) return;
    el.dataset.tooltip = text;
    el.setAttribute('title', text);
  }

  // ── Validación de formulario ──────────────────────────────────────────────

  #validateForm() {
    const sapUser = this.sapUserInputTarget.value.trim();
    if (!sapUser) {
      this.sapUserErrorTarget.classList.remove('hidden');
      this.sapUserInputTarget.focus();
      return false;
    }
    this.sapUserErrorTarget.classList.add('hidden');
    return true;
  }

  // ── API helpers ───────────────────────────────────────────────────────────

  async #get(url) {
    return this.#apiFetch(url);
  }

  async #post(url, body) {
    return this.#apiFetch(url, {
      method: 'POST',
      body: JSON.stringify(body),
    });
  }

  async #patch(url, body) {
    return this.#apiFetch(url, {
      method: 'PATCH',
      body: JSON.stringify(body),
    });
  }

  /**
   * Endpoints nativos: la sesión va en la cookie httpOnly, así que no se arma
   * ningún header Authorization — getApiHeaders() aporta lo único que hace falta.
   * El error lo trae el campo Message del contrato ApiResponse.
   */
  async #apiFetch(url, options = {}) {
    const res = await fetch(url, {
      ...options,
      headers: {
        'Accept': 'application/json',
        ...getApiHeaders(),
        ...(options.headers || {}),
      },
    });

    if (!res.ok) {
      const body = await res.json().catch(() => null);
      throw new Error(body?.Message || `HTTP ${res.status}`);
    }

    const contentType = res.headers.get('content-type') || '';
    const contentLength = res.headers.get('content-length');
    if (contentLength === '0' || !contentType.includes('json')) return {};
    return res.json();
  }

  #extractError(err) {
    if (typeof err === 'string') return err;
    return err?.message ?? 'Ocurrió un error inesperado.';
  }
}

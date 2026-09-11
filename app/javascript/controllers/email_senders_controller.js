import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * EmailSendersController — Bandejas de correo de envío (/configurations/email-senders).
 *
 * Migrado del `EmailInboxComponent` de Angular, que tenía dos tabs. Acá queda
 * uno solo:
 *
 *   - "Bandeja de Correos" (EmailInboxConfigComponent) → esta pantalla.
 *   - "Asignación de Bandejas a Compañías" (EmailInboxAssigmentComponent) → se
 *     eliminó. Asignaba N bandejas a una compañía contra la tabla puente
 *     `CompanyEmailConfig` del .NET, pero el envío resolvía la suya con un
 *     `FirstOrDefault`: de las N usaba una arbitraria. Acá la relación es
 *     `companies.email_config_id` (UNA bandeja por compañía) y se elige en la
 *     sección "Datos Generales" del formulario de compañías, al lado de la
 *     conexión de SAP.
 *
 * Endpoints (Rails nativo — ver CLAUDE.md §28):
 *   GET   /api/email_configs?email=&ssl=&page=&per_page=
 *   POST  /api/email_configs
 *   PATCH /api/email_configs/:id
 *   POST  /api/email_credential_validations
 *
 * Ninguno pasa por el proxy .NET, así que no hay header `API` ni token de
 * `sessionStorage.currentFEUser`: la sesión va en la cookie y `getApiHeaders()`
 * pone lo único que hace falta.
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,

    // Toolbar
    'btnCreate', 'btnCreateWrap',

    // Filtros
    // NOTA: el filtro 'filterHost' se eliminó de la vista (ver TODOS.md). Ya no
    // se envía nada en su lugar: `GET /api/email_configs` no lo pide.
    'filterEmail', 'filterSsl',

    // Panel lateral
    'panel', 'panelBackdrop', 'panelTitle',
    'saveBtn', 'saveBtnWrap', 'saveLabel',
    'btnValidate', 'validateIcon', 'validateLabel',

    // Campos del formulario
    'inputEmail', 'errorEmail', 'errorEmailPattern',
    'inputPassword', 'errorPassword', 'passwordEyeIcon', 'passwordAsterisk', 'passwordHint',
    'inputSenderAddress',
    'inputHost', 'errorHost',
    'inputPort', 'errorPort',
    'inputSsl',
    'inputActive', 'activeHint',
    'inputTestEmail',
  ];

  static values = { ...TabulatorController.values };

  // ── Estado ────────────────────────────────────────────────────────────────

  #permissions = [];

  #totalRecords  = 0;        // total real del servidor (evita la sobreestimación de §17)
  #editingRecord = null;     // null = creación

  // La prueba de credenciales es requisito para guardar. `#verifiedFingerprint`
  // guarda la huella de los valores con los que la prueba pasó: si alguno
  // cambia, la verificación deja de valer sin tener que escuchar campo por
  // campo (mismo patrón que `connections_controller.js`).
  #verifiedFingerprint = null;
  #isValidating = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    this.#permissions = SStore.get('Permissions') || [];

    // Botón "Nueva Bandeja": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.hasBtnCreateTarget) {
      if (this.#hasPerm('Configurations_EmailInbox_Create')) {
        this.#enableCreateButton();
      } else if (this.hasBtnCreateWrapTarget) {
        this.#attachTooltip(this.btnCreateWrapTarget);
      }
    }

    // El botón de guardar del panel también vive fuera de la tabla, así que el
    // `setupTooltip()` del base no lo cubre.
    if (this.hasSaveBtnWrapTarget) this.#attachTooltip(this.saveBtnWrapTarget);

    super.connect();  // inicializa Tabulator; dispara ajaxRequestFunc con page=1
  }

  // ── Configuración Tabulator ────────────────────────────────────────────────

  getTableConfig() {
    // Excluir 'data' y 'maxHeight' del base para que Tabulator entre en modo ajax
    // (con la key 'data' presente, aunque sea undefined, usa modo local y no
    // muestra el loader) y para que la tabla ocupe el alto del contenedor (§11).
    const { data: _d, maxHeight: _m, ...base } = super.getTableConfig();
    return {
      ...base,
      height:      '100%',
      movableRows: false,
      layout:      'fitColumns',
      placeholder: 'No hay bandejas registradas',
      pagination:     true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 15, 25],
      // Contador con el total REAL del servidor: `paginationCounter: 'rows'`
      // calcula `last_page * pageSize` y sobreestima cuando la última página no
      // está llena (CLAUDE.md §17).
      paginationCounter: (pageSize, currentRow) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      // ajaxURL requerido para activar el modo remote; la petición real la hace
      // ajaxRequestFunc.
      ajaxURL:         '/api/email_configs',
      ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
      locale: TABULATOR_LOCALE,
      langs:  TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      columns: this.getColumns(),
    };
  }

  getColumns() {
    return [
      { title: 'Correo',       field: 'Email',         minWidth: 180 },
      { title: 'Host',         field: 'Host',          minWidth: 140 },
      { title: 'Puerto',       field: 'Port',          width: 90  },
      {
        title: 'SSL',
        field: 'Ssl',
        width: 90,
        formatter: (cell) => this.#badge(cell.getValue() ? 'active' : 'inactive',
          cell.getValue() ? 'Sí' : 'No'),
      },
      { title: 'A nombre de',  field: 'SenderAddress', minWidth: 160 },
      {
        // Cuántas compañías la usan: es lo que explica por qué una bandeja no se
        // puede dar de baja, antes de que el guardado lo rechace.
        title: 'Compañías',
        field: 'CompaniesCount',
        width: 110,
        hozAlign: 'center',
      },
      {
        title: 'Estado',
        field: 'Active',
        width: 110,
        formatter: (cell) => this.#badge(cell.getValue() ? 'active' : 'inactive'),
      },
      {
        title: 'Acciones',
        field: '_actions',
        width: 100,
        hozAlign: 'center',
        headerSort: false,
        // Editar sin permiso: deshabilitado + tooltip (CLAUDE.md §26). El
        // data-tooltip va en el <span> envolvente (un <button disabled> no emite
        // eventos de mouse); el setupTooltip base (tabla) lo detecta.
        formatter: () => this.#hasPerm('Configurations_EmailInbox_Update')
          ? `<button type="button" data-action-type="edit" data-tooltip="Modificar la bandeja"
                     class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
               <span class="material-icons text-base">edit</span>
             </button>`
          : `<span data-tooltip="No cuenta con permisos para editar bandejas de correo">
               <button type="button" disabled
                       class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
                 <span class="material-icons text-base">edit</span>
               </button>
             </span>`,
        cellClick: (event, cell) => {
          if (!event.target.closest('[data-action-type]')) return;
          this.#openEditPanel(cell.getRow().getData());
        },
      },
    ];
  }

  // ── Acciones públicas ─────────────────────────────────────────────────────

  /** setData() recarga vía ajaxRequestFunc y vuelve a la página 1. */
  search() {
    this.table?.setData();
  }

  openCreatePanel() {
    // Defensa en profundidad: el botón se deshabilita sin permiso, pero
    // reverificamos acá (CLAUDE.md §26).
    if (!this.#hasPerm('Configurations_EmailInbox_Create')) {
      showToast('No cuenta con permisos para crear bandejas de correo.', 'info');
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

  /**
   * Llamada desde `data-action="input-> change->"` del contenedor del panel.
   * No compara campo por campo: recalcula el estado de los dos botones a partir
   * de la huella, así que un campo nuevo no se puede olvidar de invalidar la
   * verificación.
   */
  onFormChange() {
    this.#syncValidateButton();
    this.#syncSaveButton();
  }

  async validateCredentials() {
    if (this.#isValidating) return;

    const blocked = this.#validateBlockedReason();
    if (blocked) {
      showToast(blocked, 'warning');
      return;
    }

    const fingerprint = this.#fingerprint();
    this.#isValidating = true;
    this.#verifiedFingerprint = null;
    this.#syncValidateButton();
    this.#syncSaveButton();

    try {
      const json = await this.#apiFetch('/api/email_credential_validations', {
        method: 'POST',
        body: JSON.stringify({
          EmailConfigId:  this.#editingRecord?.Id ?? null,
          Email:          this.inputEmailTarget.value.trim(),
          Password:       this.inputPasswordTarget.value,
          Host:           this.inputHostTarget.value.trim(),
          Port:           this.inputPortTarget.value,
          Ssl:            this.inputSslTarget.checked,
          SenderAddress:  this.inputSenderAddressTarget.value.trim(),
          RecipientEmail: this.inputTestEmailTarget.value.trim(),
        }),
      });

      // Credenciales inválidas llegan como 200 con `Data: false` y el motivo en
      // `Message`: no es un error de la petición, es el resultado de la prueba.
      if (json?.Data === true) {
        this.#verifiedFingerprint = fingerprint;
        showToast(json.Message || 'Se envió el correo de prueba.', 'success');
      } else {
        showAlert({
          type:    ALERT_TYPES.ERROR,
          title:   'No se pudo enviar el correo de prueba',
          message: json?.Message || 'El servidor de correo rechazó la configuración.',
        });
      }
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al probar la bandeja', message: err.message });
    } finally {
      this.#isValidating = false;
      this.#syncValidateButton();
      this.#syncSaveButton();
    }
  }

  async save() {
    // Defensa en profundidad: la UI ya deshabilita el botón, pero se puede
    // manipular (CLAUDE.md §26).
    const blocked = this.#saveBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    const isCreate = !this.#editingRecord;
    const url    = isCreate ? '/api/email_configs' : `/api/email_configs/${this.#editingRecord.Id}`;
    const method = isCreate ? 'POST' : 'PATCH';

    this.saveBtnTarget.disabled = true;
    try {
      const json = await this.#apiFetch(url, { method, body: JSON.stringify(this.#payload()) });
      this.closePanel();
      this.table?.setData();
      showToast(json.Message || 'Bandeja guardada con éxito.', 'success');
    } catch (err) {
      // Error de escritura → modal, no toast (CLAUDE.md §9).
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar la bandeja', message: err.message });
      this.#syncSaveButton();
    }
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
    // El `<select>` de SSL usa '' para "Todos": un filtro ausente no filtra, y
    // no hace falta el valor centinela `2` del .NET.
    if (this.filterSslTarget.value) query.set('ssl', this.filterSslTarget.value);

    try {
      const json = await this.#apiFetch(`/api/email_configs?${query}`);
      const total = json.Data?.Total ?? 0;
      this.#totalRecords = total;
      return { data: json.Data?.Items ?? [], last_page: Math.max(1, Math.ceil(total / size)) };
    } catch (err) {
      // Error de lectura → toast (CLAUDE.md §9).
      showToast(err.message || 'Error al buscar las bandejas.', 'error');
      this.#totalRecords = 0;
      return { data: [], last_page: 1 };
    }
  }

  // ── Panel lateral ─────────────────────────────────────────────────────────

  #openEditPanel(row) {
    if (!this.#hasPerm('Configurations_EmailInbox_Update')) {
      showToast('No cuenta con permisos para editar bandejas de correo.', 'info');
      return;
    }
    this.#editingRecord = row;
    this.#resetForm();

    this.panelTitleTarget.textContent = 'Modificar bandeja';
    this.saveLabelTarget.textContent  = 'Modificar';

    this.inputEmailTarget.value         = row.Email         || '';
    this.inputSenderAddressTarget.value = row.SenderAddress || '';
    this.inputHostTarget.value          = row.Host          || '';
    this.inputPortTarget.value          = row.Port ?? '';
    this.inputSslTarget.checked         = !!row.Ssl;
    this.inputActiveTarget.checked      = row.Active !== false;

    this.#applyPanelMode();
    this.#openPanel();
  }

  /**
   * Lo que cambia entre crear y editar. Son tres cosas y todas salen del mismo
   * lugar para que no se desincronicen:
   *
   *  - la contraseña deja de ser obligatoria (en blanco = conservar la guardada);
   *  - el check "Bandeja activa" solo aparece al editar: dar de alta una bandeja
   *    inactiva no tiene sentido, y `is_active` nace en `true`;
   *  - el aviso de cuántas compañías la usan, que es el motivo por el que
   *    desactivarla puede fallar.
   */
  #applyPanelMode() {
    const isEdit = !!this.#editingRecord;

    this.passwordAsteriskTarget.classList.toggle('hidden', isEdit);
    this.passwordHintTarget.classList.toggle('hidden', !isEdit || !this.#editingRecord.HasPassword);
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
    this.inputEmailTarget.value            = '';
    this.inputPasswordTarget.value         = '';
    this.inputPasswordTarget.type          = 'password';
    this.passwordEyeIconTarget.textContent = 'visibility_off';
    this.inputSenderAddressTarget.value    = '';
    this.inputHostTarget.value             = '';
    this.inputPortTarget.value             = '';
    this.inputSslTarget.checked            = true;   // el default de la columna
    this.inputActiveTarget.checked         = true;
    this.inputTestEmailTarget.value        = '';
    this.#verifiedFingerprint = null;
    this.#clearErrors();
  }

  // ── Validación y estado de los botones ────────────────────────────────────

  /**
   * Valores de los que depende el resultado de la prueba. Se serializa con
   * `JSON.stringify` y no con un `join`: cualquier separador puede aparecer
   * dentro de una contraseña.
   *
   * El destinatario de la prueba NO entra: cambiar a quién se le manda no
   * invalida unas credenciales que ya funcionaron.
   */
  #fingerprint() {
    return JSON.stringify([
      this.inputEmailTarget.value.trim(),
      this.inputPasswordTarget.value,
      this.inputHostTarget.value.trim(),
      this.inputPortTarget.value,
      this.inputSslTarget.checked,
      this.inputSenderAddressTarget.value.trim(),
    ]);
  }

  #isVerified() {
    return this.#verifiedFingerprint !== null && this.#verifiedFingerprint === this.#fingerprint();
  }

  /**
   * Motivo por el que todavía no se puede PROBAR, o `null` si ya se puede. Es lo
   * mismo que alimenta el tooltip del botón deshabilitado (§2): cada mensaje
   * responde *¿cuándo SÍ podré usarlo?*.
   */
  #validateBlockedReason() {
    const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    if (!this.inputEmailTarget.value.trim())            return 'Ingrese el correo de la bandeja para probarla';
    if (!EMAIL_RE.test(this.inputEmailTarget.value.trim())) return 'El correo de la bandeja no tiene un formato válido';
    if (!this.inputHostTarget.value.trim())             return 'Ingrese el host para probar la bandeja';
    if (!this.inputPortTarget.value)                    return 'Ingrese el puerto para probar la bandeja';
    // En edición la contraseña guardada sirve: en blanco significa "la que ya está".
    if (!this.inputPasswordTarget.value && !this.#editingRecord?.HasPassword) {
      return 'Ingrese la contraseña de la bandeja para probarla';
    }
    if (!this.inputTestEmailTarget.value.trim())        return 'Indique el correo destinatario al que se enviará la prueba';
    if (!EMAIL_RE.test(this.inputTestEmailTarget.value.trim())) return 'El correo destinatario de la prueba no tiene un formato válido';

    return null;
  }

  /** Motivo por el que todavía no se puede GUARDAR, o `null`. */
  #saveBlockedReason() {
    const blocked = this.#validateBlockedReason();
    // Mientras falten campos, el motivo de no poder guardar es el mismo que el
    // de no poder probar — decir "pruebe las credenciales" con el host vacío
    // manda al usuario a un botón que tampoco funciona.
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
      this.validateLabelTarget.textContent = 'Enviando prueba...';
    } else if (verified) {
      this.validateIconTarget.textContent  = 'check_circle';
      this.validateLabelTarget.textContent = 'Bandeja verificada';
    } else {
      this.validateIconTarget.textContent  = 'wifi_tethering';
      this.validateLabelTarget.textContent = 'Probar bandeja';
    }
  }

  /**
   * El botón de guardar nace deshabilitado y el motivo va en el `data-tooltip`
   * del <span> envolvente: un `<button disabled>` no emite eventos de mouse
   * (§2 y §26), por eso el botón lleva `pointer-events-none` mientras lo está.
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

  #clearErrors() {
    ['errorEmail', 'errorEmailPattern', 'errorPassword', 'errorHost', 'errorPort']
      .forEach((name) => this[`${name}Target`]?.classList.add('hidden'));
  }

  /**
   * El cuerpo del POST/PATCH: exactamente los campos que el formulario ofrece.
   *
   * `Password` en blanco NO se manda: para el servidor eso significa "conservar
   * la guardada" (ver `Api::EmailConfigsController#password_param`), y mandar la
   * cadena vacía sería pedirle que la borre.
   *
   * `Active` solo al editar: el check no existe al crear y `is_active` nace en
   * `true` por el default de la columna.
   */
  #payload() {
    const body = {
      Email:         this.inputEmailTarget.value.trim(),
      Host:          this.inputHostTarget.value.trim(),
      Port:          this.inputPortTarget.value,
      Ssl:           this.inputSslTarget.checked,
      SenderAddress: this.inputSenderAddressTarget.value.trim(),
    };
    if (this.inputPasswordTarget.value) body.Password = this.inputPasswordTarget.value;
    if (this.#editingRecord)            body.Active   = this.inputActiveTarget.checked;

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

  #badge(status, labelOverride = null) {
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

  // Tooltip flotante para un elemento fuera de la tabla, que el `setupTooltip()`
  // base no cubre. Reposiciona dentro del viewport (CLAUDE.md §25).
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
  // (CLAUDE.md §28).
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

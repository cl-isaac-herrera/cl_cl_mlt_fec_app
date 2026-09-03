import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * ConnectionsController — Lista + búsqueda de conexiones SAP (Tabulator) y
 * panel lateral de creación/edición.
 *
 * Endpoints nativos de Rails (ver CLAUDE.md §28):
 *   - GET   /api/connections?name=&sl_url=&page=&per_page=   (listado paginado)
 *   - GET   /api/connections/:id                             (cargar para editar)
 *   - POST  /api/connections                                 (crear)
 *   - PATCH /api/connections/:id                             (actualizar)
 *   - POST  /api/sap_license_validations                     (comprobar credenciales)
 *
 * El formulario maneja las columnas que existen en la tabla `connections`
 * (Name, SlUrl, SapLicense, SapLicensePassword). Los parámetros de DI-API/ODBC
 * que pedía el .NET (ODBCType, ServerType, DBUser, DBPass, …) se eliminaron:
 * este producto llega a SAP únicamente por Service Layer (CLAUDE.md §29).
 *
 * La contraseña de licencia es de SOLO ESCRITURA: el servidor nunca la devuelve,
 * así que el campo siempre carga en blanco y en blanco significa "conservar la
 * guardada". `HasSapLicensePassword` es lo único que dice si ya hay una.
 *
 * Crear/editar ya NO navega a otra vista: abre un panel lateral derecho
 * (patrón de CLAUDE.md §8). Al guardar con éxito se cierra el panel y se
 * refresca la tabla, sin recargar la página.
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,
    'inputName',
    'inputSlUrl',
    'btnCreate', 'btnCreateWrap',
    // Panel lateral
    'panel', 'panelBackdrop', 'panelTitle',
    'fName', 'fNameError',
    'fSlUrl', 'fSlUrlError',
    'fSapLicense', 'fSapLicensePassword', 'fSapLicensePasswordHint', 'fEyeIcon',
    'fCompanyDb', 'fCompanyDbList',
    'btnTestLicense', 'testLicenseIcon', 'testLicenseLabel',
    'submitBtn', 'submitIcon', 'submitLabel',
  ];

  static values = { ...TabulatorController.values };

  #permissions = [];
  #totalRecords = 0;        // total real del servidor (evita sobreestimación de Tabulator)
  #connectionId = 0;        // 0 = crear; >0 = editar
  #editMode = false;

  // ── Estado de la prueba de credenciales de licencia ────────────────────────
  #hasStoredPassword = false;   // el servidor no devuelve la contraseña, solo si existe
  #isTesting = false;
  /**
   * Huella de los valores con los que la prueba salió bien. Se compara contra la
   * huella actual en vez de escuchar cada campo: así cambiar la URL, el usuario,
   * la contraseña o la base invalida el "verificadas" sin tener que recordar
   * cablear el reset en cada input nuevo.
   */
  #verifiedFingerprint = null;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  connect() {
    const perms = SStore.get('Permissions');
    this.#permissions = Array.isArray(perms) ? perms : [];

    // Botón "Nueva Conexión": habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.#hasPerm('Configurations_Connections_Create')) {
      this.#enableCreateButton();
    } else if (this.hasBtnCreateWrapTarget) {
      this.#attachTooltip(this.btnCreateWrapTarget);
    }

    // El botón de la prueba vive en el panel, fuera del contenedor de la tabla:
    // el setupTooltip() del base no lo alcanza y sin esto su data-tooltip —que es
    // donde dice qué falta para habilitarlo— no se vería (CLAUDE.md §33).
    if (this.hasBtnTestLicenseTarget) this.#attachTooltip(this.btnTestLicenseTarget);

    super.connect();   // construye la tabla y dispara la carga remota de la página 1
  }

  // ── Configuración Tabulator (paginación remota) ──────────────────────────────

  getTableConfig() {
    return {
      height: '100%',
      layout: 'fitColumns',
      movableRows: false,
      placeholder: 'No hay conexiones registradas',
      columnDefaults: { headerSort: false },

      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 15, 25],
      // paginationCounter custom — Tabulator calcula el total como last_page*pageSize, lo que
      // sobreestima cuando la última página no está llena. Usamos el total real del servidor.
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#totalRecords;
        if (!total) return '';
        const to = Math.min(currentRow + _pageSize - 1, total);
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      ajaxURL: '/api/connections',
      ajaxRequestFunc: (url, config, params) => this.#fetchPage(url, params),

      columns: this.getColumns(),
    };
  }

  getColumns() {
    const canEdit = this.#hasPerm('Configurations_Connections_Update');

    const columns = [
      { title: 'ID', field: 'Id', width: 80 },
      { title: 'Nombre', field: 'Name', widthGrow: 2 },
      { title: 'URL del Service Layer', field: 'SlUrl', widthGrow: 3, tooltip: true },
      {
        title: 'Licencia SAP', field: 'SapLicense', widthGrow: 2,
        formatter: (cell) => this.#licenseCell(cell.getRow().getData()),
      },
    ];

    // Columna Acciones siempre presente; el botón editar se deshabilita con
    // tooltip cuando falta el permiso (ver CLAUDE.md §26).
    columns.push({
      title: 'Acciones', field: 'Id', width: 100, hozAlign: 'center', headerSort: false,
      formatter: (cell) => this.#editButton(cell.getValue(), canEdit),
      cellClick: (e, cell) => {
        if (e.target.closest('[data-action-type="edit"]')) {
          this.#onEditClick(cell.getRow().getData());
        }
      },
    });

    return columns;
  }

  /**
   * Función de carga remota para Tabulator.
   * El endpoint nativo pagina por query string (página 1-indexed) y devuelve el
   * total real en el cuerpo (`Data.Total`), no en un header.
   * @param {string} url     ajaxURL configurada
   * @param {Object} params  { page (1-indexed), size, ... }
   * @returns {Promise<{data: Array, last_page: number}>}
   */
  async #fetchPage(url, params) {
    const size = params.size || 10;

    const qp = new URLSearchParams({
      name:     this.inputNameTarget.value.trim(),
      sl_url:   this.inputSlUrlTarget.value.trim(),
      page:     String(params.page || 1),
      per_page: String(size),
    });

    try {
      const { json } = await this.#apiFetch(`${url}?${qp}`);

      if (!json.Data) {
        showToast(json.Message || 'Error al obtener las conexiones', 'error');
        return { data: [], last_page: 1 };
      }

      const total = json.Data.Total ?? 0;
      this.#totalRecords = total;
      const lastPage = Math.max(1, Math.ceil(total / size));
      return { data: json.Data.Items ?? [], last_page: lastPage };
    } catch (err) {
      showToast(err.message || 'Error al obtener las conexiones', 'error');
      return { data: [], last_page: 1 };
    }
  }

  // ── Acciones públicas — lista ────────────────────────────────────────────────

  search() {
    this.table.setData();   // recarga vía ajax y vuelve a la página 1
  }

  // ── Panel lateral — crear / editar ───────────────────────────────────────────

  /** Abre el panel en modo creación. */
  openCreatePanel() {
    if (!this.#hasPerm('Configurations_Connections_Create')) {
      showToast('No cuenta con permisos para realizar esta acción.', 'info');
      return;
    }

    this.#editMode     = false;
    this.#connectionId = 0;

    this.#resetPanel();
    this.panelTitleTarget.textContent  = 'Nueva Conexión SAP';
    this.submitIconTarget.textContent  = 'check';
    this.submitLabelTarget.textContent = 'Crear conexión';

    this.#openPanel();
  }

  /** Abre el panel en modo edición y carga los datos de la conexión. */
  async #onEditClick(conn) {
    if (!this.#hasPerm('Configurations_Connections_Update')) {
      showToast('No cuenta con permisos para realizar esta acción.', 'info');
      return;
    }

    this.#editMode     = true;
    this.#connectionId = conn.Id;

    this.#resetPanel();
    this.panelTitleTarget.textContent  = 'Editar Conexión SAP';
    this.submitIconTarget.textContent  = 'autorenew';
    this.submitLabelTarget.textContent = 'Actualizar';

    this.#openPanel();

    // Se recarga desde el servidor en vez de usar la fila: la lista pudo quedar
    // vieja si otra persona editó la conexión mientras la tabla estaba abierta.
    try {
      const { json } = await this.#apiFetch(`/api/connections/${this.#connectionId}`);
      if (!json.Data) {
        showToast(json.Message || 'No se encontró la conexión', 'error');
        this.closePanel();
        return;
      }
      this.#fillPanel(json.Data);
    } catch (err) {
      showToast(err.message || 'Error al cargar la conexión', 'error');
      this.closePanel();
    }
  }

  closePanel() {
    this.panelTarget.classList.add('translate-x-full');
    this.panelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  /**
   * Habilita el botón de guardar solo cuando todos los campos requeridos están
   * completos, y sincroniza el botón de la prueba.
   *
   * Lo llama el `input->`/`change->` del contenedor del panel, así que corre con
   * cualquier tecla: es también donde se detecta que los valores dejaron de ser
   * los que se probaron.
   */
  refreshSubmitState() {
    this.submitBtnTarget.disabled = !this.#isFormValid();
    this.#syncTestLicenseBtn();
  }

  /** ¿Están completos todos los campos obligatorios del panel? */
  #isFormValid() {
    // Las credenciales de licencia son opcionales: la tabla las acepta nulas y
    // una conexión sin ellas sigue sirviendo para las pantallas, que usan las
    // credenciales personales de quien está en sesión. Sin ellas lo único que no
    // corre es la sincronización de fondo (Sap::CompanyClient).
    return this.fNameTarget.value.trim() !== '' && this.#isSlUrlValid();
  }

  /** La URL tiene que ser http(s), igual que valida el modelo del servidor. */
  #isSlUrlValid() {
    return /^https?:\/\//i.test(this.fSlUrlTarget.value.trim());
  }

  async savePanel() {
    if (!this.#validatePanel()) return;

    const payload  = this.#buildPayload();
    const isCreate = !this.#editMode;

    this.submitBtnTarget.disabled = true;
    try {
      // Crear va a la colección; actualizar, al recurso: el id viaja en el path,
      // no en el cuerpo como pedía el .NET (CLAUDE.md §28).
      const { json } = await this.#apiFetch(
        isCreate ? '/api/connections' : `/api/connections/${this.#connectionId}`,
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

      showToast(isCreate ? 'Conexión creada con éxito' : 'Conexión actualizada con éxito', 'success');
      this.closePanel();
      this.table.setData();   // refresca la lista sin recargar la página
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error', message: err.message });
    } finally {
      this.submitBtnTarget.disabled = false;
    }
  }

  // ── Panel — helpers ──────────────────────────────────────────────────────────

  #openPanel() {
    this.panelBackdropTarget.classList.remove('hidden');
    this.panelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  #resetPanel() {
    this.fNameTarget.value               = '';
    this.fSlUrlTarget.value              = '';
    this.fSapLicenseTarget.value         = '';
    this.fSapLicensePasswordTarget.value = '';
    this.fCompanyDbTarget.value          = '';
    this.fCompanyDbListTarget.replaceChildren();

    this.#hasStoredPassword   = false;
    this.#verifiedFingerprint = null;
    this.#isTesting           = false;
    this.#hideLicensePassword();
    this.fSapLicensePasswordHintTarget.classList.add('hidden');

    this.refreshSubmitState();

    [this.fNameErrorTarget, this.fSlUrlErrorTarget].forEach(e => e.classList.add('hidden'));
  }

  #fillPanel(conn) {
    this.fNameTarget.value       = conn.Name       ?? '';
    this.fSlUrlTarget.value      = conn.SlUrl      ?? '';
    this.fSapLicenseTarget.value = conn.SapLicense ?? '';

    // La contraseña no viene nunca — solo si existe. El campo queda en blanco y
    // el hint explica que dejarlo así la conserva.
    this.#hasStoredPassword = conn.HasSapLicensePassword === true;
    this.fSapLicensePasswordHintTarget.classList.toggle('hidden', !this.#hasStoredPassword);

    // Sugerencias para la base de la prueba: las bases de SAP de las compañías
    // que ya usan esta conexión. Con una sola, se preselecciona — es la única
    // respuesta posible y hacerla escribir no aporta nada.
    this.#fillSapDbOptions(conn.SapDbs ?? []);

    this.refreshSubmitState();
  }

  #fillSapDbOptions(dbs) {
    this.fCompanyDbListTarget.replaceChildren(
      ...dbs.map((db) => {
        const opt = document.createElement('option');
        opt.value = db;
        return opt;
      }),
    );

    if (dbs.length === 1) this.fCompanyDbTarget.value = dbs[0];
  }

  #validatePanel() {
    const nameEmpty  = !this.fNameTarget.value.trim();
    const urlInvalid = !this.#isSlUrlValid();

    this.fNameErrorTarget.classList.toggle('hidden', !nameEmpty);
    this.fSlUrlErrorTarget.classList.toggle('hidden', !urlInvalid);

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
      Name:               this.fNameTarget.value.trim(),
      SlUrl:              this.fSlUrlTarget.value.trim(),
      SapLicense:         this.fSapLicenseTarget.value.trim(),
      SapLicensePassword: this.fSapLicensePasswordTarget.value,
    };
  }

  // ── Credenciales de licencia — prueba contra el Service Layer ────────────────

  /** Toggle de visibilidad de la contraseña de licencia (CLAUDE.md §4). */
  toggleLicensePassword() {
    const input = this.fSapLicensePasswordTarget;
    const shown = input.type === 'text';
    input.type = shown ? 'password' : 'text';
    this.fEyeIconTarget.textContent = shown ? 'visibility_off' : 'visibility';
  }

  #hideLicensePassword() {
    this.fSapLicensePasswordTarget.type = 'password';
    this.fEyeIconTarget.textContent     = 'visibility_off';
  }

  /**
   * Comprueba las credenciales de licencia contra el Service Layer.
   *
   * Prueba lo que está EN EL FORMULARIO, no lo guardado: si alguien corrige la
   * URL y prueba, tiene que probarse la URL nueva. La única excepción es la
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
      // Responde 200 con Data true/false; el motivo del rechazo viene en Message
      // (mismo contrato que /api/sap_credential_validations).
      const { json } = await this.#apiFetch('/api/sap_license_validations', {
        method: 'POST',
        body: JSON.stringify({
          ConnectionId:       this.#editMode ? this.#connectionId : null,
          SlUrl:              this.fSlUrlTarget.value.trim(),
          SapLicense:         this.fSapLicenseTarget.value.trim(),
          SapLicensePassword: this.fSapLicensePasswordTarget.value,
          CompanyDb:          this.fCompanyDbTarget.value.trim(),
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
   * Motivo por el que todavía no se puede probar, o `null` si ya se puede.
   * Es lo mismo que alimenta el tooltip del botón deshabilitado (CLAUDE.md §2):
   * cada mensaje responde *¿cuándo SÍ podré usarlo?*.
   */
  #licenseTestBlocker() {
    if (!this.#isSlUrlValid())                     return 'Ingrese la URL del Service Layer para probar las credenciales';
    if (!this.fSapLicenseTarget.value.trim())      return 'Ingrese el usuario de licencia para probar las credenciales';
    if (!this.fSapLicensePasswordTarget.value && !this.#hasStoredPassword) {
      return 'Ingrese la contraseña de licencia para probar las credenciales';
    }
    if (!this.fCompanyDbTarget.value.trim())       return 'Indique la base de datos de SAP para probar las credenciales';

    return null;
  }

  /**
   * Valores de los que depende el resultado de la prueba. Se serializa con
   * `JSON.stringify` y no con un `join`: cualquier separador que se elija puede
   * aparecer dentro de una contraseña, y dos combinaciones distintas darían la
   * misma huella — el botón se quedaría en "verificadas" con otros valores.
   */
  #licenseFingerprint() {
    return JSON.stringify([
      this.fSlUrlTarget.value.trim(),
      this.fSapLicenseTarget.value.trim(),
      this.fSapLicensePasswordTarget.value,
      this.fCompanyDbTarget.value.trim(),
    ]);
  }

  /** Tres estados: probando / verificadas / por probar. Igual que el perfil. */
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
   * Mantiene `data-tooltip` (convención §2/§25) y `title` (fallback nativo)
   * sincronizados. El botón deshabilitado tiene que decir qué falta para poder
   * usarlo, no un genérico.
   */
  #setTip(el, text) {
    if (!el) return;
    el.dataset.tooltip = text;
    el.setAttribute('title', text);
  }

  // ── Render helpers ───────────────────────────────────────────────────────────

  /**
   * Celda "Licencia SAP". Muestra el usuario de licencia, y avisa cuando la
   * configuración quedó a medias.
   *
   * Un usuario sin contraseña no sirve para nada: `Connection#sap_license?` exige
   * las dos mitades y la sincronización de fondo se detiene con
   * `MissingConfiguration`. Sin el aviso, la fila se vería igual de configurada
   * que una completa — el usuario está ahí, la contraseña no se muestra nunca.
   */
  #licenseCell(conn) {
    const user = (conn.SapLicense ?? '').trim();

    if (!user) {
      return `<span class="text-gray-400 italic">Sin configurar</span>`;
    }

    if (!conn.HasSapLicensePassword) {
      return `
        <span class="inline-flex items-center gap-1.5"
              data-tooltip="La conexión tiene usuario de licencia pero no contraseña: la sincronización de documentos no puede autenticarse. Edite la conexión para completarla.">
          <span style="background-color:#fffbeb; color:#b45309;"
                class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
            <span class="material-icons" style="font-size:14px; line-height:1">warning</span>
            Falta la contraseña
          </span>
          <span class="text-gray-600">${this.#escape(user)}</span>
        </span>`;
    }

    return `<span class="text-gray-700">${this.#escape(user)}</span>`;
  }

  /** El usuario de licencia lo escribe una persona: va escapado antes del innerHTML. */
  #escape(value) {
    const div = document.createElement('div');
    div.textContent = value;
    return div.innerHTML;
  }

  // Botón editar: habilitado (azul) o deshabilitado (gris + tooltip envuelto en
  // <span>, porque un <button disabled> no emite eventos de mouse). Ver §26.
  #editButton(id, canEdit) {
    if (canEdit) {
      return `
        <button type="button" data-action-type="edit" data-testid="btn-edit-${id}" data-tooltip="Editar"
                class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
          <span class="material-icons text-base">edit</span>
        </button>`;
    }
    return `
      <span data-tooltip="No cuenta con permisos para editar conexiones">
        <button type="button" data-testid="btn-edit-${id}" disabled
                class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
          <span class="material-icons text-base">edit</span>
        </button>
      </span>`;
  }

  // ── Utilidades ─────────────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Nueva Conexión" (nace deshabilitado/gris con tooltip de
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

    return { json: await response.json(), headers: response.headers };
  }
}

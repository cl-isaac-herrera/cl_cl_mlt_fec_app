import { Controller } from '@hotwired/stimulus';
import { Storage, SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts';

/**
 * CompanyFormController — Crear / Editar compañía.
 *
 * Replica: Angular CreateOrUpdateCompanyComponent
 *
 * Modos:
 *   - create: companyIdValue = 0  → botón "Registrar" visible
 *   - edit:   companyIdValue > 0  → botones "Actualizar" por sección
 *
 * Storage (ver fec-migration-docs/STORAGE-KEY-MAPPING.md):
 *   - localStorage.Session          → { access_token, expires_at, ... }
 *   - sessionStorage.CurrentCompany → { companyId, companyName, groupId, ... }
 *   - sessionStorage.Permissions    → string[]  (e.g. ["Configurations_Companies_Create"])
 *
 * NOTA: CurrentFESession de Angular no existe en Rails.
 * El feToken se obtiene del mismo localStorage.Session (access_token).
 */
export default class extends Controller {
  static values = { companyId: Number };

  static targets = [
    // Sección 1 - Datos Generales
    'name',
    'legalName', 'legalNameError',
    'identificationType',
    'identification', 'identificationError',
    'codigoActividad', 'codigoActividadError',
    'nameToEmail',
    'freightCharges',
    'registrofiscal8707',
    'sapConnectionId',
    'btnAddConnection',
    'dbSap',
    'active',
    'btnSaveGeneralContainer', 'btnSaveGeneral', 'btnSaveGeneralWrap',

    // Sección 2 - Adicional
    'additionalInformation',
    'emailCcList',
    'btnAddEmail',
    'btnSaveAdditionalContainer',

    // Sección 3 - ATV
    'certPin', 'certPinEyeIcon',
    'certPath', 'certPathText',
    'certFileInput',
    'certExpireDate',
    'tokenUsr',
    'tokenPass', 'tokenPassEyeIcon',
    'btnSaveAtvContainer',

    // Sección 4 - Adjuntos
    'logoName', 'logoFileInput',
    'printFormatName', 'printFormatFileInput',
    'btnResetFormat',
    'btnSaveAttachmentsContainer',

    // Sección 5 - Códigos de actividad
    'sectionActivityCodes',
    'activityCodesList',
    'activityCodesEmpty',
    'activityCodesDupError',
    'btnSaveActivityCodes',

    // Sección 6 - SAP / Factura Proveedor
    'useFactProv',
    'sendReceptContainer', 'sendReceptAndApInv',
    'sapFieldsGroup',
    'numSerieProv', 'numSerieFactProv',
    'defaultTaxForXml',
    'whDefault',
    'btnAddTolerance',
    'xmlToleranceList', 'xmlToleranceEmpty', 'tolerancesDupError',
    'btnAddCurrencyMapping',
    'currencyMappingList', 'currencyMappingEmpty', 'currencyMappingsDupError',
    'btnReloadSap',
    'btnSaveSap',
    'sapErrorIcon', 'sapErrorDetail',

    // Loaders de sección
    'loaderGeneral', 'loaderAdditional', 'loaderAtv', 'loaderAttachments', 'loaderActivityCodes', 'loaderSap',

    // Botón registrar
    'btnRegisterContainer', 'btnRegister',

    // Panel lateral — confirmación de reset (no hay modales custom)

    // Panel lateral — crear conexión SAP
    'connPanel', 'connPanelBackdrop',
    'connName', 'connNameError',
    'connSlUrl', 'connSlUrlError',
    'connSlType',
    'connSaveBtn',
  ];

  // ── Estado interno ─────────────────────────────────────────────────────────

  #isEditing              = false;
  #selectedCertFile       = null;
  #selectedLogoFile       = null;
  #selectedPrintFormatFile = null;
  #oldCertPin             = '';
  #emailCcItems           = [];
  #xmlTolerances          = [];
  #currencyMappings       = [];
  #activityCodes          = [];
  #currenciesList         = [];
  #taxCodeList            = [];
  #warehouseList          = [];
  #companyData            = null;
  #permissions            = [];   // string[]
  #selectedCompany        = null;
  // Valores de la sección "Datos Generales" tal como se cargaron. Es la
  // referencia contra la que se decide si hay algo que guardar.
  #generalSnapshot        = null;

  #ideRules = {
    '01': { min: 9,  max: 9  },
    '02': { min: 10, max: 10 },
    '03': { min: 11, max: 12 },
    '04': { min: 10, max: 10 },
  };

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  connect() {
    this.#onLoad();
  }

  // ── Inicialización ─────────────────────────────────────────────────────────

  #onLoad() {
    this.#isEditing       = this.companyIdValue > 0;
    this.#permissions     = SStore.get('Permissions') || [];   // string[]
    this.#selectedCompany = SStore.get('CurrentCompany') || {};

    this.#setupMode();
    this.#initEmailCc();

    if (this.#isEditing) {
      this.#loadCompanyInformation();
    } else {
      this.#loadInitialData();
    }
  }

  #setupMode() {
    if (this.#isEditing) {
      // Edit: mostrar loaders de sección mientras carga
      this.#showSectionLoaders();

      // Edit: mostrar botones "Actualizar" por sección
      this.btnSaveGeneralContainerTarget.classList.remove('hidden');
      this.btnSaveAdditionalContainerTarget.classList.remove('hidden');
      this.btnSaveAtvContainerTarget.classList.remove('hidden');
      this.btnSaveAttachmentsContainerTarget.classList.remove('hidden');
      this.sectionActivityCodesTarget.classList.remove('hidden');
      this.btnSaveSapTarget.classList.remove('hidden');
      this.btnRegisterContainerTarget.classList.add('hidden');

      if (this.#hasPerm('F_ResetCompanyFormat')) {
        this.btnResetFormatTarget.classList.remove('hidden');
      }
      if (this.#hasPerm('Configurations_Connections_Create')) {
        this.btnAddConnectionTarget.classList.remove('hidden');
      }

      // Edit: UseFactProv habilitado (SAP data disponible)
      this.useFactProvTarget.disabled = false;
      this.useFactProvTarget.removeAttribute('title');
    } else {
      // Create: UseFactProv deshabilitado hasta guardar la compañía
      this.useFactProvTarget.disabled = true;
      this.useFactProvTarget.closest('label').title =
        'Esta opción estará disponible una vez que la compañía haya sido registrada.';

      this.btnRegisterContainerTarget.classList.remove('hidden');
      this.btnRegisterContainerTarget.classList.add('flex');
    }
  }

  #initEmailCc() {
    this.#emailCcItems = [''];
    this.#renderEmailCc();
  }

  // ── Carga de datos ─────────────────────────────────────────────────────────

  async #loadInitialData() {
    try {
      // El .NET pedía además `GET /api/Group/GetGroups` para el select "Cuenta".
      // No se migró: no hay grupos en esta versión (CLAUDE.md §31), así que el
      // campo se eliminó junto con la consulta que lo alimentaba (§24).
      const sapResp = await this.#apiFetch('/api/connections/assignable');

      if (sapResp.Data) this.#fillSapConnectionsSelect(sapResp.Data);

      this.#validateForm();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Se produjo un error al obtener la información', message: err.message });
    }
  }

  /**
   * Carga de la pantalla de edición.
   *
   * Solo se piden los datos de la sección que está migrada. Las consultas de las
   * otras secciones (`warehouse`, `Tax`, `currencies`, `currency-map`,
   * `activity-codes`) se quitaron: van al proxy .NET, que hoy responde 401, así
   * que no llenaban nada — solo sumaban cinco peticiones fallidas y demoraban el
   * cierre del loader. Vuelven cuando se migre cada sección (TODOS.md →
   * Compañías).
   *
   * Cada loader se oculta cuando resuelve LO SUYO, no cuando resuelven todas: el
   * `Promise.allSettled` + un único `hideSectionLoaders()` hacía que la sección
   * de datos generales siguiera girando por culpa de consultas ajenas.
   */
  async #loadCompanyInformation() {
    const companyId = this.companyIdValue;

    // El select de conexiones es parte de la sección general, así que su loader
    // tiene que esperarlo también. Las dos peticiones van en paralelo.
    const connections = this.#railsFetch('/api/connections/assignable')
      .then(resp => { if (resp.Data) this.#fillSapConnectionsSelect(resp.Data); })
      .catch(err => showToast(`No se pudieron cargar las conexiones de SAP: ${err.message}`, 'error'));

    const general = this.#railsFetch(`/api/companies/${companyId}`)
      .then((resp) => {
        if (!resp.Data) throw new Error(resp.Message || 'Error desconocido');
        this.#companyData = resp.Data;
      })
      .catch((err) => {
        showAlert({
          type:    ALERT_TYPES.ERROR,
          title:   'Se produjo un error al obtener la información de la compañía',
          message: err.message,
        });
      });

    try {
      // El orden importa: las conexiones tienen que estar en el <select> antes de
      // aplicarle el valor de la compañía, o el `select.value = …` no encuentra
      // la opción y queda en blanco.
      await Promise.all([connections, general]);
      if (this.#companyData) this.#fillGeneralSection(this.#companyData);
    } finally {
      this.#hideLoader(this.loaderGeneralTarget);
    }
  }

  // Solo se muestra el loader de la sección que realmente carga algo. Las demás
  // no piden nada todavía: dejarlas girando diría que están esperando datos.
  #showSectionLoaders() {
    this.#showLoader(this.loaderGeneralTarget);
  }

  #showLoader(loaderTarget) { loaderTarget?.classList.remove('hidden'); }
  #hideLoader(loaderTarget) { loaderTarget?.classList.add('hidden'); }

  /**
   * Llena la sección "Datos Generales" con la respuesta de
   * GET /api/companies/:id. Todo viene de la tabla `companies`: el bloque del
   * emisor ante Hacienda estuvo un tiempo como UDFs de `OADM` y volvió a la base
   * de la aplicación, así que ya no hay que ir a SAP para pintar el formulario.
   *
   * Las claves del emisor conservan el vocabulario del XML de Hacienda
   * (`EmsrNombre`, `CodigoActividad`) aunque las columnas se llamen en inglés
   * (`issuer_legal_name`, `economic_activity_code`): la traducción la hace
   * `serialize_detail` del controller.
   *
   * Las demás secciones (adicional, ATV, adjuntos, códigos de actividad,
   * factura a proveedor) todavía no se migraron y por eso no se llenan acá.
   */
  #fillGeneralSection(data) {
    this.nameTarget.value           = data.Name || '';
    this.dbSapTarget.value          = data.SapDb || '';
    this.nameToEmailTarget.value    = String(data.EmailSenderType ?? 1);
    this.freightChargesTarget.value = String(data.FreightType ?? 1);
    this.activeTarget.checked       = data.Active !== false;

    if (data.ConnectionId) this.sapConnectionIdTarget.value = String(data.ConnectionId);

    // `EmsrNombreComercial` llega en la respuesta pero no se pinta: es el mismo
    // valor que `Name`, que ya está en el campo "Nombre".
    this.legalNameTarget.value          = data.EmsrNombre             || '';
    this.identificationTypeTarget.value = data.EmsrIdeTipo            || '01';
    this.identificationTarget.value     = data.EmsrIdeNumero          || '';
    this.codigoActividadTarget.value    = data.CodigoActividad        || '';
    this.registrofiscal8707Target.value = data.EmsrRegistroFiscal8707 || '';

    this.#applyIdentificationRules(data.EmsrIdeTipo || '01');

    // La foto se toma DESPUÉS de llenar: es el estado "sin cambios".
    this.#generalSnapshot = this.#generalValues();
    this.#validateForm();
  }

  /**
   * Los valores actuales de la sección "Datos Generales", normalizados a texto
   * para poder compararlos contra la foto inicial. El orden no importa: se
   * compara llave por llave.
   */
  #generalValues() {
    return {
      name:               this.nameTarget.value.trim(),
      legalName:          this.legalNameTarget.value.trim(),
      identificationType: this.identificationTypeTarget.value,
      identification:     this.identificationTarget.value.trim(),
      codigoActividad:    this.codigoActividadTarget.value.trim(),
      registrofiscal8707: this.registrofiscal8707Target.value.trim(),
      nameToEmail:        this.nameToEmailTarget.value,
      freightCharges:     this.freightChargesTarget.value,
      sapConnectionId:    this.sapConnectionIdTarget.value,
      dbSap:              this.dbSapTarget.value.trim(),
      active:             String(this.activeTarget.checked),
    };
  }

  /** ¿Cambió algo en la sección respecto a lo que se cargó? */
  #generalIsDirty() {
    if (!this.#generalSnapshot) return false;

    const current = this.#generalValues();
    return Object.keys(current).some(key => current[key] !== this.#generalSnapshot[key]);
  }

  /**
   * Habilita "Actualizar datos generales" solo si hay algo que actualizar en ESA
   * sección. Sin cambios queda inhabilitado, con el motivo en el tooltip.
   *
   * El `data-tooltip` va en el <span> envolvente porque un <button disabled> no
   * emite eventos de mouse (CLAUDE.md §2 y §26); por eso el botón lleva
   * `pointer-events-none` mientras está deshabilitado y se lo quita al
   * habilitarse.
   */
  #refreshGeneralSaveState() {
    if (!this.hasBtnSaveGeneralTarget) return;

    const reason = this.#generalSaveBlockedReason();
    const btn    = this.btnSaveGeneralTarget;

    btn.disabled = !!reason;
    btn.classList.toggle('pointer-events-none', !!reason);
    btn.classList.toggle('cursor-not-allowed', !!reason);
    btn.classList.toggle('bg-gray-300',  !!reason);
    btn.classList.toggle('text-gray-500', !!reason);
    btn.classList.toggle('bg-blue-600',  !reason);
    btn.classList.toggle('text-white',   !reason);
    btn.classList.toggle('hover:bg-blue-700', !reason);

    if (this.hasBtnSaveGeneralWrapTarget) {
      this.btnSaveGeneralWrapTarget.dataset.tooltip =
        reason || 'Actualizar los datos generales de la compañía';
    }
  }

  /**
   * Por qué NO se puede guardar la sección, o null si sí se puede. El texto es
   * el del tooltip, así que tiene que responder "¿cuándo sí podré usarlo?"
   * (CLAUDE.md §2).
   * @returns {?string}
   */
  #generalSaveBlockedReason() {
    if (!this.#generalIsDirty()) return 'No hay cambios por guardar en esta sección';
    if (!this.#validateGeneralForm()) {
      return 'Complete los campos requeridos de la sección para poder guardar';
    }

    return null;
  }

  // ── Rellenar selects ───────────────────────────────────────────────────────

  #fillSapConnectionsSelect(connections) {
    const select  = this.sapConnectionIdTarget;
    const current = select.value;
    select.innerHTML = '';
    connections.forEach(c => {
      const opt = document.createElement('option');
      opt.value = String(c.Id);
      opt.textContent = c.Name;
      select.appendChild(opt);
    });
    if (current) select.value = current;
  }

  #fillTaxSelect() {
    const select  = this.defaultTaxForXmlTarget;
    const current = select.value;
    select.innerHTML = '<option value="">-- seleccionar --</option>';
    this.#taxCodeList.forEach(t => {
      const opt = document.createElement('option');
      opt.value = t.TaxCode;
      opt.textContent = t.TaxCode;
      select.appendChild(opt);
    });
    if (current) select.value = current;
  }

  #fillWarehouseSelect() {
    const select  = this.whDefaultTarget;
    const current = select.value;
    select.innerHTML = '<option value="">-- seleccionar --</option>';
    this.#warehouseList.forEach(w => {
      const opt = document.createElement('option');
      opt.value = w.WhCode;
      opt.textContent = w.WhName;
      select.appendChild(opt);
    });
    if (current) select.value = current;
  }

  // ── Acciones formulario ────────────────────────────────────────────────────

  onFormChange() { this.#validateForm(); }

  onIdentificationTypeChange() {
    this.#applyIdentificationRules(this.identificationTypeTarget.value);
    this.#validateForm();
  }

  /** Formatea fecha como yyyy-MM-dd HH:mm:ss (igual que DATE_TIME_FORMAT del legacy Angular) */
  #formatDateTime(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  #applyIdentificationRules(type) {
    const rules = this.#ideRules[type] ?? { min: 9, max: 9 };
    // setAttribute evita el error de orden min/max al cambiar tipo de identificación:
    // el browser lanza excepción si se asigna minLength > maxLength actual vía propiedad DOM.
    this.identificationTarget.setAttribute('maxlength', String(rules.max));
    this.identificationTarget.setAttribute('minlength', String(rules.min));
  }

  onUseFactProvChange() {
    if (this.useFactProvTarget.checked) {
      this.#enableSapFields();
      this.sendReceptContainerTarget.classList.remove('hidden');
      this.sendReceptContainerTarget.classList.add('flex');
    } else {
      this.#disableSapFields();
      this.sendReceptContainerTarget.classList.add('hidden');
      this.sendReceptContainerTarget.classList.remove('flex');
    }
    this.#validateForm();
  }

  #enableSapFields() {
    this.sapFieldsGroupTarget
      .querySelectorAll('input, select, button')
      .forEach(el => { el.disabled = false; });

    // En edición, DefaultTaxForXML y whDefault son required (datos SAP disponibles).
    // En creación no aplica porque la empresa aún no tiene conexión SAP activa.
    if (this.#isEditing) {
      this.defaultTaxForXmlTarget.required = true;
      this.whDefaultTarget.required        = true;
    }
    // NumSerieProv siempre required cuando UseFactProv=true
    this.numSerieProvTarget.required = true;
  }

  #disableSapFields() {
    this.sapFieldsGroupTarget
      .querySelectorAll('input, select')
      .forEach(el => { el.disabled = true; });
    this.btnAddToleranceTarget.disabled       = true;
    this.btnAddCurrencyMappingTarget.disabled = true;

    // Quitar required al deshabilitar
    this.numSerieProvTarget.required    = false;
    this.defaultTaxForXmlTarget.required = false;
    this.whDefaultTarget.required        = false;
  }

  // ── Toggle passwords ───────────────────────────────────────────────────────

  toggleCertPin() {
    const input = this.certPinTarget;
    const icon  = this.certPinEyeIconTarget;
    input.type       = input.type === 'password' ? 'text' : 'password';
    icon.textContent = input.type === 'password' ? 'visibility_off' : 'visibility';
  }

  toggleTokenPass() {
    const input = this.tokenPassTarget;
    const icon  = this.tokenPassEyeIconTarget;
    input.type       = input.type === 'password' ? 'text' : 'password';
    icon.textContent = input.type === 'password' ? 'visibility_off' : 'visibility';
  }

  // ── Certificado ────────────────────────────────────────────────────────────

  onCertPinClick() { this.#oldCertPin = this.certPinTarget.value; }

  onCertPinBlur()  { this.#changeCertPin(this.certPinTarget.value); }
  onCertPinEnter() { this.#changeCertPin(this.certPinTarget.value); }

  #changeCertPin(newPin) {
    if (this.#oldCertPin !== newPin && this.#selectedCertFile && newPin) {
      this.#oldCertPin = newPin;
      this.#getCertExpireDate();
    }
  }

  triggerCertUpload() { this.certFileInputTarget.click(); }

  onCertFileSelected() {
    const file = this.certFileInputTarget.files[0];
    if (!file) { this.certPathTarget.value = ''; this.certPathTextTarget.value = ''; return; }

    if (!file.name.endsWith('.p12') && !file.name.endsWith('.pfx')) {
      this.certFileInputTarget.value = '';
      showToast('Seleccione un certificado con extensión válida (.p12 o .pfx).', 'error');
      return;
    }

    this.#selectedCertFile        = file;
    this.certPathTarget.value     = file.name;
    this.certPathTextTarget.value = file.name;

    if (!this.certPinTarget.value) {
      showAlert({ type: ALERT_TYPES.WARNING, title: 'Pin requerido', message: 'Para obtener la fecha de expiración del certificado debe colocar el PIN.' });
      return;
    }
    this.#getCertExpireDate();
  }

  async #getCertExpireDate() {
    const pin  = this.certPinTarget.value;
    const file = this.#selectedCertFile;
    if (!pin || !file) return;

    const fd = new FormData();
    fd.append('file', file);

    try {
      const resp = await fetch(
        `/api/Companies/CheckCertExpireDate?CertPin=${encodeURIComponent(pin)}`,
        { method: 'POST', headers: this.#authHeaders(), body: fd }
      );
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const json = await resp.json();

      this.certExpireDateTarget.value = json.Data?.CertExpireDate
        ? this.#formatDateTime(json.Data.CertExpireDate)
        : '';

      if (!json.Data?.CertExpireDate) {
        showAlert({ type: ALERT_TYPES.WARNING, title: 'Certificado', message: json.Message || 'No se pudo obtener la fecha de expiración.' });
      }
    } catch (err) {
      this.certExpireDateTarget.value = '';
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error de certificado', message: err.message });
    }
  }

  async downloadCertificate() {
    await this.#downloadBlob(
      `/api/companies/${this.companyIdValue}/certificate`,
      this.certPathTarget.value || 'certificado.pfx'
    );
  }

  // ── Logo ───────────────────────────────────────────────────────────────────

  triggerLogoUpload() { this.logoFileInputTarget.click(); }

  onLogoSelected() {
    const file = this.logoFileInputTarget.files[0];
    if (!file) { this.logoNameTarget.value = ''; return; }
    const ext = file.name.split('.').pop().toLowerCase();
    if (!['jpg', 'jpeg', 'png'].includes(ext)) {
      this.logoFileInputTarget.value = '';
      showToast('Seleccione un logo con formato válido (JPG, JPEG o PNG).', 'error');
      return;
    }
    this.#selectedLogoFile    = file;
    this.logoNameTarget.value = file.name;
  }

  async downloadLogo() {
    await this.#downloadBlob(
      `/api/companies/${this.companyIdValue}/logo`,
      this.logoNameTarget.value || 'logo.png'
    );
  }

  // ── Formato de impresión ───────────────────────────────────────────────────

  triggerPrintFormatUpload() { this.printFormatFileInputTarget.click(); }

  onPrintFormatSelected() {
    const file = this.printFormatFileInputTarget.files[0];
    if (!file) { this.printFormatNameTarget.value = ''; return; }
    if (!file.name.endsWith('.rpt')) {
      this.printFormatFileInputTarget.value = '';
      showToast('Seleccione un formato de impresión válido (.rpt).', 'error');
      return;
    }
    this.#selectedPrintFormatFile   = file;
    this.printFormatNameTarget.value = file.name;
  }

  async downloadPrintFormat() {
    await this.#downloadBlob(
      `/api/companies/${this.companyIdValue}/print-format`,
      this.printFormatNameTarget.value || 'formato-impresion.rpt'
    );
  }

  async resetPrintFormat() {
    const confirmed = await confirm(
      'Esta acción restablecerá el formato de impresión de la compañía al por defecto. ¿Desea continuar?',
      'Restablecer formato'
    );
    if (!confirmed) return;
    try {
      await this.#apiFetch(
        `/api/Companies/ResetCompanyPrintFormat?companyId=${this.companyIdValue}`,
        { method: 'PATCH' }
      );
      showToast('Formato de impresión restablecido con éxito', 'success');
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al restablecer formato', message: err.message });
    }
  }

  // ── EmailCC dinámico ───────────────────────────────────────────────────────

  addEmail() {
    this.#emailCcItems.push('');
    this.#renderEmailCc();
  }

  removeEmail(event) {
    const idx = parseInt(event.currentTarget.dataset.index);
    if (this.#emailCcItems.length === 1) {
      showAlert({ type: ALERT_TYPES.WARNING, message: 'No se puede eliminar el último registro del correo copia' });
      return;
    }
    this.#emailCcItems.splice(idx, 1);
    this.#renderEmailCc();
  }

  #renderEmailCc() {
    const container = this.emailCcListTarget;
    container.innerHTML = '';
    this.#emailCcItems.forEach((email, i) => {
      const row = document.createElement('div');
      row.className = 'flex items-center gap-2';
      row.innerHTML = `
        <input type="email"
               data-testid="email-cc-input"
               value="${this.#esc(email)}"
               placeholder="correo@ejemplo.com"
               class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
        <button type="button"
                data-index="${i}"
                data-testid="btn-remove-email-${i}"
                class="p-1.5 text-red-500 hover:bg-red-50 rounded transition-colors">
          <span class="material-icons text-base">remove</span>
        </button>
      `;
      row.querySelector('input').addEventListener('input', e => { this.#emailCcItems[i] = e.target.value; });
      row.querySelector('button').addEventListener('click', e => this.removeEmail(e));
      container.appendChild(row);
    });
  }

  // ── Códigos de actividad ───────────────────────────────────────────────────

  addActivityCode() {
    this.#activityCodes.push({ Code: '', Name: '' });
    this.#renderActivityCodes();
  }

  removeActivityCode(event) {
    const idx = parseInt(event.currentTarget.dataset.index);
    this.#activityCodes.splice(idx, 1);
    this.#renderActivityCodes();
  }

  #renderActivityCodes() {
    const container = this.activityCodesListTarget;
    container.innerHTML = '';

    if (!this.#activityCodes.length) {
      this.activityCodesEmptyTarget.classList.remove('hidden');
      return;
    }
    this.activityCodesEmptyTarget.classList.add('hidden');

    this.#activityCodes.forEach((item, i) => {
      const row = document.createElement('div');
      row.className = 'flex items-center gap-2';
      row.setAttribute('data-testid', 'activity-code-row');
      row.innerHTML = `
        <input type="text" placeholder="Código (6)" maxlength="6" minlength="6"
               value="${this.#esc(item.Code)}"
               class="w-32 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
        <input type="text" placeholder="Nombre"
               value="${this.#esc(item.Name)}"
               class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
        <button type="button" data-index="${i}"
                class="p-1.5 text-red-500 hover:bg-red-50 rounded transition-colors">
          <span class="material-icons text-base">delete_outline</span>
        </button>
      `;
      const [codeInput, nameInput] = row.querySelectorAll('input');
      codeInput.addEventListener('input', e => { this.#activityCodes[i].Code = e.target.value; this.#validateActivityCodes(); });
      nameInput.addEventListener('input', e => { this.#activityCodes[i].Name = e.target.value; });
      row.querySelector('button').addEventListener('click', e => this.removeActivityCode(e));
      container.appendChild(row);
    });
    this.#validateActivityCodes();
  }

  #validateActivityCodes() {
    const codes  = this.#activityCodes.map(a => a.Code).filter(Boolean);
    const dupErr = codes.length !== new Set(codes).size;
    this.activityCodesDupErrorTarget.classList.toggle('hidden', !dupErr);
    return !dupErr;
  }

  async saveActivityCodes() {
    if (!this.#validateActivityCodes()) {
      showToast('Revise los códigos de actividad (duplicados).', 'error');
      return;
    }
    this.#showLoader(this.loaderActivityCodesTarget);
    try {
      await this.#apiFetch(`/api/Companies/${this.companyIdValue}/activity-codes`, {
        method: 'PUT',
        body:   JSON.stringify(this.#activityCodes.map(({ Code, Name }) => ({ Code, Name }))),
      });
      showToast('Códigos de actividad actualizados con éxito.', 'success');
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al actualizar códigos de actividad', message: err.message });
    } finally {
      this.#hideLoader(this.loaderActivityCodesTarget);
    }
  }

  // ── Tolerancias XML ────────────────────────────────────────────────────────

  addXmlTolerance() {
    this.#xmlTolerances.push({ Tolerance: 0, CurrencyCode: '' });
    this.#renderXmlTolerances();
  }

  removeXmlTolerance(event) {
    this.#xmlTolerances.splice(parseInt(event.currentTarget.dataset.index), 1);
    this.#renderXmlTolerances();
  }

  #renderXmlTolerances() {
    const container = this.xmlToleranceListTarget;
    container.innerHTML = '';

    if (!this.#xmlTolerances.length) {
      this.xmlToleranceEmptyTarget.classList.remove('hidden');
      this.#validateTolerances();
      return;
    }
    this.xmlToleranceEmptyTarget.classList.add('hidden');

    this.#xmlTolerances.forEach((item, i) => {
      const row = document.createElement('div');
      row.className = 'flex items-center gap-2';
      row.setAttribute('data-testid', 'xml-tolerance-row');
      row.innerHTML = `
        <select class="w-40 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
          ${this.#currenciesList.map(c =>
            `<option value="${this.#esc(c.Code)}" ${c.Code === item.CurrencyCode ? 'selected' : ''}>${this.#esc(c.Code)} — ${this.#esc(c.Name)}</option>`
          ).join('')}
        </select>
        <input type="number" min="0" value="${item.Tolerance}" placeholder="Tolerancia"
               class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
        <button type="button" data-index="${i}" data-testid="btn-remove-tolerance-${i}"
                class="p-1.5 text-red-500 hover:bg-red-50 rounded transition-colors">
          <span class="material-icons text-base">delete_outline</span>
        </button>
      `;
      row.querySelector('select').addEventListener('change', e => { this.#xmlTolerances[i].CurrencyCode = e.target.value; this.#validateTolerances(); });
      row.querySelector('input').addEventListener('input', e => { this.#xmlTolerances[i].Tolerance = parseFloat(e.target.value) || 0; });
      row.querySelector('button').addEventListener('click', e => this.removeXmlTolerance(e));
      container.appendChild(row);
    });
    this.#validateTolerances();
  }

  #validateTolerances() {
    const codes  = this.#xmlTolerances.map(t => t.CurrencyCode).filter(Boolean);
    const dupErr = codes.length !== new Set(codes).size;
    this.tolerancesDupErrorTarget.classList.toggle('hidden', !dupErr);
    return !dupErr;
  }

  // ── Mapeo de monedas ───────────────────────────────────────────────────────

  addCurrencyMapping() {
    this.#currencyMappings.push({ Id: 0, XmlCurrencyCode: '', MappedCurrencyCode: '' });
    this.#renderCurrencyMappings();
  }

  removeCurrencyMapping(event) {
    this.#currencyMappings.splice(parseInt(event.currentTarget.dataset.index), 1);
    this.#renderCurrencyMappings();
  }

  #renderCurrencyMappings() {
    const container = this.currencyMappingListTarget;
    container.innerHTML = '';

    if (!this.#currencyMappings.length) {
      this.currencyMappingEmptyTarget.classList.remove('hidden');
      return;
    }
    this.currencyMappingEmptyTarget.classList.add('hidden');

    this.#currencyMappings.forEach((item, i) => {
      const row = document.createElement('div');
      row.className = 'flex items-center gap-2';
      row.setAttribute('data-testid', 'currency-mapping-row');
      row.innerHTML = `
        <input type="text" placeholder="Moneda XML" value="${this.#esc(item.XmlCurrencyCode)}"
               class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
        <select class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">
          ${this.#currenciesList.map(c =>
            `<option value="${this.#esc(c.Code)}" ${c.Code === item.MappedCurrencyCode ? 'selected' : ''}>${this.#esc(c.Code)} — ${this.#esc(c.Name)}</option>`
          ).join('')}
        </select>
        <button type="button" data-index="${i}"
                class="p-1.5 text-red-500 hover:bg-red-50 rounded transition-colors">
          <span class="material-icons text-base">delete_outline</span>
        </button>
      `;
      row.querySelector('input').addEventListener('input', e => { this.#currencyMappings[i].XmlCurrencyCode = e.target.value; this.#validateCurrencyMappings(); });
      row.querySelector('select').addEventListener('change', e => { this.#currencyMappings[i].MappedCurrencyCode = e.target.value; });
      row.querySelector('button').addEventListener('click', e => this.removeCurrencyMapping(e));
      container.appendChild(row);
    });
  }

  #validateCurrencyMappings() {
    const codes  = this.#currencyMappings.map(m => m.XmlCurrencyCode).filter(Boolean);
    const dupErr = codes.length !== new Set(codes).size;
    this.currencyMappingsDupErrorTarget.classList.toggle('hidden', !dupErr);
    return !dupErr;
  }

  // ── Errores de listas SAP (almacén, impuestos, monedas) ─────────────────────

  #collectSapListErrors(warehouseResp, taxResp, currenciesResp) {
    const errors = [];
    if (warehouseResp.status  === 'rejected') errors.push(`Almacenes: ${warehouseResp.reason?.message || 'error desconocido'}`);
    if (taxResp.status        === 'rejected') errors.push(`Impuestos: ${taxResp.reason?.message || 'error desconocido'}`);
    if (currenciesResp.status === 'rejected') errors.push(`Monedas: ${currenciesResp.reason?.message || 'error desconocido'}`);
    return errors;
  }

  // Muestra/oculta el ícono rojo palpitante en el encabezado de la sección y
  // rellena el tooltip con el detalle de las consultas que fallaron.
  #setSapListError(errors) {
    if (!this.hasSapErrorIconTarget) return;
    if (errors?.length) {
      this.sapErrorDetailTarget.textContent = errors.join('\n');
      this.sapErrorIconTarget.classList.remove('hidden');
    } else {
      this.sapErrorDetailTarget.textContent = '';
      this.sapErrorIconTarget.classList.add('hidden');
    }
  }

  // ── Recargar listas SAP ────────────────────────────────────────────────────

  async reloadSapDependentLists() {
    const companyId = this.companyIdValue;
    if (!companyId) return;
    try {
      const [warehouseResp, taxResp, currenciesResp] = await Promise.allSettled([
        this.#apiFetch(`/api/warehouse?companyId=${companyId}`),
        this.#apiFetch(`/api/Tax?companyId=${companyId}`),
        this.#apiFetch(`/api/Companies/${companyId}/currencies`),
      ]);
      if (warehouseResp.status === 'fulfilled' && warehouseResp.value?.Data?.length) {
        this.#warehouseList = warehouseResp.value.Data; this.#fillWarehouseSelect();
      }
      if (taxResp.status === 'fulfilled' && taxResp.value?.Data?.length) {
        this.#taxCodeList = taxResp.value.Data; this.#fillTaxSelect();
      }
      if (currenciesResp.status === 'fulfilled' && currenciesResp.value?.Data?.length) {
        this.#currenciesList = currenciesResp.value.Data;
        this.#renderXmlTolerances();
        this.#renderCurrencyMappings();
      }

      // allSettled nunca rechaza: hay que inspeccionar cada resultado para reportar fallos.
      const sapListErrors = this.#collectSapListErrors(warehouseResp, taxResp, currenciesResp);
      this.#setSapListError(sapListErrors);
      if (sapListErrors.length) {
        showToast('No se pudieron cargar los datos para factura proveedor', 'error');
        return;
      }
      showToast('Información recargada correctamente', 'success');
    } catch (err) {
      showToast(`Error al recargar: ${err.message}`, 'error');
    }
  }

  // ── Guardar por sección ────────────────────────────────────────────────────

  /**
   * Guarda SOLO la sección "Datos Generales", contra su propio endpoint.
   *
   * Cada sección tiene el suyo (`PATCH /api/companies/:id/general`), así que este
   * botón no puede pisar el certificado ni los adjuntos ni nada de otra sección.
   * El .NET mandaba las 42 columnas en cada guardado y apretar "Actualizar" en
   * una sección reescribía todas las demás con lo que hubiera en pantalla.
   *
   * ⚠️ NO usa `#sendEditRequest` ni `#buildCompanyFormData`: esos son el camino
   * viejo al .NET, y los siguen usando las secciones que no se migraron.
   */
  async saveGeneralData() {
    // Defensa en profundidad: la UI ya deshabilita el botón, pero se puede
    // manipular (CLAUDE.md §26).
    const blocked = this.#generalSaveBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    this.#showLoader(this.loaderGeneralTarget);
    try {
      const json = await this.#railsFetch(
        `/api/companies/${this.companyIdValue}/general`,
        { method: 'PATCH', body: JSON.stringify(this.#generalPayload()) },
      );

      // Se repinta con lo que quedó guardado, no con lo que había en pantalla: el
      // servidor normaliza (los vacíos pasan a NULL) y así el formulario muestra
      // el estado real.
      if (json.Data) {
        this.#companyData = { ...this.#companyData, ...json.Data };
        this.#fillGeneralSection(this.#companyData);
      }

      showToast(json.Message || 'Datos generales actualizados con éxito.', 'success');
    } catch (err) {
      // Error de escritura → modal, no toast (CLAUDE.md §9).
      showAlert({
        type:    ALERT_TYPES.ERROR,
        title:   'Error al guardar datos generales',
        message: err.message,
      });
    } finally {
      this.#hideLoader(this.loaderGeneralTarget);
    }
  }

  /**
   * El cuerpo del PATCH de la sección: exactamente los campos que la sección
   * ofrece, con las claves que el endpoint acepta. Tiene que cubrir lo mismo que
   * `#generalValues()`, que es lo que decide si hay cambios que guardar.
   */
  #generalPayload() {
    return {
      Name:                   this.nameTarget.value.trim(),
      Active:                 this.activeTarget.checked,
      ConnectionId:           this.sapConnectionIdTarget.value || null,
      SapDb:                  this.dbSapTarget.value.trim(),
      EmailSenderType:        this.nameToEmailTarget.value,
      FreightType:            this.freightChargesTarget.value,
      EmsrNombre:             this.legalNameTarget.value.trim(),
      EmsrIdeTipo:            this.identificationTypeTarget.value,
      EmsrIdeNumero:          this.identificationTarget.value.trim(),
      CodigoActividad:        this.codigoActividadTarget.value.trim(),
      EmsrRegistroFiscal8707: this.registrofiscal8707Target.value.trim(),
    };
  }

  async saveAdditionalData() {
    this.#showLoader(this.loaderAdditionalTarget);
    try {
      await this.#sendEditRequest(5);
      showToast('Información adicional actualizada con éxito.', 'success');
    } catch (err) { showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar información adicional', message: err.message }); }
    finally { this.#hideLoader(this.loaderAdditionalTarget); }
  }

  async saveAtvData() {
    const identification = this.identificationTarget.value;
    const certPath       = this.certPathTarget.value;
    const tokenUsr       = this.tokenUsrTarget.value.replace(/[^0-9]/g, '');

    if (certPath && !certPath.includes(identification)) {
      showToast('El nombre del certificado no coincide con la identificación de la compañía.', 'error');
      return;
    }
    if (tokenUsr && !tokenUsr.includes(identification)) {
      showToast('El token del usuario no coincide con la identificación de la compañía.', 'error');
      return;
    }
    this.#showLoader(this.loaderAtvTarget);
    try {
      await this.#sendEditRequest(2);
      showToast('Datos de Hacienda actualizados con éxito.', 'success');
    } catch (err) { showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar datos de Hacienda', message: err.message }); }
    finally { this.#hideLoader(this.loaderAtvTarget); }
  }

  async saveAttData() {
    this.#showLoader(this.loaderAttachmentsTarget);
    try {
      await this.#sendEditRequest(3);
      showToast('Adjuntos actualizados con éxito.', 'success');
    } catch (err) { showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar adjuntos', message: err.message }); }
    finally { this.#hideLoader(this.loaderAttachmentsTarget); }
  }

  async saveSapData() {
    // Solo se validan tolerancias/monedas cuando la funcionalidad está activa.
    // Si el usuario desactiva "Usa factura a proveedor", se guarda igual para apagarla.
    if (this.useFactProvTarget.checked && (!this.#xmlTolerances.length || !this.#validateTolerances())) {
      showToast('Verifique los datos de factura proveedor (tolerancias requeridas, sin duplicados).', 'error');
      return;
    }
    this.#showLoader(this.loaderSapTarget);
    try {
      await this.#sendEditRequest(4);
      await this.#apiFetch(`/api/Companies/${this.companyIdValue}/currency-map`, {
        method: 'PUT',
        body:   JSON.stringify(this.#currencyMappings),
      });
      showToast('Datos de factura proveedor actualizados con éxito.', 'success');
    } catch (err) { showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar datos de factura proveedor', message: err.message }); }
    finally { this.#hideLoader(this.loaderSapTarget); }
  }

  // ── Crear compañía ─────────────────────────────────────────────────────────

  async submitCreate() {
    const identification = this.identificationTarget.value;
    const certPath       = this.certPathTarget.value;
    const tokenUsr       = this.tokenUsrTarget.value.replace(/[^0-9]/g, '');

    if (certPath && !certPath.includes(identification)) {
      showToast('El nombre del certificado no coincide con la identificación de la compañía.', 'error');
      return;
    }
    if (tokenUsr && !tokenUsr.includes(identification)) {
      showToast('El token del usuario no coincide con la identificación de la compañía.', 'error');
      return;
    }
    if (!this.#validateGeneralForm()) {
      showToast('La información ingresada contiene errores. Verifíquela antes de continuar.', 'error');
      return;
    }
    if (this.useFactProvTarget.checked && !this.#xmlTolerances.length) {
      showToast('Verifique que los datos de factura a proveedor estén correctos.', 'error');
      return;
    }

    const companyId = parseInt(this.#selectedCompany?.companyId) || 0;
    // `groupId` va en 0: el campo se eliminó porque no hay grupos (§31), pero el
    // endpoint .NET todavía lo exige. Ver TODOS.md → Compañías.
    const groupId   = 0;

    try {
      const response = await fetch(
        `/api/Companies?companyId=${companyId}&groupId=${groupId}&feToken=${encodeURIComponent(Storage.get('Session')?.access_token || '')}`,
        {
          method:  'POST',
          headers: this.#authHeaders({ 'Request-With-Files': 'true', 'API': 'ApiAppUrl' }),
          body:    this.#buildCompanyFormData(),
        }
      );

      const json = await response.json();

      if (!response.ok) throw new Error(json.Message);
      
      if (json.Error) throw new Error(json.Message);

      showToast('Compañía registrada exitosamente.', 'success');
      setTimeout(() => { Turbo.visit('/configurations/companies'); }, 1200);
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al registrar compañía', message: err.message });
    }
  }

  // ── Helpers de petición ────────────────────────────────────────────────────

  #buildCompanyFormData() {
    const company = {
      Id:                    this.companyIdValue,
      // El campo "Nombre Comercial" se eliminó: es el mismo dato que `name`, así
      // que las dos claves del payload viejo salen de ahí.
      ComercialName:         this.nameTarget.value,
      LegalName:             this.legalNameTarget.value,
      Identification:        this.identificationTarget.value,
      Type:                  this.identificationTypeTarget.value,
      EmsrIdeTipo:           this.identificationTypeTarget.value,
      EmsrNombre:            this.legalNameTarget.value,
      EmsrNombreComercial:   this.nameTarget.value,
      EmsrIdeNumero:         this.identificationTarget.value,
      CertPin:               this.certPinTarget.value,
      CertPath:              this.certPathTarget.value,
      TokenUsr:              this.tokenUsrTarget.value,
      TokenPass:             this.tokenPassTarget.value,
      AdditionalInformation: this.additionalInformationTarget.value,
      CodigoActividad:       this.codigoActividadTarget.value,
      EmailCC:               this.#emailCcItems.join(';'),
      SAPConnectionId:       parseInt(this.sapConnectionIdTarget.value) || null,
      DBSap:                 this.dbSapTarget.value,
      DBMaestraSap:          '',
      NameToEmail:           parseInt(this.nameToEmailTarget.value),
      // `ShortName` e `IsExternal` se eliminaron del formulario pero el endpoint
      // .NET los sigue exigiendo: se manda el valor por defecto (§24).
      // Ver TODOS.md → Compañías.
      ShortName:             '',
      FreightCharges:        parseInt(this.freightChargesTarget.value),
      UseFactProv:           this.useFactProvTarget.checked,
      IsExternal:            false,
      SendReceptAndApInv:    this.sendReceptAndApInvTarget.checked,
      EmsrRegistrofiscal8707: this.registrofiscal8707Target.value,
      Active:                this.activeTarget.checked,
      NumSerieProv:          parseFloat(this.numSerieProvTarget.value) || null,
      NumSerieFactProv:      parseFloat(this.numSerieFactProvTarget.value) || null,
      DefaultTaxForXML:      this.defaultTaxForXmlTarget.value,
      DefaultWareHouse:      this.whDefaultTarget.value,
      XmlToleranceAmounts:   this.#xmlTolerances,
      grant_type: '', client_id: '', EnvironmentId: 0, Attempts: 0, Busy: false,
    };

    const fd = new FormData();
    fd.append('company',           JSON.stringify(company));
    // Sin archivo seleccionado → enviar literal "undefined" (FormData coacciona undefined → "undefined"),
    // igual que el proyecto legacy. Un Blob vacío haría que el backend interprete que SÍ hay archivo
    // y podría sobrescribir el certificado/logo/formato ya almacenado en el servidor.
    fd.append('file',              this.#selectedCertFile        || undefined);
    fd.append('fileFEPrintFormat', this.#selectedPrintFormatFile || undefined);
    fd.append('fileLogo',          this.#selectedLogoFile        || undefined);
    return fd;
  }

  async #sendEditRequest(action) {
    // 0 fijo: el campo "Grupo" se eliminó (§31) y el endpoint .NET lo exige.
    const groupId  = 0;

    const response = await fetch(
      `/api/Companies?groupId=${groupId}&action=${action}`,
      {
        method:  'PATCH',
        headers: this.#authHeaders({ 'Request-With-Files': 'true' }),
        body:    this.#buildCompanyFormData(),
      }
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const json = await response.json();
    if (json.Error) throw new Error(json.Message);
    return json;
  }

  async #downloadBlob(url, filename) {
    try {
      const response = await fetch(url, { headers: this.#authHeaders() });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const blob = await response.blob();
      const link = document.createElement('a');
      link.href     = URL.createObjectURL(blob);
      link.download = filename;
      link.click();
      URL.revokeObjectURL(link.href);
    } catch (err) {
      showToast(`Error al descargar: ${err.message}`, 'error');
    }
  }

  // ── Validación general ─────────────────────────────────────────────────────

  #validateGeneralForm() {
    const id    = this.identificationTarget.value;
    const rules = this.#ideRules[this.identificationTypeTarget.value] ?? { min: 9, max: 9 };
    return !!(
      this.nameTarget.value.trim() &&
      this.legalNameTarget.value.trim() &&
      id.length >= rules.min && id.length <= rules.max &&
      this.codigoActividadTarget.value.length === 6 &&
      this.dbSapTarget.value.trim() &&
      this.sapConnectionIdTarget.value
    );
  }

  #validateForm() {
    if (this.hasBtnRegisterTarget) {
      this.btnRegisterTarget.disabled = !this.#validateGeneralForm();
    }
    this.#refreshGeneralSaveState();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  #esc(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  /** Permissions es string[] en sessionStorage */
  #hasPerm(name) { return this.#permissions.includes(name); }

  #authHeaders(extra = {}) {
    const session = Storage.get('Session') || {};
    const token   = session.access_token;
    return {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...extra,
    };
  }

  /**
   * Endpoints NATIVOS de Rails: la sesión viaja en la cookie httpOnly, así que
   * no se arma ningún header Authorization — getApiHeaders() aporta lo único
   * que hace falta (CLAUDE.md §28). Los endpoints que todavía caen al proxy
   * .NET siguen usando `#apiFetch`.
   */
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

    return response.json();
  }

  async #apiFetch(url, options = {}) {
    const session = Storage.get('Session') || {};
    const token   = session.access_token;

    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(options.headers || {}),
      },
    });

    // Leer cl-message header (mismo mapeo que HttpAlertInterceptor de Angular).
    // El proxy Rails reenvía este header; contiene el mensaje real de la API encoded en URI.
    const clMessage = response.headers.get('cl-message');
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage); } catch { return clMessage; }
    })() : null;

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText);
      throw new Error(decodedMessage || text || `HTTP ${response.status}`);
    }

    const json = await response.json();

    // Mover cl-message a json.Message si la respuesta no trae mensaje propio
    if (decodedMessage && !json.Message) {
      json.Message = decodedMessage;
    }

    return json;
  }

  // ── Panel lateral — crear conexión SAP ────────────────────────────────────

  /**
   * Abre el panel lateral derecho para crear una nueva conexión SAP.
   * Equivalente al dialog.open(CreateOrUpdateConnectionComponent) del legacy Angular.
   */
  openCreateConnectionPanel() {
    this.#resetConnectionPanel();
    this.connPanelBackdropTarget.classList.remove('hidden');
    this.connPanelTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
    // Foco en el primer campo
    setTimeout(() => this.connNameTarget.focus(), 310);
  }

  closeConnectionPanel() {
    this.connPanelTarget.classList.add('translate-x-full');
    this.connPanelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  /** Habilita el botón de crear conexión solo cuando todos los requeridos están completos. */
  refreshConnSubmitState() {
    if (this.hasConnSaveBtnTarget) this.connSaveBtnTarget.disabled = !this.#isConnFormValid();
  }

  /** ¿Están completos los campos obligatorios? El motor (SlType) es opcional. */
  #isConnFormValid() {
    return this.connNameTarget.value.trim() !== '' && this.#isConnSlUrlValid();
  }

  /** La URL tiene que ser http(s), igual que valida el modelo del servidor. */
  #isConnSlUrlValid() {
    return /^https?:\/\//i.test(this.connSlUrlTarget.value.trim());
  }

  /**
   * Crea la conexión vía API y auto-selecciona el nuevo registro en el select.
   * Equivalente a dialogRef.afterClosed() + GetSAPConnectionsForAssignment() del legacy Angular.
   */
  async saveConnectionFromPanel() {
    if (!this.#validateConnectionPanel()) {
      showToast('Complete los campos requeridos.', 'warning');
      return;
    }

    this.connSaveBtnTarget.disabled = true;

    try {
      // Solo las tres columnas que existen en la tabla `connections`.
      const json = await this.#apiFetch('/api/connections', {
        method: 'POST',
        body: JSON.stringify({
          Name:   this.connNameTarget.value.trim(),
          SlUrl:  this.connSlUrlTarget.value.trim(),
          SlType: this.connSlTypeTarget.value.trim(),
        }),
      });

      if (!json.Data) {
        showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al crear la conexión', message: json.Message || 'Error desconocido' });
        return;
      }

      // Recargar lista de conexiones y auto-seleccionar la recién creada (la última del listado).
      // Mismo comportamiento que el legacy Angular: GetSAPConnectionsForAssignment + patchValue(lastConnection).
      const sapResp = await this.#apiFetch('/api/connections/assignable');
      if (sapResp.Data?.length) {
        this.#fillSapConnectionsSelect(sapResp.Data);
        const lastConn = sapResp.Data[sapResp.Data.length - 1];
        if (lastConn) {
          this.sapConnectionIdTarget.value = String(lastConn.Id);
          this.#validateForm();
        }
      }

      this.closeConnectionPanel();
      showToast('Conexión creada con éxito.', 'success');
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al crear la conexión', message: err.message });
    } finally {
      this.connSaveBtnTarget.disabled = false;
    }
  }

  #resetConnectionPanel() {
    [this.connNameTarget, this.connSlUrlTarget, this.connSlTypeTarget]
      .forEach(el => { el.value = ''; });

    this.refreshConnSubmitState();

    [this.connNameErrorTarget, this.connSlUrlErrorTarget]
      .forEach(el => el.classList.add('hidden'));
  }

  #validateConnectionPanel() {
    const nameEmpty  = !this.connNameTarget.value.trim();
    const urlInvalid = !this.#isConnSlUrlValid();

    this.connNameErrorTarget.classList.toggle('hidden', !nameEmpty);
    this.connSlUrlErrorTarget.classList.toggle('hidden', !urlInvalid);

    return !nameEmpty && !urlInvalid;
  }
}
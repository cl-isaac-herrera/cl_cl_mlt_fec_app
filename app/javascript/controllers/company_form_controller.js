import { Controller } from '@hotwired/stimulus';
import { Storage, SStore, getApiHeaders } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts';

/**
 * Con cuántos días de anticipación se avisa que el certificado está por vencer.
 *
 * Es el mismo umbral que `Company::CERT_EXPIRATION_ALARM_DAYS`, el que usa el
 * toast del home. Si cambia allá, cambia acá: son dos avisos de lo mismo y
 * quedarían diciendo cosas distintas el mismo día.
 */
const CERT_ALARM_DAYS = 7;

/**
 * Los dos tonos de las insignias de aviso (§33): disco claro, ícono oscuro. El
 * par importa — un disco cargado con el ícono en un tono cercano los funde y el
 * ícono deja de leerse.
 */
const ALERT_TONES = {
  warning: 'text-yellow-700 bg-yellow-100',
  error:   'text-red-600 bg-red-200',
};

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
    'certAlert',
    'certPin', 'certPinEyeIcon',
    'certPath', 'certPathText',
    'certFileInput',
    'certExpireDate',
    'tokenUsr',
    'tokenPass', 'tokenPassEyeIcon',
    'btnSaveAtvContainer', 'btnSaveAtv', 'btnSaveAtvWrap',

    // Sección 4 - Adjuntos
    'logoName', 'logoFileInput',
    'btnDownloadLogo', 'btnDownloadLogoWrap',
    'printFormatName', 'printFormatFileInput',
    'btnDownloadPrintFormat', 'btnDownloadPrintFormatWrap',
    'btnResetFormat', 'btnResetFormatWrap',
    'btnSaveAttachmentsContainer', 'btnSaveAttachments', 'btnSaveAttachmentsWrap',

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
    'sapErrorIcon',

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
  // Lo mismo para la sección "Datos de Conexión de Hacienda (ATV)". Los dos
  // secretos no entran en la foto: el servidor no los devuelve, así que el campo
  // siempre arranca vacío y no hay contra qué comparar. En su lugar se recuerda
  // si el usuario los escribió, que es lo que decide si viajan en el PATCH.
  #atvSnapshot            = null;
  #certPinTouched         = false;
  #tokenPassTouched       = false;

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
    this.#setupTooltips();
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

    // Los tres botones de la barra de los campos de "Adjuntos" (descargar logo,
    // descargar formato, restablecer) nacen deshabilitados y los habilita
    // `#refreshAttachmentsState()` según el permiso y según haya archivo
    // guardado. No se ocultan cuando falta el permiso: se deshabilitan con el
    // motivo (§26). Corre en los dos modos — en creación el motivo es que la
    // compañía todavía no existe.
    this.#refreshAttachmentsState();
  }

  #initEmailCc() {
    this.#emailCcItems = [''];
    this.#renderEmailCc();
  }

  // ── Tooltips ───────────────────────────────────────────────────────────────

  /**
   * Este formulario no tiene tabla, así que no hereda el `setupTooltip()` de
   * `TabulatorController`: sin esto, los `data-tooltip` que ya estaban puestos
   * (el motivo por el que un botón "Actualizar" está deshabilitado, §26) no se
   * veían nunca.
   */
  #setupTooltips() {
    [
      this.hasCertAlertTarget          ? this.certAlertTarget          : null,
      this.hasSapErrorIconTarget       ? this.sapErrorIconTarget       : null,
      this.hasBtnSaveGeneralWrapTarget ? this.btnSaveGeneralWrapTarget : null,
      this.hasBtnSaveAtvWrapTarget     ? this.btnSaveAtvWrapTarget     : null,
      this.hasBtnSaveAttachmentsWrapTarget    ? this.btnSaveAttachmentsWrapTarget    : null,
      this.hasBtnDownloadLogoWrapTarget       ? this.btnDownloadLogoWrapTarget       : null,
      this.hasBtnDownloadPrintFormatWrapTarget ? this.btnDownloadPrintFormatWrapTarget : null,
      this.hasBtnResetFormatWrapTarget        ? this.btnResetFormatWrapTarget        : null,
    ].filter(Boolean).forEach(el => this.#attachTooltip(el));

    // Los dos botones de "adjuntar" están siempre habilitados, así que su
    // tooltip va directo en el <button> y no en un <span> envolvente.
    this.element
      .querySelectorAll('[data-action*="triggerLogoUpload"], [data-action*="triggerPrintFormatUpload"]')
      .forEach(el => this.#attachTooltip(el));
  }

  /**
   * Tooltip flotante para un elemento fuera de Tabulator. Mismo patrón y mismo
   * `place()` con clamp que el base (CLAUDE.md §25): se posiciona arriba del
   * cursor, se voltea a la izquierda si se sale por la derecha y se recorta
   * contra los cuatro bordes, para que nunca quede cortado.
   *
   * Lee `data-tooltip` en cada `mouseenter`, no al registrar: el del aviso de
   * vencimiento cambia cuando cambia la fecha.
   */
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
   * Solo se piden los datos de las secciones que están migradas — "Datos
   * Generales", "Hacienda (ATV)" y "Adjuntos", que salen de la misma petición.
   * Las consultas de las otras secciones (`warehouse`, `Tax`, `currencies`,
   * `currency-map`, `activity-codes`) se quitaron: van al proxy .NET, que hoy
   * responde 401, así que no llenaban nada — solo sumaban cinco peticiones
   * fallidas y demoraban el cierre del loader. Vuelven cuando se migre cada
   * sección (TODOS.md → Compañías).
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
      if (this.#companyData) {
        this.#fillGeneralSection(this.#companyData);
        this.#fillAtvSection(this.#companyData);
        this.#fillAttachmentsSection(this.#companyData);
      }
    } finally {
      this.#hideLoader(this.loaderGeneralTarget);
      this.#hideLoader(this.loaderAtvTarget);
      this.#hideLoader(this.loaderAttachmentsTarget);
    }
  }

  // Solo se muestran los loaders de las secciones que realmente cargan algo. Las
  // demás no piden nada todavía: dejarlas girando diría que están esperando
  // datos. Las tres salen de la MISMA petición (`GET /api/companies/:id`), aunque
  // el guardado esté partido en un endpoint por sección.
  #showSectionLoaders() {
    this.#showLoader(this.loaderGeneralTarget);
    this.#showLoader(this.loaderAtvTarget);
    this.#showLoader(this.loaderAttachmentsTarget);
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
   * Las secciones de Hacienda (ATV) y de adjuntos salen de la misma respuesta
   * pero las llenan `#fillAtvSection` y `#fillAttachmentsSection`. Las demás
   * (adicional, códigos de actividad, factura a proveedor) todavía no se
   * migraron y por eso no se llenan.
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

    this.#paintSectionSaveButton(
      this.btnSaveGeneralTarget,
      this.hasBtnSaveGeneralWrapTarget ? this.btnSaveGeneralWrapTarget : null,
      this.#generalSaveBlockedReason(),
      'Actualizar los datos generales de la compañía',
    );
  }

  /**
   * Pinta el botón "Actualizar …" de una sección según se pueda guardar o no.
   * Lo comparten todas las secciones migradas para que el gris, el cursor y el
   * tooltip signifiquen lo mismo en todas.
   *
   * @param {HTMLButtonElement} btn
   * @param {?HTMLElement} wrap  <span> envolvente que lleva el tooltip.
   * @param {?string} reason     Por qué NO se puede guardar; null si sí se puede.
   * @param {string} enabledTooltip  Qué hace el botón cuando está habilitado.
   */
  #paintSectionSaveButton(btn, wrap, reason, enabledTooltip) {
    btn.disabled = !!reason;
    btn.classList.toggle('pointer-events-none', !!reason);
    btn.classList.toggle('cursor-not-allowed', !!reason);
    btn.classList.toggle('bg-gray-300',  !!reason);
    btn.classList.toggle('text-gray-500', !!reason);
    btn.classList.toggle('bg-blue-600',  !reason);
    btn.classList.toggle('text-white',   !reason);
    btn.classList.toggle('hover:bg-blue-700', !reason);

    if (wrap) wrap.dataset.tooltip = reason || enabledTooltip;
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

  // ── Sección "Hacienda (ATV)" ───────────────────────────────────────────────

  /**
   * Llena la sección con la respuesta de `GET /api/companies/:id`.
   *
   * El PIN del certificado y el token password NO vienen en la respuesta: están
   * cifrados y no se le devuelven a nadie. Lo único que llega es si hay uno
   * guardado (`HasCertPin` / `HasTokenPass`), y con eso el campo —que siempre
   * arranca vacío— dice en el placeholder qué pasa si se escribe algo.
   *
   * Del certificado llega el nombre del archivo, no la ruta: dónde lo guardó el
   * servidor no es asunto de esta pantalla.
   */
  #fillAtvSection(data) {
    this.certPathTarget.value       = data.CertFileName || '';
    this.certPathTextTarget.value   = data.CertFileName || '';
    this.tokenUsrTarget.value       = data.TokenUsr || '';
    this.#showCertExpiresAt(data.CertExpireDate);

    this.#applySecretPlaceholder(this.certPinTarget,   this.certPinEyeIconTarget,   data.HasCertPin);
    this.#applySecretPlaceholder(this.tokenPassTarget, this.tokenPassEyeIconTarget, data.HasTokenPass);

    // Un certificado ya guardado no es un archivo pendiente de subir.
    this.#selectedCertFile = null;
    this.#oldCertPin       = '';

    // La foto se toma DESPUÉS de llenar: es el estado "sin cambios".
    this.#certPinTouched   = false;
    this.#tokenPassTouched = false;
    this.#atvSnapshot      = this.#atvValues();
    this.#refreshAtvSaveState();
  }

  /**
   * Pinta la fecha de vencimiento. Es solo display: la fecha no viaja de vuelta
   * al servidor — la deriva él del `.p12` al guardarlo, que es la única fuente
   * que no se puede escribir a mano para posponer la alarma de vencimiento.
   *
   * El aviso del encabezado se repinta acá y no en `#fillAtvSection` para que
   * también siga al adelanto: al elegir un certificado nuevo, el ícono refleja
   * la fecha que se está viendo, no la que todavía está guardada.
   */
  #showCertExpiresAt(isoDate) {
    this.certExpireDateTarget.value = this.#formatDateTime(isoDate);
    this.#renderCertAlert(isoDate);
  }

  /**
   * El ícono que late al lado del título de la sección: ámbar los días previos
   * al vencimiento, rojo una vez vencido, nada el resto del tiempo.
   *
   * Va en el encabezado —visible con la sección cerrada— porque el formulario
   * tiene seis secciones plegadas y un certificado vencido no puede depender de
   * que alguien abra la correcta para enterarse.
   */
  #renderCertAlert(isoDate) {
    if (!this.hasCertAlertTarget) return;

    this.#paintAlertBadge(this.certAlertTarget, this.#certExpirationAlert(isoDate));
  }

  /**
   * Pinta —o apaga— una insignia de aviso en el encabezado de una sección: disco
   * lleno, ícono redondeado encima y el motivo en el tooltip (§33).
   *
   * Es el ÚNICO lugar que arma esas clases. Las secciones que avisan algo son
   * varias (el vencimiento del certificado, las listas de SAP que no cargaron) y
   * con cada una armando su propio HTML se iban separando sin que nadie lo
   * notara.
   *
   * @param {HTMLElement} el
   * @param {?{icon: string, tone: string, urgent: boolean, message: string}} alert
   *   null apaga la insignia.
   */
  #paintAlertBadge(el, alert) {
    if (!alert) {
      el.className = 'hidden';
      el.removeAttribute('data-tooltip');
      el.innerHTML = '';
      return;
    }

    el.className = [
      'cl-beat',
      alert.urgent ? 'cl-beat-urgent' : '',
      // Disco lleno, no un aro: el círculo es una superficie sólida del tono
      // claro y el ícono va encima en el oscuro.
      'items-center justify-center h-6 w-6 rounded-full flex-shrink-0',
      alert.tone,
    ].filter(Boolean).join(' ');

    el.dataset.tooltip = alert.message;
    el.innerHTML = this.#alertIcon(alert.icon);
  }

  /**
   * Los dos íconos, de **Material Symbols Rounded** — la variante de puntas
   * redondeadas. No es la familia `material-icons` del resto de la app: esa
   * dibuja el triángulo con las puntas en ángulo vivo. El layout la carga
   * subseteada a estos dos nombres (ver `protected.html.erb`).
   *
   * El vencido usa `priority_high` (el signo solo) y no `error`: ese es un
   * círculo relleno y, adentro del anillo, se vería como un círculo dentro de
   * otro.
   */
  #alertIcon(name) {
    return `<span class="material-symbols-rounded" style="font-size:16px; line-height:1">${name}</span>`;
  }

  /**
   * Qué avisar sobre el vencimiento, o null si todavía falta mucho.
   *
   * Los textos son los mismos que arma `Company#cert_expiration_message` para el
   * toast del home: es el mismo hecho contado en dos lugares y decirlo distinto
   * haría dudar de cuál es el bueno.
   *
   * @returns {?{icon: string, ring: string, urgent: boolean, message: string}}
   */
  #certExpirationAlert(isoDate) {
    if (!isoDate) return null;

    const expiresAt = new Date(isoDate);
    if (isNaN(expiresAt.getTime())) return null;

    // Días de calendario, no de 24 horas: un certificado que vence esta noche
    // tiene que decir "vence hoy", no "vence en 0 días" ni "venció".
    const midnight = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
    const days = Math.round((midnight(expiresAt) - midnight(new Date())) / 86_400_000);
    if (days > CERT_ALARM_DAYS) return null;

    const pad  = n => String(n).padStart(2, '0');
    const date = `${pad(expiresAt.getDate())}/${pad(expiresAt.getMonth() + 1)}/${expiresAt.getFullYear()}`;

    if (days < 0) {
      return {
        icon: 'priority_high', tone: ALERT_TONES.error, urgent: true,
        message: `El certificado digital venció el ${date}. Debe cargar uno vigente para poder emitir documentos electrónicos.`,
      };
    }
    if (days === 0) {
      return {
        icon: 'warning', tone: ALERT_TONES.warning, urgent: false,
        message: `El certificado digital vence hoy (${date}). Debe cargar uno vigente para no interrumpir la emisión.`,
      };
    }

    const plural = days === 1 ? 'día' : 'días';
    return {
      icon: 'warning', tone: ALERT_TONES.warning, urgent: false,
      message: `El certificado digital vence en ${days} ${plural} (${date}). Debe cargar uno vigente antes de esa fecha.`,
    };
  }

  /**
   * Un campo de secreto se muestra vacío siempre. El placeholder es lo único que
   * distingue "no hay nada guardado" de "hay algo y no se muestra".
   *
   * Vuelve a taparse (`type=password`) junto con su ícono: si el usuario lo había
   * destapado para revisar lo que escribía, después de guardar no tiene por qué
   * seguir a la vista.
   */
  #applySecretPlaceholder(input, eyeIcon, stored) {
    input.value       = '';
    input.type        = 'password';
    input.placeholder = stored ? 'Guardado — escriba para reemplazarlo' : '';
    eyeIcon.textContent = 'visibility_off';
  }

  /**
   * Los valores editables de la sección, normalizados a texto para compararlos
   * contra la foto inicial.
   *
   * Es uno solo: el nombre del certificado y su vencimiento son de solo lectura
   * —los deriva el servidor del archivo— y los dos secretos no se pueden comparar
   * contra nada, porque el servidor no los devuelve. Para esos tres el "cambió"
   * son las marcas de abajo.
   */
  #atvValues() {
    return { tokenUsr: this.tokenUsrTarget.value.trim() };
  }

  /** ¿Cambió algo en la sección respecto a lo que se cargó? */
  #atvIsDirty() {
    if (!this.#atvSnapshot) return false;
    if (this.#certPinTouched || this.#tokenPassTouched || this.#selectedCertFile) return true;

    const current = this.#atvValues();
    return Object.keys(current).some(key => current[key] !== this.#atvSnapshot[key]);
  }

  /**
   * Por qué NO se puede guardar la sección, o null si sí se puede. El texto es el
   * del tooltip, así que tiene que responder "¿cuándo sí podré usarlo?"
   * (CLAUDE.md §2).
   *
   * Las dos concordancias con la identificación de la compañía eran toasts que
   * saltaban recién al apretar el botón; como son condiciones que se pueden
   * evaluar mientras se escribe, ahora deshabilitan el botón y explican por qué
   * (§26).
   *
   * @returns {?string}
   */
  #atvSaveBlockedReason() {
    if (!this.#atvIsDirty()) return 'No hay cambios por guardar en esta sección';

    const identification = this.identificationTarget.value;
    const certPath       = this.certPathTarget.value;
    const tokenUsr       = this.tokenUsrTarget.value.replace(/[^0-9]/g, '');

    if (certPath && !certPath.includes(identification)) {
      return 'El nombre del certificado debe contener la identificación de la compañía';
    }
    if (tokenUsr && !tokenUsr.includes(identification)) {
      return 'El token de usuario debe contener la identificación de la compañía';
    }

    return null;
  }

  #refreshAtvSaveState() {
    if (!this.hasBtnSaveAtvTarget) return;

    this.#paintSectionSaveButton(
      this.btnSaveAtvTarget,
      this.hasBtnSaveAtvWrapTarget ? this.btnSaveAtvWrapTarget : null,
      this.#atvSaveBlockedReason(),
      'Actualizar los datos de Hacienda de la compañía',
    );
  }

  /** Cambió un campo visible de la sección (token de usuario). */
  onAtvChange() { this.#refreshAtvSaveState(); }

  // Escribir en un campo de secreto es lo que lo hace viajar en el PATCH: sin
  // esta marca, la clave no se manda y el valor guardado queda como está.
  onCertPinInput() {
    this.#certPinTouched = true;
    this.#refreshAtvSaveState();
  }

  onTokenPassInput() {
    this.#tokenPassTouched = true;
    this.#refreshAtvSaveState();
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
    if (!file) {
      this.certPathTarget.value     = '';
      this.certPathTextTarget.value = '';
      this.#refreshAtvSaveState();
      return;
    }

    if (!file.name.endsWith('.p12') && !file.name.endsWith('.pfx')) {
      this.certFileInputTarget.value = '';
      showToast('Seleccione un certificado con extensión válida (.p12 o .pfx).', 'error');
      return;
    }

    this.#selectedCertFile        = file;
    this.certPathTarget.value     = file.name;
    this.certPathTextTarget.value = file.name;
    this.#refreshAtvSaveState();

    if (!this.certPinTarget.value) {
      showAlert({ type: ALERT_TYPES.WARNING, title: 'Pin requerido', message: 'Para obtener la fecha de expiración del certificado debe colocar el PIN.' });
      return;
    }
    this.#getCertExpireDate();
  }

  /**
   * Le pide al servidor la fecha de vencimiento del certificado recién elegido.
   *
   * El PIN va en el CUERPO, no en la query string como en el .NET: un secreto en
   * la URL queda en el historial del navegador y en el log de accesos, donde
   * `filter_parameters` no llega.
   *
   * Es solo un adelanto para la pantalla: acá el archivo se abre y se descarta.
   * La fecha que queda guardada la deriva el PATCH de la sección del archivo que
   * recibe, no de esto.
   */
  async #getCertExpireDate() {
    const pin  = this.certPinTarget.value;
    const file = this.#selectedCertFile;
    if (!pin || !file) return;

    const fd = new FormData();
    fd.append('file', file);
    fd.append('CertPin', pin);

    try {
      const json = await this.#railsFetch('/api/certificate_inspections', { method: 'POST', body: fd });

      this.#showCertExpiresAt(json.Data?.CertExpireDate);
    } catch (err) {
      this.#showCertExpiresAt(null);
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error de certificado', message: err.message });
    } finally {
      // La fecha es un campo de la sección: cambie o falle, el botón tiene que
      // reflejar el estado real.
      this.#refreshAtvSaveState();
    }
  }

  async downloadCertificate() {
    await this.#downloadBlob(
      `/api/companies/${this.companyIdValue}/certificate`,
      this.certPathTarget.value || 'certificado.pfx'
    );
  }

  // ── Sección "Adjuntos de la compañía" ──────────────────────────────────────

  /**
   * Llena la sección con la respuesta de `GET /api/companies/:id`.
   *
   * De los dos adjuntos llega el NOMBRE del archivo, no la ruta: la columna
   * guarda la ruta absoluta que otro proceso abre —el servicio de correo el
   * logo, el generador del PDF el `.rpt`— y dónde lo guardó el servidor no es
   * asunto de esta pantalla.
   */
  #fillAttachmentsSection(data) {
    this.logoNameTarget.value        = data.LogoFileName || '';
    this.printFormatNameTarget.value = data.PrintFormatFileName || '';

    // Un archivo ya guardado no es un archivo pendiente de subir. El <input
    // type="file"> también se limpia: si no, volver a elegir el mismo archivo no
    // dispara `change` y la sección quedaría sin poder guardarse.
    this.#selectedLogoFile          = null;
    this.#selectedPrintFormatFile   = null;
    this.logoFileInputTarget.value        = '';
    this.printFormatFileInputTarget.value = '';

    this.#refreshAttachmentsState();
  }

  /**
   * Por qué NO se puede guardar la sección, o null si sí se puede.
   *
   * No hay foto de valores contra la que comparar como en las otras secciones:
   * los dos campos son de solo lectura y muestran el nombre de lo que ya está
   * guardado. Lo único que se puede cambiar es elegir un archivo nuevo, así que
   * eso ES el "cambió".
   *
   * @returns {?string}
   */
  #attachmentsSaveBlockedReason() {
    if (!this.#selectedLogoFile && !this.#selectedPrintFormatFile) {
      return 'No hay cambios por guardar en esta sección';
    }

    return null;
  }

  /**
   * Repinta los cuatro botones de la sección: el de guardar y los tres de la
   * barra de los campos (descargar logo, descargar formato, restablecer).
   *
   * Los tres últimos dependen de dos cosas distintas —el permiso y que haya un
   * archivo guardado— y las dos se explican en el tooltip, porque un ícono gris
   * sin motivo obliga a adivinar (§2 y §26).
   */
  #refreshAttachmentsState() {
    if (this.hasBtnSaveAttachmentsTarget) {
      this.#paintSectionSaveButton(
        this.btnSaveAttachmentsTarget,
        this.hasBtnSaveAttachmentsWrapTarget ? this.btnSaveAttachmentsWrapTarget : null,
        this.#attachmentsSaveBlockedReason(),
        'Actualizar los adjuntos de la compañía',
      );
    }

    if (this.hasBtnDownloadLogoTarget) {
      this.#paintIconButton(
        this.btnDownloadLogoTarget,
        this.hasBtnDownloadLogoWrapTarget ? this.btnDownloadLogoWrapTarget : null,
        this.#logoDownloadBlockedReason(),
        'Descargar el logo de la compañía',
      );
    }

    if (this.hasBtnDownloadPrintFormatTarget) {
      this.#paintIconButton(
        this.btnDownloadPrintFormatTarget,
        this.hasBtnDownloadPrintFormatWrapTarget ? this.btnDownloadPrintFormatWrapTarget : null,
        this.#printFormatDownloadBlockedReason(),
        'Descargar el formato de impresión de la compañía',
      );
    }

    if (this.hasBtnResetFormatTarget) {
      this.#paintIconButton(
        this.btnResetFormatTarget,
        this.hasBtnResetFormatWrapTarget ? this.btnResetFormatWrapTarget : null,
        this.#resetFormatBlockedReason(),
        'Restablecer el formato de impresión al de la aplicación',
      );
    }
  }

  /**
   * Pinta un botón de ícono de la barra de un campo según se pueda usar o no.
   * Es el equivalente de `#paintSectionSaveButton` para los botones sufijo: ahí
   * el deshabilitado es un fondo gris; acá, el ícono en gris claro (§4).
   *
   * @param {HTMLButtonElement} btn
   * @param {?HTMLElement} wrap  <span> envolvente que lleva el tooltip.
   * @param {?string} reason     Por qué NO se puede usar; null si sí se puede.
   * @param {string} enabledTooltip  Qué hace el botón cuando está habilitado.
   */
  #paintIconButton(btn, wrap, reason, enabledTooltip) {
    btn.disabled = !!reason;
    btn.classList.toggle('pointer-events-none', !!reason);
    btn.classList.toggle('cursor-not-allowed', !!reason);
    btn.classList.toggle('text-gray-300', !!reason);
    btn.classList.toggle('text-gray-500', !reason);
    btn.classList.toggle('hover:bg-gray-100', !reason);
    btn.classList.toggle('hover:text-gray-700', !reason);

    if (wrap) wrap.dataset.tooltip = reason || enabledTooltip;
  }

  /**
   * Los dos permisos que acepta el endpoint de descarga: el de la compañía y el
   * global. Se evalúan igual que del lado del servidor —cualquiera alcanza— para
   * que la pantalla no deshabilite lo que el API sí permitiría.
   */
  #canDownload(permission, globalPermission) {
    return this.#hasPerm(permission) || this.#hasPerm(globalPermission);
  }

  /** El nombre del archivo GUARDADO, que es el que se descarga. */
  #savedLogoName()        { return this.#companyData?.LogoFileName || ''; }
  #savedPrintFormatName() { return this.#companyData?.PrintFormatFileName || ''; }

  /**
   * En creación no hay nada que descargar ni restablecer todavía. Es el primer
   * motivo de los tres botones: sin esto dirían "no cuenta con permisos", que es
   * falso y manda a pedirle un permiso a quien no lo necesita.
   */
  #attachmentsNeedSavedCompany() {
    return this.#isEditing ? null : 'Debe registrar la compañía antes de administrar sus adjuntos';
  }

  #logoDownloadBlockedReason() {
    const pending = this.#attachmentsNeedSavedCompany();
    if (pending) return pending;

    if (!this.#canDownload('Configurations_Companies_DownloadLogo',
                           'Configurations_Companies_DownloadLogoInAllCompanies')) {
      return 'No cuenta con permisos para descargar el logo de la compañía';
    }
    if (!this.#savedLogoName()) {
      return 'La compañía debe tener un logo guardado para poder descargarlo';
    }

    return null;
  }

  #printFormatDownloadBlockedReason() {
    const pending = this.#attachmentsNeedSavedCompany();
    if (pending) return pending;

    if (!this.#canDownload('Configurations_Companies_DownloadFEPrintFormat',
                           'Configurations_Companies_DownloadFEPrintFormatInAllCompanies')) {
      return 'No cuenta con permisos para descargar el formato de impresión de la compañía';
    }
    if (!this.#savedPrintFormatName()) {
      return 'La compañía debe tener un formato de impresión guardado para poder descargarlo';
    }

    return null;
  }

  #resetFormatBlockedReason() {
    const pending = this.#attachmentsNeedSavedCompany();
    if (pending) return pending;

    if (!this.#hasPerm('F_ResetCompanyFormat')) {
      return 'No cuenta con permisos para restablecer el formato de impresión';
    }
    if (!this.#savedPrintFormatName()) {
      return 'La compañía debe tener un formato de impresión propio para poder restablecerlo';
    }

    return null;
  }

  // ── Logo ───────────────────────────────────────────────────────────────────

  triggerLogoUpload() { this.logoFileInputTarget.click(); }

  onLogoSelected() {
    const file = this.logoFileInputTarget.files[0];

    // Sin archivo (el usuario canceló el diálogo) el campo vuelve a mostrar el
    // nombre de lo que está guardado, no queda en blanco: en blanco parecería
    // que la compañía se quedó sin logo.
    if (!file) {
      this.#selectedLogoFile    = null;
      this.logoNameTarget.value = this.#savedLogoName();
      this.#refreshAttachmentsState();
      return;
    }

    const ext = file.name.split('.').pop().toLowerCase();
    if (!['jpg', 'jpeg', 'png'].includes(ext)) {
      this.logoFileInputTarget.value = '';
      showToast('Seleccione un logo con formato válido (JPG, JPEG o PNG).', 'error');
      return;
    }
    this.#selectedLogoFile    = file;
    this.logoNameTarget.value = file.name;
    this.#refreshAttachmentsState();
  }

  async downloadLogo() {
    // Defensa en profundidad: el botón ya está deshabilitado, pero la UI se
    // puede manipular (§26).
    const blocked = this.#logoDownloadBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    await this.#downloadBlob(
      `/api/companies/${this.companyIdValue}/logo`,
      this.#savedLogoName() || 'logo.png'
    );
  }

  // ── Formato de impresión ───────────────────────────────────────────────────

  triggerPrintFormatUpload() { this.printFormatFileInputTarget.click(); }

  onPrintFormatSelected() {
    const file = this.printFormatFileInputTarget.files[0];

    if (!file) {
      this.#selectedPrintFormatFile    = null;
      this.printFormatNameTarget.value = this.#savedPrintFormatName();
      this.#refreshAttachmentsState();
      return;
    }

    if (!file.name.endsWith('.rpt')) {
      this.printFormatFileInputTarget.value = '';
      showToast('Seleccione un formato de impresión válido (.rpt).', 'error');
      return;
    }
    this.#selectedPrintFormatFile    = file;
    this.printFormatNameTarget.value = file.name;
    this.#refreshAttachmentsState();
  }

  async downloadPrintFormat() {
    const blocked = this.#printFormatDownloadBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    await this.#downloadBlob(
      `/api/companies/${this.companyIdValue}/print_format`,
      this.#savedPrintFormatName() || 'formato-impresion.rpt'
    );
  }

  /**
   * ⚠️ Lo único de esta sección que TODAVÍA va al .NET (y por eso usa
   * `#apiFetch` y no `#railsFetch`).
   *
   * No se migró con el resto porque "restablecer" no es vaciar la columna: en el
   * legado copiaba el formato por defecto —el del grupo— a la carpeta de la
   * compañía y apuntaba la columna al archivo nuevo. Vaciarla dejaría a la
   * compañía sin poder emitir: el servicio de emisión levanta si no hay formato
   * ("No se ha configurado un formato de impresion para FE").
   *
   * En esta versión no hay grupos (§31) y el formato por defecto de la
   * aplicación vive en las configuraciones generales, que todavía no tienen
   * tabla — no hay de dónde copiar. Ver `TODOS.md` → Compañías.
   */
  async resetPrintFormat() {
    // Defensa en profundidad: el botón ya está deshabilitado, pero la UI se
    // puede manipular (§26).
    const blocked = this.#resetFormatBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    const confirmed = await confirm(
      'Esta acción restablecerá el formato de impresión de la compañía al por defecto. ¿Desea continuar?',
      'Restablecer formato'
    );
    if (!confirmed) return;

    this.#showLoader(this.loaderAttachmentsTarget);
    try {
      await this.#apiFetch(
        `/api/Companies/ResetCompanyPrintFormat?companyId=${this.companyIdValue}`,
        { method: 'PATCH' }
      );
      // El servidor cambió la ruta, así que el nombre que hay en pantalla ya no
      // es el que quedó guardado: se relee la sección en vez de adivinarlo.
      await this.#reloadAttachmentsSection();
      showToast('Formato de impresión restablecido con éxito', 'success');
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al restablecer formato', message: err.message });
    } finally {
      this.#hideLoader(this.loaderAttachmentsTarget);
    }
  }

  /**
   * Vuelve a leer la compañía y repinta solo la sección de adjuntos. La lectura
   * del formulario es una sola (`GET /api/companies/:id`), así que se reusa esa
   * y se refresca lo que cambió.
   */
  async #reloadAttachmentsSection() {
    const resp = await this.#railsFetch(`/api/companies/${this.companyIdValue}`);
    if (!resp.Data) return;

    this.#companyData = resp.Data;
    this.#fillAttachmentsSection(this.#companyData);
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
  /**
   * El aviso de la sección "Factura a Proveedor": las listas que la alimentan
   * (almacenes, impuestos, monedas) no se pudieron traer de SAP.
   *
   * Usa la misma insignia que el vencimiento del certificado (§33). Antes era un
   * `material-icons` con `animate-pulse` y un tooltip propio hecho con
   * `group-hover`; quedó de antes de que la convención existiera.
   *
   * Rojo porque el fallo ya ocurrió, pero con el latido normal: la sección queda
   * incompleta, que es menos grave que un certificado vencido —eso frena la
   * emisión— y el ritmo rápido se reserva para eso.
   */
  #setSapListError(errors) {
    if (!this.hasSapErrorIconTarget) return;

    this.#paintAlertBadge(this.sapErrorIconTarget, errors?.length ? {
      icon: 'priority_high', tone: ALERT_TONES.error, urgent: false,
      // Con ' · ' y no con salto de línea: el tooltip flotante normaliza los
      // espacios en blanco (§25) y los renglones quedarían pegados.
      message: `No se pudieron cargar las listas de SAP de esta sección. ${errors.join(' · ')}`,
    } : null);
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

  /**
   * Guarda SOLO la sección "Datos de Conexión de Hacienda (ATV)", contra su
   * propio endpoint (`PATCH /api/companies/:id/tax_authority`).
   *
   * El cuerpo es multipart porque la sección incluye el certificado. El servidor
   * lo guarda en disco y deriva de él la ruta y el vencimiento; esta pantalla no
   * manda ninguno de los dos.
   */
  async saveAtvData() {
    // Defensa en profundidad: la UI ya deshabilita el botón, pero se puede
    // manipular (CLAUDE.md §26).
    const blocked = this.#atvSaveBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    this.#showLoader(this.loaderAtvTarget);
    try {
      const json = await this.#railsFetch(
        `/api/companies/${this.companyIdValue}/tax_authority`,
        { method: 'PATCH', body: this.#atvPayload() },
      );

      // Se repinta con lo que quedó guardado, no con lo que había en pantalla: es
      // además la única forma de volver a saber si hay secretos guardados, porque
      // sus valores no vuelven, y de ver el nombre y el vencimiento que el
      // servidor sacó del archivo.
      if (json.Data) {
        this.#companyData = { ...this.#companyData, ...json.Data };
        this.#fillAtvSection(this.#companyData);
      }

      showToast(json.Message || 'Datos de Hacienda actualizados con éxito.', 'success');
    } catch (err) {
      // Error de escritura → modal, no toast (CLAUDE.md §9).
      showAlert({
        type:    ALERT_TYPES.ERROR,
        title:   'Error al guardar datos de Hacienda',
        message: err.message,
      });
    } finally {
      this.#hideLoader(this.loaderAtvTarget);
    }
  }

  /**
   * El cuerpo del PATCH de la sección — `FormData`, porque puede llevar el
   * certificado.
   *
   * Los dos secretos viajan SOLO si el usuario los escribió: la clave ausente le
   * dice al endpoint que los deje como están. Sin esa regla, guardar la sección
   * para cambiar el token de usuario borraría el PIN, porque el input se pinta
   * vacío (el valor guardado no vuelve nunca del servidor).
   *
   * El nombre del certificado y su vencimiento NO se mandan: los deriva el
   * servidor del archivo. Mandar el nombre era además peligroso — la columna
   * guarda la ruta que el servicio de firma abre, y pisarla con `cert.p12` a
   * secas dejaba a la compañía sin poder emitir.
   */
  #atvPayload() {
    const fd = new FormData();
    fd.append('TokenUsr', this.tokenUsrTarget.value.trim());

    if (this.#certPinTouched)   fd.append('CertPin',   this.certPinTarget.value);
    if (this.#tokenPassTouched) fd.append('TokenPass', this.tokenPassTarget.value);
    if (this.#selectedCertFile) fd.append('file',      this.#selectedCertFile);

    return fd;
  }

  /**
   * Guarda SOLO la sección "Adjuntos de la compañía", contra su propio endpoint
   * (`PATCH /api/companies/:id/attachments`).
   *
   * El cuerpo es multipart porque los dos campos de la sección son archivos. Las
   * rutas NO se mandan: las deriva el servidor de la cédula de la compañía y del
   * nombre del archivo, igual que la del certificado.
   */
  async saveAttData() {
    // Defensa en profundidad: la UI ya deshabilita el botón, pero se puede
    // manipular (§26).
    const blocked = this.#attachmentsSaveBlockedReason();
    if (blocked) {
      showToast(blocked, 'info');
      return;
    }

    this.#showLoader(this.loaderAttachmentsTarget);
    try {
      const json = await this.#railsFetch(
        `/api/companies/${this.companyIdValue}/attachments`,
        { method: 'PATCH', body: this.#attachmentsPayload() },
      );

      // Se repinta con lo que quedó guardado, no con lo que había en pantalla: el
      // servidor limpia el nombre del archivo antes de escribirlo, así que el que
      // se eligió y el que quedó pueden no ser el mismo.
      if (json.Data) {
        this.#companyData = { ...this.#companyData, ...json.Data };
        this.#fillAttachmentsSection(this.#companyData);
      }

      showToast(json.Message || 'Adjuntos actualizados con éxito.', 'success');
    } catch (err) {
      // Error de escritura → modal, no toast (§9).
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al guardar adjuntos', message: err.message });
    } finally {
      this.#hideLoader(this.loaderAttachmentsTarget);
    }
  }

  /**
   * El cuerpo del PATCH de la sección — `FormData`, porque los dos campos son
   * archivos.
   *
   * Cada uno viaja SOLO si el usuario eligió uno nuevo: la parte ausente le dice
   * al endpoint que deje esa columna como está. Sin esa regla, guardar la sección
   * para cambiar el logo borraría el formato de impresión, porque el campo
   * muestra su nombre pero no vuelve a subir el archivo.
   */
  #attachmentsPayload() {
    const fd = new FormData();
    if (this.#selectedLogoFile)        fd.append('Logo',        this.#selectedLogoFile);
    if (this.#selectedPrintFormatFile) fd.append('PrintFormat', this.#selectedPrintFormatFile);

    return fd;
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

      // Los endpoints nativos contestan el motivo en el cuerpo (`ApiResponse`):
      // "El logo de la compañía no está disponible en el servidor" le dice al
      // usuario qué pasó, `HTTP 404` no.
      if (!response.ok) {
        const body = await response.json().catch(() => null);
        throw new Error(body?.Message || `HTTP ${response.status}`);
      }

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
    // La identificación de la compañía vive en "Datos Generales" pero condiciona
    // el guardado de la sección de Hacienda (el nombre del certificado y el token
    // tienen que contenerla), así que editarla también repinta ese botón.
    this.#refreshAtvSaveState();
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
    const headers = {
      'Accept': 'application/json',
      ...getApiHeaders(),
      ...(options.headers || {}),
    };

    // `getApiHeaders()` fija `Content-Type: application/json`. Un cuerpo
    // FormData trae el suyo con el boundary que el browser genera: dejarle el
    // de JSON encima hace que el servidor no encuentre las partes.
    if (options.body instanceof FormData) delete headers['Content-Type'];

    const response = await fetch(url, { ...options, headers });

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
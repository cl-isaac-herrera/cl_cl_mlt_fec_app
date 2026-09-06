import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { Storage, SStore } from 'vendor/clavisco/core';
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';
import { relativeDate } from 'vendor/clavisco/format/dates';

/**
 * DocumentsIssuedController — Búsqueda de documentos emitidos (FE/ND/NC/TE/FEC/FEE/REP).
 *
 * El listado consulta `GET /api/documents`, que a su vez pasa por
 * `Sap::IssuedDocumentsSearch` — en vivo contra SAP Service Layer, ya NO contra
 * el proxy .NET (`Api::DocumentsController`, `db/seeds.rb` sección 5,
 * `getDocuments01`..`10`). Dos consecuencias directas de ese cambio de fuente:
 *
 *   - El filtro "Tipo de Documento" ahora es OBLIGATORIO: cada tipo pega a un
 *     recurso distinto del catálogo (no hay forma de traer "todos" de una)
 *   - No hay `Total` de filas: el Service Layer no lo expone sin un header que
 *     el submódulo todavía no soporta (`TODOS.md` → SAP). Se usa `HasMore` en
 *     su lugar — el contador de paginación muestra el rango de la página
 *     actual, sin "de N filas".
 *
 * ⚠️ Fuera de alcance de esta migración (siguen pegándole al proxy .NET, con un
 * `Id` de fila que ya no existe en un resultado que viene de SAP — anotado en
 * `TODOS.md` → Emisión de documentos): Ver/Descargar PDF, Ver/Descargar XML
 * Hacienda, Descargar Doc XML, Correos, Omitir Validaciones, Anulación Interna,
 * Reprocesar, Descarga Masiva, y el gráfico "Más Información" (dependía de
 * `DocumentQtyList`, que el .NET calculaba y SAP no).
 */
export default class extends TabulatorController {
  static targets = [
    ...TabulatorController.targets,

    // Formulario de filtros
    'inputStartDate', 'inputEndDate',
    'inputConsecutivo', 'selectStatus',
    'inputCedula', 'inputCodigoMoneda',
    'inputClave', 'inputReceptor',
    'inputConsecutivoFE', 'selectDocType',

    // Toolbar
    'btnChart', 'btnBulkDownload', 'btnBulkDownloadWrap',

    // Panel lateral correos
    'emailModal', 'emailPanelBackdrop', 'emailLoader', 'emailTable', 'emailEmpty',
    'otherEmailsForm', 'inputEmailTo', 'errorEmailTo', 'inputEmailCC', 'errorEmailCC', 'btnResend',

    // Panel lateral info
    'infoModal', 'infoPanelBackdrop', 'infoClave', 'copyTooltip', 'infoFechaEmision',
    'infoErrorSection', 'infoError',
    'infoErrorHaciendaSection', 'infoErrorHacienda',

    // Modal chart
    'chartModal', 'chartCanvas',

    // Modal confirmación

    // Modal error
  ];

  static values = { ...TabulatorController.values };

  // ── Estado interno ─────────────────────────────────────────────────────────

  /** Empresa activa */
  #companyId = null;

  /** Permisos del usuario */
  #permissions = [];

  /** Tamaño de página actual (lo gestiona Tabulator, lo guardamos para bulkDownload) */
  #stepPos = 10;

  /**
   * Cantidad de filas que trajo la ÚLTIMA página (no el total: SAP no lo da,
   * ver cabecera del archivo). Alcanza para un contador de rango honesto
   * ("Mostrando X-Y") sin inventar un total que no existe.
   */
  #lastPageRowCount = 0;

  /**
   * Contadores de estado para el gráfico "Más Información". SIEMPRE vacío: sin
   * `DocumentQtyList` (el .NET lo calculaba, SAP no expone un conteo así) no hay
   * de dónde sacarlos, así que el botón queda oculto (ver `search()`) y
   * `openChartModal` avisa "sin datos" en vez de romper. Ver cabecera del archivo.
   */
  #quantities = {};

  /** Id del documento activo en el modal de correos */
  #activeEmailDocId = null;

  /** Gráfico (Chart.js) */
  #chart = null;


  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company     = SStore.get('CurrentCompany');
    const permissions = SStore.get('Permissions');

    this.#companyId   = company?.companyId ? parseInt(company.companyId) : null;
    this.#permissions = Array.isArray(permissions) ? permissions : [];

    // Botón descarga masiva: habilitado solo con permiso; si no, queda
    // deshabilitado con tooltip explicativo (ver CLAUDE.md §26).
    if (this.hasBtnBulkDownloadTarget) {
      if (this.#hasPerm('F_CreateBulkDownloadOfDocuments')) {
        this.#enableBulkDownloadButton();
      } else if (this.hasBtnBulkDownloadWrapTarget) {
        this.#attachTooltip(this.btnBulkDownloadWrapTarget);
      }
    }

    // Inicializar fechas con hoy
    const today = this.#todayISO();
    this.inputStartDateTarget.value = today;
    this.inputEndDateTarget.value   = today;

    // Leer ?clave= ANTES de super.connect() para que el primer request de Tabulator ya lo incluya
    const urlParams = new URLSearchParams(window.location.search);
    const claveParam = urlParams.get('clave');
    if (claveParam) this.inputClaveTarget.value = claveParam;

    super.connect(); // inicializa Tabulator; dispara ajaxRequestFunc con page=1 automáticamente
  }

  disconnect() {
    this.#chart?.destroy();
  }

  // ── Configuración Tabulator ────────────────────────────────────────────────

  getTableConfig() {
    const baseConfig = super.getTableConfig();
    delete baseConfig.data; // Eliminar data estático para que Tabulator use AJAX desde el inicio

    return {
      ...baseConfig,
      height: '100%',
      maxHeight: undefined,
      movableRows: false,
      layout: 'fitColumns',
      placeholder: 'No se encontraron documentos para los filtros aplicados.',
      // Paginación remota: Tabulator gestiona el UI; nosotros fetcheamos por página
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [5, 10, 15],
      // paginationCounter custom — SAP no da un total real (ver cabecera del archivo),
      // así que se muestra el rango de la página actual sin "de N filas" (CLAUDE.md §17
      // asume un total conocible; acá NO lo hay, y es a propósito).
      paginationCounter: (_pageSize, currentRow) => {
        if (!this.#lastPageRowCount) return '';
        const to = currentRow + this.#lastPageRowCount - 1;
        return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')}`;
      },
      // ajaxURL es requerido para activar el modo remote; el request real lo hace ajaxRequestFunc
      ajaxURL: '/api/documents',
      ajaxRequestFunc: (_url, _config, params) => this.#tabulatorRequest(params),
      ajaxResponse:    (_url, _params, response) => response,
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      columns: this.getColumns(),
    };
  }

  getColumns() {
    return [
      {
        // `DocDate` — fecha del documento en SAP, no la de emisión ante Hacienda.
        title: 'Fecha Factura',
        field: 'FechaFactura',
        width: 130,
      },
      {
        // Vacío hasta que Hacienda acepta el comprobante y asigna el
        // consecutivo — no es un dato faltante, es el estado normal de un
        // documento que todavía no se envió (o está en trámite).
        title: 'N° FE',
        field: 'NumeroConsecutivo',
        widthGrow: 2,
        formatter: (cell) => cell.getValue() || '<span class="text-gray-400">—</span>',
      },
      {
        title: 'N° Ref',
        field: 'Consecutivo',
        widthGrow: 1,
      },
      {
        title: 'Receptor',
        field: 'RcprNombre',
        widthGrow: 2,
      },
      {
        title: 'Estado',
        field: 'StatusForTable',
        width: 140,
        hozAlign: 'left',
        formatter: (cell) => this.#statusBadge(cell.getValue()),
      },
      {
        title: 'Total',
        field: 'TotalComprobante',
        width: 130,
        hozAlign: 'right',
      },
      {
        title: 'Acciones',
        field: 'Id',
        width: 80,
        hozAlign: 'center',
        formatter: () => this.#optionsButton(),
        cellClick: (e, cell) => {
          if (e.target.closest('[data-action-type="options"]')) {
            this.#showRowDropdown(e, cell.getRow().getData());
          }
        },
      },
    ];
  }

  // ── API fetch (llamado por Tabulator en cada cambio de página/tamaño) ────────

  async #tabulatorRequest(params) {
    // params.page = página actual (1-based), params.size = registros por página.
    // El backend clampea per_page a Sap::IssuedDocumentsSearch::MAX_PAGE_SIZE (19)
    // — bien por encima de [5,10,15] (paginationSizeSelector), así que nunca se
    // choca contra el techo real de 20 filas por respuesta de SAP.
    const page     = params.page || 1;
    const pageSize = params.size || 10;
    this.#stepPos  = pageSize;

    const docType = this.selectDocTypeTarget.value;

    const queryParams = new URLSearchParams({
      doc_type:       docType,
      start_date:     this.inputStartDateTarget.value,
      end_date:       this.inputEndDateTarget.value,
      status:         this.selectStatusTarget.value,
      consecutivo:    this.inputConsecutivoTarget.value,
      consecutivo_fe: this.inputConsecutivoFETarget.value,
      receptor:       this.inputReceptorTarget.value,
      cedula:         this.inputCedulaTarget.value,
      clave:          this.inputClaveTarget.value,
      codigo_moneda:  this.inputCodigoMonedaTarget.value,
      page,
      per_page: pageSize,
    });

    const json = await this.#apiFetch(`/api/documents?${queryParams}`);

    if (!json.Data) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Se produjo un error al obtener los documentos', message: json.Message || 'Error desconocido' });
      // Retornar formato válido para que Tabulator no quede en estado roto
      this.#lastPageRowCount = 0;
      return { data: [], last_page: 1 };
    }

    const docs = (json.Data.Items || []).map(d => this.#mapDocument(d, docType));
    this.#lastPageRowCount = docs.length;

    // Sin un total real (ver cabecera del archivo), `last_page` es "esta página
    // + 1" cuando SAP avisó que hay más, o la página actual cuando no —
    // suficiente para que el botón "Siguiente" de Tabulator se habilite o no.
    const lastPage = json.Data.HasMore ? page + 1 : page;

    showToast('Documentos obtenidos correctamente!', 'success');

    // Tabulator espera { data: [...], last_page: N } para paginación remota
    return { data: docs, last_page: lastPage };
  }

  // `doc` trae los campos crudos de SAP (`DocEntry`, `DocDate`, `DocNum`,
  // `CardName`, `DocCurrency`, `DocTotal`, `U_CL_FEC_*`) — se traducen acá a
  // los nombres que usan las columnas de la tabla. `docType` es el filtro con el que se buscó
  // (SAP no lo devuelve en la fila): se estampa para que el dropdown de
  // acciones pueda decidir según tipo (ej. "Anulación Interna" solo en FEC).
  //
  // `Id` queda como alias de `DocEntry` — las acciones por fila (PDF, XML,
  // reprocesar, …) siguen sin migrar y esperan un `Id` que ya no existe en un
  // resultado que viene de SAP (ver cabecera del archivo).
  #mapDocument(doc, docType) {
    return {
      Id: doc.DocEntry,
      DocType: docType,
      NumeroConsecutivo: doc.U_CL_FEC_NumConsecutivo,
      Consecutivo: doc.DocNum,
      RcprNombre: doc.CardName,
      Clave: doc.U_CL_FEC_Clave,
      ErrDetails: doc.U_CL_FEC_ErrorDetails,
      Status: doc.U_CL_FEC_Status,
      StatusForTable: this.#statusLabel(doc.U_CL_FEC_Status),
      FechaFactura: this.#formatDate(doc.DocDate),
      // Sin columna propia en la tabla (se sacó a pedido): sigue viajando
      // cruda para el panel "Consultar Información" (`#openInfoModal`).
      FechaEmision: doc.U_CL_FEC_FechaEmision,
      TotalComprobante: this.#normalizeCurrency(doc.DocCurrency) + ' ' +
                        Number(doc.DocTotal || 0).toFixed(2).replace(/\d(?=(\d{3})+\.)/g, '$&,'),
    };
  }

  #normalizeCurrency(code) {
    if (code === '₡' || code === '¢') return '₡';
    if (code === '$') return '$';
    if (code === '€') return '€';
    return code || '';
  }

  // ── Formatters ────────────────────────────────────────────────────────────

  // Devuelve texto del estado para mostrar en la tabla como badge. Los códigos
  // son los de `U_CL_FEC_Status` (el UDF que escribe la sincronización de
  // emitidos — `config/sap_schemas/marketing_documents.json`,
  // `db/external/sql_server/schema.sql` StatusCodes), NO los del `.NET` legacy
  // (que numeraba 1=Aceptado..7=Anulado): esos dos catálogos no coinciden.
  #statusLabel(status) {
    const map = {
      0: { label: 'Pendiente', bg: '#fffbeb', color: '#b45309' },
      3: { label: 'Enviado',   bg: '#e8f0fe', color: '#1a56db' },
      4: { label: 'Error',     bg: '#fdecea', color: '#c0392b' },
      6: { label: 'Aceptado',  bg: '#e8f5ee', color: '#3a7d52' },
      7: { label: 'Rechazado', bg: '#fef2f2', color: '#991b1b' },
    };
    return map[status] ? { ...map[status], status } : { label: 'N/A', bg: '#f3f4f6', color: '#6b7280', status };
  }

  #statusBadge(val) {
    if (!val || typeof val !== 'object') return '';
    if (val.loading) return this.#sendingBadge();
    return `<span style="background-color:${val.bg}; color:${val.color};"
                  class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${val.label}
    </span>`;
  }

  /** Badge transitorio que se muestra en la celda Estado mientras se envía la solicitud de reprocesamiento */
  #sendingBadge() {
    return `<span style="background-color:#e8f0fe; color:#1a56db;"
                  class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      <span class="inline-block h-3 w-3 rounded-full border-2 border-current border-t-transparent animate-spin"></span>
      Enviando
    </span>`;
  }

  #optionsButton() {
    return `
      <button type="button" data-action-type="options" data-tooltip="Opciones"
              class="p-1.5 text-gray-600 rounded hover:bg-gray-100 transition-colors cursor-pointer">
        <span class="material-icons text-base">more_vert</span>
      </button>`;
  }

  // ── Dropdown de opciones por fila ─────────────────────────────────────────

  #showRowDropdown(e, row) {
    // Eliminar dropdown previo si existe
    document.getElementById('cl-row-dropdown')?.remove();

    const options = [
      { label: 'Ver PDF',               icon: 'picture_as_pdf', action: 'view-pdf'     },
      { label: 'Descargar PDF',         icon: 'download',       action: 'download-pdf' },
      {
        // Códigos de `U_CL_FEC_Status`: 6 Aceptado, 7 Rechazado (ver #statusLabel).
        label: 'Ver XML (Resp Hacienda)', icon: 'terminal', action: 'view-xml',
        disabled: row.Status !== 6 && row.Status !== 7,
        disabledReason: 'Solo disponible para documentos en estado Aceptado o Rechazado',
      },
      {
        label: 'Descargar XML (Resp Hacienda)', icon: 'download', action: 'download-xml',
        disabled: row.Status !== 6 && row.Status !== 7,
        disabledReason: 'Solo disponible para documentos en estado Aceptado o Rechazado',
      },
      {
        label: 'Descargar Doc XML', icon: 'description', action: 'download-doc-xml',
        disabled: row.Status === 4,
        disabledReason: 'No disponible para documentos en estado Error',
      },
      { label: 'Correos',               icon: 'mail',     action: 'emails' },
      { label: 'Consultar Información', icon: 'info',     action: 'info'   },
      {
        label: 'Omitir Validaciones', icon: 'lock_open', action: 'skip-validations',
        disabled: row.Status !== 4,
        disabledReason: 'Solo disponible para documentos en estado Error',
      },
      {
        // `U_CL_FEC_Status` no tiene un código de "anulado internamente" (solo
        // Pendiente/Enviado/Error/Aceptado/Rechazado) — a diferencia del enum
        // legacy, que sí lo tenía. Sin esa marca no se puede saber acá si ya
        // se anuló antes; queda pendiente junto con la migración de la acción
        // (`TODOS.md` → Emisión de documentos).
        label: 'Anulación Interna', icon: 'cancel', action: 'internal-cancel',
        disabled: row.DocType !== '08',
        disabledReason: 'Solo disponible para documentos de tipo FEC (08)',
      },
      {
        label: 'Reprocesar', icon: 'autorenew', action: 'reprocess',
        disabled: row.Status !== 7,
        disabledReason: 'Solo disponible para documentos en estado Rechazado',
      },
    ];

    const menu = document.createElement('div');
    menu.id = 'cl-row-dropdown';
    menu.className = 'fixed bg-white border border-gray-200 rounded-lg shadow-xl z-[9999] py-1 min-w-[210px]';
    menu.style.top  = `${e.clientY}px`;
    menu.style.left = `${e.clientX}px`;

    options.forEach(opt => {
      const wrapper = document.createElement('div');
      wrapper.className = 'relative group/opt';

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = opt.disabled
        ? 'w-full flex items-center gap-2 px-3 py-2 text-sm text-gray-400 cursor-not-allowed'
        : 'w-full flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50 transition-colors';
      btn.innerHTML = `<span class="material-icons text-base">${opt.icon}</span>${opt.label}`;
      btn.disabled = !!opt.disabled;

      if (!opt.disabled) {
        btn.addEventListener('click', () => {
          menu.remove();
          this.#handleRowAction(opt.action, row);
        });
      }

      wrapper.appendChild(btn);

      // Tooltip descriptivo solo en opciones inhabilitadas — position:fixed para evitar clipping
      if (opt.disabled && opt.disabledReason) {
        btn.addEventListener('mouseenter', (ev) => {
          this.#showDropdownTooltip(ev, opt.disabledReason);
        });
        btn.addEventListener('mouseleave', () => {
          this.#hideDropdownTooltip();
        });
      }

      menu.appendChild(wrapper);
    });

    document.body.appendChild(menu);

    // Cerrar al hacer click fuera
    const close = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        this.#hideDropdownTooltip();
        document.removeEventListener('click', close);
      }
    };
    setTimeout(() => document.addEventListener('click', close), 0);

    // Ajustar para que no salga de la ventana
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth)  menu.style.left = `${window.innerWidth - rect.width - 8}px`;
    if (rect.bottom > window.innerHeight) menu.style.top = `${window.innerHeight - rect.height - 8}px`;
  }

  async #handleRowAction(action, row) {
    switch (action) {
      case 'view-pdf':         this.#viewPDF(row.Id);          break;
      case 'download-pdf':     this.#downloadPDF(row.Id, row.NumeroConsecutivo); break;
      case 'view-xml':         this.#viewXML(row.Id);          break;
      case 'download-xml':     this.#downloadXML(row.Id, row.NumeroConsecutivo); break;
      case 'download-doc-xml': this.#downloadDocXML(row.Id, row.NumeroConsecutivo); break;
      case 'emails':           this.#openEmailModal(row.Id);   break;
      case 'info':             this.#openInfoModal(row);        break;
      case 'skip-validations': this.#skipValidations(row.Id);  break;
      case 'internal-cancel':  this.#internalCancel(row);      break;
      case 'reprocess':        this.#reprocess(row.Id);        break;
    }
  }

  // ── Acciones de fila ──────────────────────────────────────────────────────

  async #viewPDF(id) {
    try {
      const json = await this.#apiFetch(`/api/Report/PrintInvoicePDF?id=${id}`);
      if (!json.Data) { showToast('No se pudo obtener el PDF', 'error'); return; }
      this.#openBase64InTab(json.Data, 'application/pdf');
      showToast('Información cargada con éxito!', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  async #downloadPDF(id, numeroConsecutivo) {
    try {
      const json = await this.#apiFetch(`/api/Report/DownloadInvoicePDF?id=${id}`);
      if (!json.Data) { showToast('No se pudo descargar el PDF', 'error'); return; }
      this.#downloadBase64(json.Data, `${numeroConsecutivo}-PDF`, 'application/pdf');
      showToast('Proceso de descarga exitoso!', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  async #viewXML(id) {
    try {
      const json = await this.#apiFetch(`/api/Documents/PrintDocumentXML?docId=${id}`);
      if (!json.Data?.HrRespuestaXml) { showToast('No se encontró respuesta XML', 'error'); return; }
      this.#openBase64InTab(json.Data.HrRespuestaXml, 'application/xml');
      showToast('Información cargada con éxito!', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  async #downloadXML(id, numeroConsecutivo) {
    try {
      const json = await this.#apiFetch(`/api/Documents/DownloadDocumentXML?docId=${id}`);
      if (!json.Data?.HrRespuestaXml) { showToast('No se pudo descargar el XML', 'error'); return; }
      this.#downloadBase64(json.Data.HrRespuestaXml, `${numeroConsecutivo}-XMLRESP`, 'application/xml');
      showToast('Proceso de descarga exitoso!', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  async #downloadDocXML(id, numeroConsecutivo) {
    try {
      const json = await this.#apiFetch(`/api/Documents/GetXMLDoc?docId=${id}`);
      if (!json.Data?.XmlSent) { showToast('No se pudo descargar el XML del documento', 'error'); return; }
      const decoded = this.#b64DecodeUnicode(json.Data.XmlSent);
      const blob = new Blob([decoded], { type: 'application/xml' });
      this.#saveBlob(blob, `${numeroConsecutivo}-XMLDOC`);
      showToast('Proceso de descarga exitoso!', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  async #skipValidations(docId) {
    const confirmed = await confirm('Esta acción omitirá las validaciones y enviará el documento a Hacienda con errores bajo su propia responsabilidad. ¿Está seguro que desea continuar?', 'Omitir validaciones');
    if (!confirmed) return;
    try {
      const session = Storage.get('Session') || {};
      await this.#apiFetch('/api/Documents', {
        method: 'PATCH',
        body: JSON.stringify({ docId, feToken: '' }),
      });
      showToast('Estado cambiado con éxito', 'success');
      this.table?.replaceData();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al omitir validaciones', message: err.message });
    }
  }

  async #internalCancel(row) {
    // Códigos de `U_CL_FEC_Status` — ver #statusLabel.
    const statusLabels = { 0: 'Pendiente', 3: 'Enviado', 4: 'Error', 6: 'Aceptado', 7: 'Rechazado' };
    const statusText = statusLabels[row.Status] || 'Desconocido';

    const confirmed = await confirm('¿Está seguro que desea continuar?', `Esta acción anulará de manera interna la FEC bajo su propia responsabilidad, la cuál se encuentra en estado: ${statusText}`);
    if (!confirmed) return;
    try {
      await this.#apiFetch('/api/Documents/SetDocStatusInternalCancelled', {
        method: 'PATCH',
        body: JSON.stringify({ docId: row.Id, feToken: '' }),
      });
      showToast('Documento anulado con éxito', 'success');
      this.table?.replaceData();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al anular el documento', message: err.message });
    }
  }

  async #reprocess(docId) {
    if (!this.#hasPerm('Documents_Emission_Reprocess')) {
      showToast('No tiene permiso para realizar esta acción', 'info');
      return;
    }
    // Loader a nivel de fila: marca la celda Estado como "Enviando" durante la solicitud
    const currentPage = this.table?.getPage() || 1;
    const rowComp = this.table?.getRows().find(r => r.getData().Id === docId);
    rowComp?.update({ StatusForTable: { loading: true } });
    try {
      // ApiFEUrl: este endpoint vive en el servidor de sincronización FE, no en el App server
      await this.#apiFetch(
        `/api/Documents/${docId}/Reprocess?isReceptionDocument=false&companyId=${this.#companyId}`,
        { method: 'PATCH', body: JSON.stringify({}), headers: { 'API': 'ApiFEUrl' } }
      );
      showToast('Solicitud de reprocesamiento enviada', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    } finally {
      // Refrescar manteniéndose en la página actual: setPage(n) recarga esa página desde el
      // servidor con los filtros vigentes (replaceData/setData resetean a la página 1).
      // Si tras refrescar la página quedó fuera de rango porque bajó el total (p.ej. se
      // reprocesó el último registro de la página), navegar a la última página válida.
      await this.table?.setPage(currentPage).catch(() => {});
      const maxPage = this.table?.getPageMax?.() ?? 1;
      if (currentPage > maxPage) await this.table?.setPage(maxPage).catch(() => {});
    }
  }

  // ── Panel lateral Correos ─────────────────────────────────────────────────

  // Chip de ícono con tooltip CSS (patrón group-hover, §2 — fuera de Tabulator).
  // Conserva el look de dos tonos del badge: fondo tenue + ícono en color oscuro.
  // El tooltip se posiciona DEBAJO del ícono para que no lo recorte el
  // overflow-hidden del card.
  #iconTooltip(icon, bg, color, label) {
    return `<span class="relative group inline-flex items-center">
      <span class="inline-flex items-center justify-center rounded-full p-1 cursor-default"
            style="background-color:${bg}; color:${color}">
        <span class="material-icons" style="font-size:14px; line-height:1">${icon}</span>
      </span>
      <span class="pointer-events-none absolute top-full left-1/2 -translate-x-1/2 mt-1 z-20
                   whitespace-nowrap rounded bg-gray-800 text-white text-[11px] px-2 py-1
                   opacity-0 group-hover:opacity-100 transition-opacity duration-150">${label}</span>
    </span>`;
  }

  // Ícono + tooltip para EmailSendType (Tipo del correo)
  #emailTypeBadge(code) {
    const map = {
      1: { label: 'Envío',    icon: 'send',             bg: '#e8f0fe', color: '#1a56db' },
      2: { label: 'Reenvío',  icon: 'forward_to_inbox', bg: '#fffbeb', color: '#b45309' },
      3: { label: 'Receptor', icon: 'call_received',    bg: '#e8f5ee', color: '#3a7d52' },
    };
    const s = map[Number(code)] ?? { label: String(code ?? ''), icon: 'mail', bg: '#f3f4f6', color: '#4b5563' };
    return this.#iconTooltip(s.icon, s.bg, s.color, s.label);
  }

  // Ícono + tooltip para MessageStatus (Estado del correo)
  #emailStatusBadge(code) {
    const map = {
      1: { label: 'Pendiente', icon: 'schedule',     bg: '#f3f4f6', color: '#6b7280' },
      2: { label: 'Enviando',  icon: 'sync',         bg: '#e8f0fe', color: '#1a56db' },
      3: { label: 'Error',     icon: 'error',        bg: '#fdecea', color: '#c0392b' },
      4: { label: 'Enviado',   icon: 'check_circle', bg: '#e8f5ee', color: '#3a7d52' },
    };
    const s = map[Number(code)] ?? { label: String(code ?? ''), icon: 'help', bg: '#f3f4f6', color: '#4b5563' };
    return this.#iconTooltip(s.icon, s.bg, s.color, s.label);
  }

  async #openEmailModal(docId) {
    this.#activeEmailDocId = docId;
    this.otherEmailsFormTarget.classList.add('hidden');
    this.inputEmailToTarget.value = '';
    this.inputEmailCCTarget.value = '';

    this.#openEmailPanel();
    this.#setEmailState('loading');

    try {
      const json = await this.#apiFetch(`/api/Email/GetOutgoingMails?docId=${docId}`);

      if (!json.Data?.length) {
        this.#setEmailState('empty');
        return;
      }

      const mails = json.Data.map(m => ({
        ...m,
        CreateDate: m.CreateDate ? m.CreateDate.replace('T', ' ').substring(0, 19) : '',
      }));

      this.#buildEmailTable(mails);
      this.#setEmailState('table');
      showToast('Datos obtenidos con éxito', 'success');
    } catch (err) {
      this.#setEmailState('empty');
      showToast(err.message, 'error');
    }
  }

  // Alterna entre los tres estados visuales del panel de correos
  #setEmailState(state) {
    this.emailLoaderTarget.classList.toggle('hidden', state !== 'loading');
    this.emailTableTarget.classList.toggle('hidden',  state !== 'table');
    this.emailEmptyTarget.classList.toggle('hidden',  state !== 'empty');
    this.#updateResendButton();
  }

  // Habilita Reenviar según el contexto:
  //   - Hay correos en tabla Y el form de otros destinatarios está cerrado
  //   - El form de otros destinatarios está abierto Y tiene al menos un campo con valor válido
  #updateResendButton() {
    const hasTable        = !this.emailTableTarget.classList.contains('hidden');
    const otherEmailsOpen = !this.otherEmailsFormTarget.classList.contains('hidden');
    const toValue         = this.inputEmailToTarget.value.trim();
    const ccValue         = this.inputEmailCCTarget.value.trim();
    const hasRecipient    = toValue.length > 0 || ccValue.length > 0;
    const fieldsValid     = (toValue.length === 0 || this.#isValidEmail(toValue))
                         && (ccValue.length === 0  || this.#isValidEmailList(ccValue));

    const enabled = otherEmailsOpen
      ? hasRecipient && fieldsValid
      : hasTable;

    this.btnResendTarget.disabled = !enabled;
  }

  #openEmailPanel() {
    this.emailPanelBackdropTarget.classList.remove('hidden');
    this.emailModalTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  closeEmailPanel() {
    this.emailModalTarget.classList.add('translate-x-full');
    this.emailPanelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // El panel es angosto (max-w-2xl): una tabla de 8 columnas trunca todo.
  // Se renderiza como lista vertical de tarjetas — usa el alto disponible y
  // muestra cada campo completo sin scroll horizontal. Ver §8 (paneles laterales).
  #buildEmailTable(data) {
    this.emailTableTarget.innerHTML = `
      <div class="space-y-3">
        ${data.map((m, i) => this.#emailCard(m, i)).join('')}
      </div>`;
  }

  // Normaliza un valor de texto de la API: null/undefined/""/"null" → "—".
  // (escapeHtml(null) produce el literal "null", que es truthy y rompe el `|| '—'`.)
  #mailText(value) {
    if (value == null) return '—';
    const str = String(value).trim();
    if (str === '' || str.toLowerCase() === 'null') return '—';
    return this.#escapeHtml(str);
  }

  // Parsea una lista de correos concatenados por ";" en un arreglo limpio
  // (sin vacíos ni el literal "null"). Devuelve [] si no hay ninguno.
  #parseEmails(value) {
    if (value == null) return [];
    return String(value)
      .split(';')
      .map((e) => e.trim())
      .filter((e) => e !== '' && e.toLowerCase() !== 'null');
  }

  // Renderiza una lista de correos (separados por ";") como chips individuales.
  // Si no hay ninguno, devuelve "—".
  #emailChips(value) {
    const emails = this.#parseEmails(value);

    if (!emails.length) return '<span class="text-sm text-gray-700">—</span>';

    return `
      <div class="flex flex-wrap gap-1.5">
        ${emails.map((e) => `
          <span class="inline-flex items-center max-w-full bg-gray-100 text-gray-700 text-xs font-medium px-2 py-0.5 rounded-md break-all">
            ${this.#escapeHtml(e)}
          </span>`).join('')}
      </div>`;
  }

  // Span de fecha relativa (relativeDate compartido) con la fecha original
  // completa en el tooltip. Si no hay valor, devuelve "—" sin tooltip ni cursor-help.
  #relativeDateSpan(value, className) {
    const raw = (value == null) ? '' : String(value).trim();
    const hasValue = raw !== '' && raw.toLowerCase() !== 'null';
    if (!hasValue) return `<span class="${className}">—</span>`;
    return `<span class="${className} cursor-help" title="${this.#escapeHtml(raw)}">${relativeDate(value)}</span>`;
  }

  // Color de la franja lateral según el estado del correo (MessageStatus).
  // Se usa como estilo inline (igual que los badges de este archivo) para que no
  // dependa del purge de Tailwind sobre clases presentes solo en strings JS.
  #emailStripeColor(code) {
    const map = { 1: '#d1d5db', 2: '#3b82f6', 3: '#ef4444', 4: '#16a34a' };
    return map[Number(code)] ?? '#d1d5db';
  }

  // Una tarjeta por correo — diseño "timeline": franja lateral coloreada según
  // el estado del correo, cabecera con fecha + badges, línea de destinatarios con
  // CC colapsable, detalle del error truncado en una línea (clic para expandir /
  // contraer) y el último intento alineado al final.
  #emailCard(m, i) {
    const toEmails = this.#parseEmails(m.OutputTo);
    const ccEmails = this.#parseEmails(m.OutputCC);
    const detail   = this.#mailText(m.Details);
    const hasDetail = detail !== '—';

    const toHtml = toEmails.length
      ? toEmails.map((e) => `<span class="text-gray-700 break-all">${this.#escapeHtml(e)}</span>`)
          .join('<span class="text-gray-300">,</span> ')
      : '<span class="text-gray-400">—</span>';

    const ccPart = ccEmails.length
      ? `<span class="text-gray-300 mx-1.5">·</span><button type="button"
                 data-action="documents-issued#toggleEmailCC"
                 data-cc-target="email-cc-${i}"
                 data-label-closed="CC (${ccEmails.length})"
                 data-label-open="Ocultar CC"
                 class="text-xs font-medium text-blue-600 hover:text-blue-700 cursor-pointer">CC (${ccEmails.length})</button>`
      : '<span class="text-gray-300 mx-1.5">·</span><span class="text-gray-400">Sin CC</span>';

    const ccList = ccEmails.length
      ? `<div id="email-cc-${i}" class="hidden mt-2 max-h-24 overflow-y-auto">${this.#emailChips(m.OutputCC)}</div>`
      : '';

    const detailsBlock = hasDetail ? `
        <div id="email-prev-${i}"
             data-action="click->documents-issued#showEmailDetails"
             data-target-full="email-det-${i}"
             title="Clic para ver el mensaje completo"
             class="mt-3 font-mono text-xs text-gray-400 hover:text-gray-600 truncate cursor-pointer">${detail}</div>
        <div id="email-det-${i}" data-email-details
             class="hidden mt-3 font-mono text-xs text-gray-600 bg-gray-50 rounded-md p-3 break-words max-h-40 overflow-y-auto">
          ${detail}
          <div class="text-right mt-2">
            <button type="button"
                    data-action="documents-issued#hideEmailDetails"
                    data-target-prev="email-prev-${i}"
                    class="text-xs font-semibold text-blue-600 hover:text-blue-700 cursor-pointer">Contraer</button>
          </div>
        </div>` : '';

    return `
      <div data-email-card class="flex overflow-hidden border border-gray-200 rounded-lg">
        <div class="w-1 flex-shrink-0" style="background-color:${this.#emailStripeColor(m.Status)}"></div>
        <div class="flex-1 min-w-0 p-4">
          <div class="flex items-start justify-between gap-2">
            <div class="flex items-center flex-wrap gap-2">
              ${this.#relativeDateSpan(m.CreateDate, 'text-sm font-semibold text-gray-800')}
              ${this.#emailStatusBadge(m.Status)}
              ${this.#emailTypeBadge(m.Type)}
            </div>
            <span class="text-xs text-gray-400 whitespace-nowrap flex-shrink-0">último intento: ${this.#relativeDateSpan(m.LastAttempt, 'text-xs text-gray-500')}</span>
          </div>

          <div class="mt-3 text-xs">
            <span class="text-gray-400 mr-1.5">Para:</span>
            <span class="text-gray-700 break-all">${toHtml}</span>
            ${ccPart}
          </div>
          ${ccList}

          ${detailsBlock}
        </div>
      </div>`;
  }

  // Toggle de la lista de CC dentro de un card de correo
  toggleEmailCC(event) {
    const btn  = event.currentTarget;
    const list = document.getElementById(btn.dataset.ccTarget);
    if (!list) return;
    const isOpen = !list.classList.contains('hidden');
    list.classList.toggle('hidden');
    btn.textContent = isOpen ? btn.dataset.labelClosed : btn.dataset.labelOpen;
  }

  // Muestra el detalle completo del error (oculta el preview truncado)
  showEmailDetails(event) {
    const prev = event.currentTarget;
    const full = document.getElementById(prev.dataset.targetFull);
    prev.classList.add('hidden');
    full?.classList.remove('hidden');
  }

  // Contrae el detalle del error (vuelve al preview truncado)
  hideEmailDetails(event) {
    const btn  = event.currentTarget;
    const full = btn.closest('[data-email-details]');
    const prev = document.getElementById(btn.dataset.targetPrev);
    full?.classList.add('hidden');
    prev?.classList.remove('hidden');
  }

  onEmailRecipientInput() {
    this.#validateEmailFields();
    this.#updateResendButton();
  }

  // Regex para un correo electrónico individual
  #EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  #isValidEmail(value) {
    return this.#EMAIL_REGEX.test(value.trim());
  }

  #isValidEmailList(value) {
    if (!value.trim()) return true; // vacío es válido (campo opcional)
    return value.split(';').every(e => this.#isValidEmail(e));
  }

  #validateEmailFields() {
    const toValue = this.inputEmailToTarget.value.trim();
    const ccValue = this.inputEmailCCTarget.value.trim();

    // Validar Para — solo si tiene valor
    const toInvalid = toValue.length > 0 && !this.#isValidEmail(toValue);
    this.inputEmailToTarget.classList.toggle('border-red-400', toInvalid);
    this.inputEmailToTarget.classList.toggle('focus:ring-red-400', toInvalid);
    this.errorEmailToTarget.classList.toggle('hidden', !toInvalid);

    // Validar CC — solo si tiene valor
    const ccInvalid = ccValue.length > 0 && !this.#isValidEmailList(ccValue);
    this.inputEmailCCTarget.classList.toggle('border-red-400', ccInvalid);
    this.inputEmailCCTarget.classList.toggle('focus:ring-red-400', ccInvalid);
    this.errorEmailCCTarget.classList.toggle('hidden', !ccInvalid);

    return !toInvalid && !ccInvalid;
  }

  toggleOtherEmails() {
    this.otherEmailsFormTarget.classList.toggle('hidden');
    this.#updateResendButton();
  }

  async resendEmail() {
    if (!this.#validateEmailFields()) return;
    try {
      const otherEmails = !this.otherEmailsFormTarget.classList.contains('hidden');
      const mailTo = this.inputEmailToTarget.value.trim();
      const mailCC = this.inputEmailCCTarget.value.trim();

      await this.#apiFetch('/api/Email/', {
        method: 'POST',
        body: JSON.stringify({
          DocId:       this.#activeEmailDocId,
          OtherEmails: otherEmails,
          MailTo:      mailTo,
          MailCC:      mailCC,
        }),
      });
      showToast('Datos listos para el reenvío', 'success');

      // Limpiar campos y refrescar tabla
      this.inputEmailToTarget.value = '';
      this.inputEmailCCTarget.value = '';
      await this.#refreshEmailTable();
    } catch (err) {
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al reenviar correo', message: err.message });
    }
  }

  async #refreshEmailTable() {
    this.#setEmailState('loading');
    try {
      const json = await this.#apiFetch(`/api/Email/GetOutgoingMails?docId=${this.#activeEmailDocId}`);

      if (!json.Data?.length) {
        this.#setEmailState('empty');
        return;
      }

      const mails = json.Data.map(m => ({
        ...m,
        CreateDate: m.CreateDate ? m.CreateDate.replace('T', ' ').substring(0, 19) : '',
      }));

      this.#buildEmailTable(mails);
      this.#setEmailState('table');
    } catch {
      this.#setEmailState('empty');
    }
  }

  // ── Panel lateral Información ─────────────────────────────────────────────

  async #openInfoModal(row) {
    this.infoClaveTarget.textContent        = row.Clave || '';
    this.infoFechaEmisionTarget.textContent = this.#formatDateTime(row.FechaEmision);

    // `U_CL_FEC_ErrorDetails` mezcla dos cosas en un solo campo: el texto
    // técnico propio (antes de "[") y, cuando Hacienda rechaza, el array con
    // código+mensaje por cada error — `#formatHaciendaError` ya sabía separar
    // eso (lo usa la sección de abajo), así que se reutiliza acá en vez de
    // volcar el string crudo.
    if (row.ErrDetails) {
      this.infoErrorTarget.innerHTML = this.#formatHaciendaError(row.ErrDetails);
      this.infoErrorSectionTarget.classList.remove('hidden');
    } else {
      this.infoErrorSectionTarget.classList.add('hidden');
    }

    this.infoErrorHaciendaSectionTarget.classList.add('hidden');
    if (row.Status === 7) { // Rechazado (`U_CL_FEC_Status`) — ver #statusLabel
      try {
        const json = await this.#apiFetch(`/api/Documents/issued/${row.Id}/xml-response-message`);
        if (json.Data?.HrRespuestaXml) {
          this.infoErrorHaciendaTarget.innerHTML = this.#formatHaciendaError(json.Data.HrRespuestaXml);
          this.infoErrorHaciendaSectionTarget.classList.remove('hidden');
        }
      } catch {
        // No bloquear el panel por esto
      }
    }

    this.infoPanelBackdropTarget.classList.remove('hidden');
    this.infoModalTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';
  }

  async copyClave() {
    const clave = this.infoClaveTarget.textContent.trim();
    if (!clave) return;
    try {
      await navigator.clipboard.writeText(clave);
    } catch {
      // Fallback para contextos sin permisos de clipboard
      const ta = document.createElement('textarea');
      ta.value = clave;
      ta.style.position = 'fixed';
      ta.style.opacity  = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
    }
    // Mostrar tooltip "¡Copiado!" y ocultarlo tras 1.5s
    this.copyTooltipTarget.classList.remove('hidden');
    clearTimeout(this._copyTooltipTimer);
    this._copyTooltipTimer = setTimeout(() => {
      this.copyTooltipTarget.classList.add('hidden');
    }, 1500);
  }

  closeInfoPanel() {
    this.infoModalTarget.classList.add('translate-x-full');
    this.infoPanelBackdropTarget.classList.add('hidden');
    document.body.style.overflow = '';
  }

  // ── Modal Chart ────────────────────────────────────────────────────────────

  openChartModal() {
    const q = this.#quantities;
    const values = [
      q[1] || 0, // Aceptado
      q[2] || 0, // Procesando
      q[3] || 0, // En Hacienda
      q[4] || 0, // Rechazado
      q[5] || 0, // Error
      q[7] || 0, // Cancelado
    ];

    const total = values.reduce((a, b) => a + b, 0);
    if (total === 0) {
      showToast('No hay datos para mostrar', 'warning');
      return;
    }

    this.chartModalTarget.classList.remove('hidden');

    // Construir/actualizar chart con Chart.js (disponible en CDN)
    if (typeof Chart === 'undefined') {
      const script = document.createElement('script');
      script.src = 'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js';
      script.onload = () => this.#renderChart(values);
      document.head.appendChild(script);
    } else {
      this.#renderChart(values);
    }
  }

  #renderChart(values) {
    this.#chart?.destroy();
    const ctx = this.chartCanvasTarget.getContext('2d');
    this.#chart = new Chart(ctx, {
      type: 'doughnut',
      data: {
        labels: ['Aceptado', 'Procesando', 'En Hacienda', 'Rechazado', 'Error', 'Anulado'],
        datasets: [{
          data: values,
          backgroundColor: ['#6BBC86', '#1a56db', '#1a56db', '#EC7063', '#FFC300', '#EC7063'],
        }],
      },
      options: {
        responsive: true,
        plugins: { legend: { position: 'bottom' } },
      },
    });
  }

  closeChartModal() {
    this.chartModalTarget.classList.add('hidden');
  }

  // ── Descarga Masiva ────────────────────────────────────────────────────────

  async bulkDownload() {
    const confirmed = await confirm('Se creará una solicitud de descarga masiva según los filtros aplicados. Los archivos serán enviados al correo del usuario que ejecuta la acción.', 'Descarga masiva de documentos', ALERT_TYPES.INFO);
    if (!confirmed) return;
    {

        try {
          const today = new Date().toISOString().split('T')[0];
          await this.#apiFetch('/api/Report/BulkDownloadOfDocuments/', {
            method: 'POST',
            body: JSON.stringify({
              Id: 0,
              CreationDate: today,
              UserId: '',
              StartDate: this.inputStartDateTarget.value,
              EndDate: this.inputEndDateTarget.value,
              CompanyId: this.#companyId,
              DocType: 1,
              Status: 0,
              AttemptsToSend: 0,
              LastAttempt: null,
              UseXMLDate: false,
              KindOfDocuments: '01',
              ToEmail: '',
              CCEmail: '',
            }),
          });
          showToast('Solicitud creada con éxito!!!', 'success');
        } catch (err) {
          showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al crear solicitud de descarga masiva', message: err.message });
        }
    }
  }

  // ── Formulario handlers ────────────────────────────────────────────────────

  search() {
    this.btnChartTarget.classList.add('hidden');
    // setPage(1) dispara ajaxRequestFunc automáticamente con page=1 y el size actual
    this.table?.setPage(1);
  }

  setTodayStartDate() {
    this.inputStartDateTarget.value = this.#todayISO();
  }

  setTodayEndDate() {
    this.inputEndDateTarget.value = this.#todayISO();
  }

  // ── Modal Confirmación ────────────────────────────────────────────────────

  // ── Utilidades ─────────────────────────────────────────────────────────────

  #hasPerm(name) {
    return this.#permissions.includes(name);
  }

  // Habilita el botón "Descarga masiva" (botón-ícono ghost que expande texto en
  // hover; nace deshabilitado/gris con tooltip en su <span> envolvente). Ver §26.
  #enableBulkDownloadButton() {
    const btn = this.btnBulkDownloadTarget;
    btn.disabled = false;
    btn.classList.remove('text-gray-300', 'cursor-not-allowed', 'pointer-events-none');
    btn.classList.add('text-blue-600', 'cursor-pointer', 'hover:bg-blue-50');
    if (this.hasBtnBulkDownloadWrapTarget) this.btnBulkDownloadWrapTarget.removeAttribute('data-tooltip');
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

  #todayISO() {
    const d = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  #formatDate(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  // Formato canónico de fecha+hora (CLAUDE.md §5): `yyyy-MM-dd HH:mm:ss`.
  // `U_CL_FEC_FechaEmision` sí trae hora — el panel de información la mostraba
  // truncada con `.substring(0, 10)`, perdiéndola sin necesidad.
  //
  // ⚠️ NO usar `new Date(dateStr).getHours()` acá: el valor llega con sufijo
  // `Z` (ej. `2026-09-06T09:06:00Z`), y `new Date` lo toma como UTC — `getHours()`
  // (hora LOCAL del navegador) lo convierte a la zona del browser, corriendo la
  // hora 6 horas para atrás en Costa Rica (09:06 → 03:06). Se extraen los
  // dígitos tal cual vienen en el string, sin pasar por conversión de huso
  // horario ninguna.
  #formatDateTime(dateStr) {
    if (!dateStr) return '';
    const match = String(dateStr).match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/);
    if (!match) return '';
    const [, year, month, day, hours, minutes, seconds] = match;
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }

  #openBase64InTab(b64, mimeType) {
    const binary   = atob(b64);
    const len      = binary.length;
    const buf      = new ArrayBuffer(len);
    const view     = new Uint8Array(buf);
    for (let i = 0; i < len; i++) view[i] = binary.charCodeAt(i);
    const blob     = new Blob([view], { type: mimeType });
    const url      = URL.createObjectURL(blob);
    const tab      = window.open();
    if (tab) tab.location.href = url;
  }

  #downloadBase64(b64, fileName, mimeType) {
    const binary   = atob(b64);
    const len      = binary.length;
    const buf      = new ArrayBuffer(len);
    const view     = new Uint8Array(buf);
    for (let i = 0; i < len; i++) view[i] = binary.charCodeAt(i);
    const blob = new Blob([view], { type: mimeType });
    this.#saveBlob(blob, fileName);
  }

  #saveBlob(blob, fileName) {
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = fileName;
    a.click();
    URL.revokeObjectURL(url);
  }

  #b64DecodeUnicode(str) {
    return decodeURIComponent(
      atob(str).split('').map(c => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2)).join('')
    );
  }

  // ── Tooltip para opciones inhabilitadas del dropdown ──────────────────────

  #showDropdownTooltip(event, text) {
    let tip = document.getElementById('cl-dropdown-tooltip');
    if (!tip) {
      tip = document.createElement('div');
      tip.id = 'cl-dropdown-tooltip';
      tip.style.cssText = 'position:fixed;z-index:10000;background:#1f2937;color:#fff;font-size:12px;line-height:1.5;border-radius:8px;padding:8px 12px;max-width:220px;pointer-events:none;box-shadow:0 4px 12px rgba(0,0,0,.25);';
      document.body.appendChild(tip);
    }
    tip.textContent = text;
    tip.style.display = 'block';
    const rect = event.target.getBoundingClientRect();
    tip.style.left = `${rect.right + 8}px`;
    tip.style.top  = `${rect.top + rect.height / 2 - 12}px`;
  }

  #hideDropdownTooltip() {
    const tip = document.getElementById('cl-dropdown-tooltip');
    if (tip) tip.style.display = 'none';
  }

  #formatHaciendaError(text) {
    if (!text) return '';

    const bracketStart = text.indexOf('[');
    const bracketEnd   = text.lastIndexOf(']');

    // Sin estructura de array → card rojo simple
    if (bracketStart === -1) {
      return `
        <div class="rounded-lg border border-red-200 bg-red-50 p-3">
          <p class="text-sm text-red-800 leading-relaxed break-all">${this.#escapeHtml(text)}</p>
        </div>`;
    }

    const preamble     = text.substring(0, bracketStart).trim();
    const arrayContent = text.substring(bracketStart + 1, bracketEnd !== -1 ? bracketEnd : undefined).trim();

    // Parsear entradas: código, ""mensaje"", fila, columna
    const entries = [];
    const regex = /(-?\d+),\s*""([\s\S]*?)"",\s*-?\d+,\s*-?\d+/g;
    let match;
    while ((match = regex.exec(arrayContent)) !== null) {
      entries.push({ code: match[1], message: match[2].trim() });
    }

    let html = '';

    if (preamble) {
      html += `<p class="text-sm text-gray-600 mb-3 leading-relaxed break-all">${this.#escapeHtml(preamble)}</p>`;
    }

    if (entries.length > 0) {
      html += '<div class="space-y-2">';
      for (const e of entries) {
        html += `
          <div class="rounded-lg border border-red-200 bg-red-50 p-3">
            <span class="inline-block text-xs font-semibold text-red-700 bg-red-100 px-2 py-0.5 rounded-full mb-1.5">
              Código ${this.#escapeHtml(e.code)}
            </span>
            <p class="text-sm text-red-800 leading-relaxed break-all">${this.#escapeHtml(e.message)}</p>
          </div>`;
      }
      html += '</div>';
    } else if (arrayContent) {
      html += `
        <div class="rounded-lg border border-red-200 bg-red-50 p-3">
          <p class="text-sm text-red-800 leading-relaxed break-all">${this.#escapeHtml(arrayContent)}</p>
        </div>`;
    }

    return html;
  }

  #escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ── apiFetch (patrón canónico CLAUDE.md) ─────────────────────────────────

  async #apiFetch(url, options = {}) {
    const isFESync = (options.headers?.['API'] ?? 'ApiAppUrl') === 'ApiFEUrl';

    const token = isFESync
      ? (JSON.parse(sessionStorage.getItem('currentFEUser') || '{}')?.access_token ?? null)
      : (Storage.get('Session') || {}).access_token;

    const company   = SStore.get('CurrentCompany');
    const companyId = company?.companyId ?? this.#companyId;

    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type':             'application/json',
        'API':                      'ApiAppUrl',
        'X-Skip-Error-Interceptor': 'true',
        ...(token     ? { Authorization:   `Bearer ${token}` } : {}),
        ...(companyId ? { 'Cl-Company-Id': String(companyId) } : {}),
        ...(options.headers || {}),
      },
    });

    const clMessage = response.headers.get('cl-message');
    const decodedMessage = clMessage ? (() => {
      try { return decodeURIComponent(clMessage); } catch { return clMessage; }
    })() : null;

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText);
      throw new Error(decodedMessage || text || `HTTP ${response.status}`);
    }

    const contentType   = response.headers.get('content-type') || '';
    const contentLength = response.headers.get('content-length');
    if (response.status === 204 || contentLength === '0' || !contentType.includes('json')) return {};

    const text = await response.text();
    if (!text || !text.trim()) return {};
    const json = JSON.parse(text);
    if (decodedMessage && !json.Message) json.Message = decodedMessage;
    return json;
  }
}

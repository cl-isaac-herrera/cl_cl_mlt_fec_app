import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
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
 * `TODOS.md` → Emisión de documentos): Ver/Descargar comprobante, Ver XML
 * respuesta, Omitir Validaciones, Anulación Interna, Descarga Masiva, y el
 * gráfico "Más Información" (dependía de `DocumentQtyList`, que el .NET
 * calculaba y SAP no).
 *
 * "Reprocesar" SÍ está migrado: `PATCH /api/documents/:id/reprocess` reencola
 * el documento en la cola propia (§37, `Documents::PendingQueue#reprocess`),
 * ya no pega al servidor de sincronización .NET (`ApiFEUrl`).
 *
 * Las DOS descargas de XML también: `GET /api/documents/:id/xml_files/sent` y
 * `…/response` (`Api::Documents::XmlFilesController`). El XML no vive en SAP
 * sino en Azure (`Documents::XmlArchive`) y SAP guarda su URL en los UDFs
 * `U_CL_FEC_XmlSentUrl`/`U_CL_FEC_XmlResponseUrl` (la vista del listado los
 * expone como `XmlSentUrl`/`XmlResponseUrl`); el listado las trae para saber
 * si hay algo que bajar, pero la URL que se baja la resuelve el servidor por
 * `DocEntry` — ver `#downloadXmlFile` y `#xmlFileOption`.
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
    'emailModal', 'emailPanelBackdrop', 'emailLoader', 'emailTable', 'emailEmpty', 'emailError',
    'emailDocNumber',
    'otherEmailsForm', 'inputEmailTo', 'errorEmailTo', 'inputEmailCC', 'errorEmailCC', 'btnResend',

    // Panel lateral info
    'infoModal', 'infoPanelBackdrop', 'infoClave', 'copyTooltip', 'infoFechaEmision',
    'infoErrorSection', 'infoError', 'infoErrorChevron',
    'infoErrorHaciendaSection', 'infoErrorHacienda',
    'infoAttemptsBody', 'infoAttemptsChevron',

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

  /**
   * Fila del documento activo en el panel de correos. Se guarda la fila entera
   * y no solo el id porque la consulta necesita también el `DocType`: la UDT
   * identifica el correo con el par `DocEntry` + `DocType`, no con el `docId`
   * de la base local que usaba el `.NET`.
   *
   * `#loadEmails` la compara al terminar: si el usuario ya abrió el panel de
   * otro documento, la respuesta vieja no debe pisar el contenido nuevo.
   */
  #activeEmailRow = null;

  /**
   * DocEntry del documento activo en el panel "Información del documento".
   * `#loadAttempts` lo compara al terminar: si el usuario ya abrió el panel de
   * otro documento, la respuesta vieja no debe pisar el contenido nuevo.
   */
  #activeInfoDocId = null;

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
      Swal.fire({ icon: 'error', title: 'Se produjo un error al obtener los documentos', text: json.Message || 'Error desconocido', confirmButtonText: 'Aceptar' });
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

    Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Documentos obtenidos correctamente!', showConfirmButton: false, timer: 3000, timerProgressBar: true });

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
      // `NumeroConsecutivo`/`Clave`, no `U_CL_FEC_NumConsecutivo`/`U_CL_FEC_Clave`:
      // la vista (`CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery`) también renombra
      // estos dos UDFs al exponerlos, igual que `FEDocumentStatus`/`XmlSentUrl`/
      // `XmlResponseUrl` más abajo — corregido en `db/seeds.rb` (documentaba lo
      // contrario, y por eso la columna "N° FE" y la Clave del panel quedaban vacías).
      NumeroConsecutivo: doc.NumeroConsecutivo,
      Consecutivo: doc.DocNum,
      RcprNombre: doc.CardName,
      Clave: doc.Clave,
      // `ErrorMessage` (la vista renombra el UDF `U_CL_FEC_ErrorDetails`) NO
      // viaja acá a propósito: la sincronización lo pisa constantemente
      // (reprocesos, `CheckSentDocumentsJob`), así que el valor de esta
      // búsqueda puede quedar desactualizado frente al estado ACTUAL del
      // documento. El panel "Información del documento" lo consulta fresco
      // cada vez que se abre (`#loadErrorDetails`, `GET /api/documents/:id`).
      //
      // `FEDocumentStatus`, no `U_CL_FEC_Status`: la vista
      // (`CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery`) renombra ese UDF al
      // exponerlo.
      Status: doc.FEDocumentStatus,
      StatusForTable: this.#statusLabel(doc.FEDocumentStatus),
      FechaFactura: this.#formatDate(doc.DocDate),
      // Sin columna propia en la tabla (se sacó a pedido): sigue viajando
      // cruda para el panel "Consultar Información" (`#openInfoModal`).
      FechaEmision: doc.U_CL_FEC_FechaEmision,
      // Las direcciones en Azure de los XML archivados (`Documents::XmlArchive`).
      // NO se usan para bajar el archivo —eso lo resuelve el servidor por
      // `DocEntry`, ver `Api::Documents::XmlFilesController`— sino para saber si
      // hay algo que bajar antes de ofrecer la opción del dropdown.
      //
      // `XmlSentUrl`/`XmlResponseUrl`, no `U_CL_FEC_XmlSentUrl`/
      // `U_CL_FEC_XmlResponseUrl`: la vista renombra esos dos UDFs al
      // exponerlos.
      //
      // ⚠️ Se copian TAL CUAL, sin `|| ''`: `undefined` (un `$select`
      // personalizado que no pidiera el campo) y `''`/`null` (SAP lo devolvió
      // vacío) son dos cosas distintas — ver `#xmlFileOption`.
      XmlSentUrl: doc.XmlSentUrl,
      XmlResponseUrl: doc.XmlResponseUrl,
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
      0: { label: 'Pendiente',    bg: '#fffbeb', color: '#b45309' },
      3: { label: 'Enviado',      bg: '#e8f0fe', color: '#1a56db' },
      4: { label: 'Error',        bg: '#fdecea', color: '#c0392b' },
      6: { label: 'Aceptado',     bg: '#e8f5ee', color: '#3a7d52' },
      7: { label: 'Rechazado',    bg: '#fef2f2', color: '#991b1b' },
      // Reencolado a pedido del usuario (§37, `Documents::PendingQueue::STATUS_REPROCESS`);
      // vuelve a `Enviado`/`Error`/etc. en cuanto `SyncIssuedDocumentsJob` lo retoma.
      8: { label: 'Reprocesando', bg: '#fff7ed', color: '#c2410c' },
    };
    return map[status] ? { ...map[status], status } : { label: 'N/A', bg: '#f3f4f6', color: '#6b7280', status };
  }

  #statusBadge(val) {
    if (!val || typeof val !== 'object') return '';
    if (val.loading) return this.#queueingBadge();
    return `<span style="background-color:${val.bg}; color:${val.color};"
                  class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      ${val.label}
    </span>`;
  }

  // Badge transitorio de la celda Estado mientras viaja la solicitud de reprocesamiento.
  // Dice "Reencolando" y no "Enviando": lo que la acción hace es devolver el documento a la
  // cola (`Documents::PendingQueue::STATUS_REPROCESS`), y el catálogo ya tiene un estado
  // "Enviado" (3, enviado a Hacienda) con el que "Enviando" se confundía.
  #queueingBadge() {
    return `<span style="background-color:#e8f0fe; color:#1a56db;"
                  class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
      <span class="inline-block h-3 w-3 rounded-full border-2 border-current border-t-transparent animate-spin"></span>
      Reencolando
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

  /**
   * Una opción de descarga de XML, habilitada según haya o no archivo archivado.
   *
   * El estado NO decide esto: lo decide la URL que SAP guardó en el UDF
   * (`U_CL_FEC_XmlSentUrl` / `U_CL_FEC_XmlResponseUrl`, expuestos por la vista
   * del listado como `XmlSentUrl`/`XmlResponseUrl`). Antes se adivinaba por
   * `Status`, que es una correlación y no el dato —un documento Aceptado cuyo
   * archivado falló ofrecía una descarga que no existía, y uno Rechazado sin
   * respuesta archivada también—.
   *
   * ⚠️ `undefined` NO es "no hay": es "no se sabe". Significa que el `$select`
   * de la consulta del catálogo (`getDocuments<tipo>`, personalizable por
   * instalación) no pidió el campo, así que la fila no puede decir nada y la
   * opción queda habilitada — el servidor contesta 404 con el motivo si de
   * verdad no hay nada. Inhabilitarla ahí mostraría un motivo falso.
   *
   * El ícono es `download` en las dos, igual que "Descargar comprobante": lo que
   * la opción hace es bajar un archivo, y el ícono lo dice.
   */
  #xmlFileOption({ label, action, url, disabledReason }) {
    const missing = url === null || url === '';

    return { label, action, icon: 'download', disabled: missing, disabledReason };
  }

  #showRowDropdown(e, row) {
    // Eliminar dropdown previo si existe
    document.getElementById('cl-row-dropdown')?.remove();

    const options = [
      { label: 'Ver comprobante',       icon: 'picture_as_pdf', action: 'view-pdf'     },
      { label: 'Descargar comprobante', icon: 'download',       action: 'download-pdf' },
      {
        // Códigos de `U_CL_FEC_Status`: 6 Aceptado, 7 Rechazado (ver #statusLabel).
        label: 'Ver XML respuesta', icon: 'terminal', action: 'view-xml',
        disabled: row.Status !== 6 && row.Status !== 7,
        disabledReason: 'Solo disponible para documentos en estado Aceptado o Rechazado',
      },
      this.#xmlFileOption({
        label: 'Descargar XML respuesta', action: 'download-xml', url: row.XmlResponseUrl,
        disabledReason: 'El XML de respuesta se archiva cuando Hacienda acepta o rechaza el documento',
      }),
      this.#xmlFileOption({
        label: 'Descargar XML comprobante', action: 'download-doc-xml', url: row.XmlSentUrl,
        disabledReason: 'El XML del comprobante se archiva cuando el documento se firma y se envía a Hacienda',
      }),
      { label: 'Correos',               icon: 'mail',     action: 'emails' },
      { label: 'Ver más detalles',      icon: 'info',     action: 'info'   },
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
      case 'download-xml':     this.#downloadXmlFile(row, 'response'); break;
      case 'download-doc-xml': this.#downloadXmlFile(row, 'sent');     break;
      case 'emails':           this.#openEmailModal(row);      break;
      case 'info':             this.#openInfoModal(row);        break;
      case 'skip-validations': this.#skipValidations(row.Id);  break;
      case 'internal-cancel':  this.#internalCancel(row);      break;
      case 'reprocess':        this.#reprocess(row);           break;
    }
  }

  // ── Acciones de fila ──────────────────────────────────────────────────────

  async #viewPDF(id) {
    try {
      const json = await this.#apiFetch(`/api/Report/PrintInvoicePDF?id=${id}`);
      if (!json.Data) { Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: 'No se pudo obtener el PDF', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return; }
      this.#openBase64InTab(json.Data, 'application/pdf');
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Información cargada con éxito!', showConfirmButton: false, timer: 3000, timerProgressBar: true });
    } catch (err) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message, showConfirmButton: false, timer: 3000, timerProgressBar: true });
    }
  }

  async #downloadPDF(id, numeroConsecutivo) {
    try {
      const json = await this.#apiFetch(`/api/Report/DownloadInvoicePDF?id=${id}`);
      if (!json.Data) { Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: 'No se pudo descargar el PDF', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return; }
      this.#downloadBase64(json.Data, `${numeroConsecutivo}-PDF`, 'application/pdf');
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Proceso de descarga exitoso!', showConfirmButton: false, timer: 3000, timerProgressBar: true });
    } catch (err) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message, showConfirmButton: false, timer: 3000, timerProgressBar: true });
    }
  }

  async #viewXML(id) {
    try {
      const json = await this.#apiFetch(`/api/Documents/PrintDocumentXML?docId=${id}`);
      if (!json.Data?.HrRespuestaXml) { Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: 'No se encontró respuesta XML', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return; }
      this.#openBase64InTab(json.Data.HrRespuestaXml, 'application/xml');
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Información cargada con éxito!', showConfirmButton: false, timer: 3000, timerProgressBar: true });
    } catch (err) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message, showConfirmButton: false, timer: 3000, timerProgressBar: true });
    }
  }

  /**
   * Baja uno de los dos XML archivados del documento — `sent` (el comprobante
   * firmado que se envió) o `response` (lo que devolvió Hacienda).
   *
   * Endpoint nativo (`GET /api/documents/:id/xml_files/:kind`), ya no
   * `GetXMLDoc`/`DownloadDocumentXML` del .NET. Dos diferencias con aquel:
   *
   *   - El cuerpo es el XML, no un JSON con Base64 adentro, así que no se pasa
   *     por `#apiFetch` (que espera JSON) sino por `fetch` a secas — mismo
   *     patrón que la descarga de esquemas XSD en `general_configs_controller`.
   *   - El nombre del archivo lo manda el servidor (`Content-Disposition`), y es
   *     EL MISMO con el que el XML quedó archivado en Azure (`<clave>.xml` /
   *     `<clave>_respuesta.xml`) y con el que viaja adjunto en el correo de
   *     recepción. El `NNN-XMLRESP`/`NNN-XMLDOC` del legacy era una tercera
   *     convención, sin extensión y sin relación con las otras dos.
   */
  async #downloadXmlFile(row, kind) {
    const url = `/api/documents/${row.Id}/xml_files/${kind}` +
                `?doc_type=${encodeURIComponent(row.DocType)}`;

    try {
      const response = await fetch(url, { headers: { Accept: 'application/xml' } });

      if (!response.ok) {
        // El cuerpo del error SÍ es JSON: trae el motivo (`Message`), que para
        // un 404 explica cuándo se archiva el XML que no está.
        const body = await response.json().catch(() => null);
        throw new Error(body?.Message || `HTTP ${response.status}`);
      }

      const fallback = `${row.Clave || row.NumeroConsecutivo || row.Id}` +
                       `${kind === 'response' ? '_respuesta' : ''}.xml`;

      this.#saveBlob(await response.blob(), this.#fileNameFromResponse(response) || fallback);
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Proceso de descarga exitoso!', showConfirmButton: false, timer: 3000, timerProgressBar: true });
    } catch (err) {
      // Lectura fallida → toast (§9).
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message, showConfirmButton: false, timer: 3000, timerProgressBar: true });
    }
  }

  /** El `filename` del `Content-Disposition`, o `null` si el header no vino. */
  #fileNameFromResponse(response) {
    const disposition = response.headers.get('content-disposition') || '';
    // `filename*=UTF-8''…` primero: es el que lleva el nombre sin degradar
    // cuando tiene caracteres fuera de ASCII.
    const encoded = disposition.match(/filename\*=UTF-8''([^;]+)/i);
    if (encoded) { try { return decodeURIComponent(encoded[1]); } catch { /* cae al plano */ } }

    return disposition.match(/filename="?([^";]+)"?/i)?.[1] || null;
  }

  async #skipValidations(docId) {
    const { isConfirmed } = await Swal.fire({
      title: 'Omitir validaciones',
      text: 'Esta acción omitirá las validaciones y enviará el documento a Hacienda con errores bajo su propia responsabilidad. ¿Está seguro que desea continuar?',
      icon: 'warning',
      showCancelButton: true,
      confirmButtonText: 'Confirmar',
      cancelButtonText: 'Cancelar'
    });
    if (!isConfirmed) return;
    try {
      const session = Storage.get('Session') || {};
      await this.#apiFetch('/api/Documents', {
        method: 'PATCH',
        body: JSON.stringify({ docId, feToken: '' }),
      });
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Estado cambiado con éxito', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      this.table?.replaceData();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al omitir validaciones', text: err.message, confirmButtonText: 'Aceptar' });
    }
  }

  async #internalCancel(row) {
    // Códigos de `U_CL_FEC_Status` — ver #statusLabel.
    const statusLabels = {
      0: 'Pendiente', 3: 'Enviado', 4: 'Error', 6: 'Aceptado', 7: 'Rechazado', 8: 'Reprocesando',
    };
    const statusText = statusLabels[row.Status] || 'Desconocido';

    const { isConfirmed } = await Swal.fire({
      title: `Esta acción anulará de manera interna la FEC bajo su propia responsabilidad, la cuál se encuentra en estado: ${statusText}`,
      text: '¿Está seguro que desea continuar?',
      icon: 'warning',
      showCancelButton: true,
      confirmButtonText: 'Confirmar',
      cancelButtonText: 'Cancelar'
    });
    if (!isConfirmed) return;
    try {
      await this.#apiFetch('/api/Documents/SetDocStatusInternalCancelled', {
        method: 'PATCH',
        body: JSON.stringify({ docId: row.Id, feToken: '' }),
      });
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Documento anulado con éxito', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      this.table?.replaceData();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al anular el documento', text: err.message, confirmButtonText: 'Aceptar' });
    }
  }

  async #reprocess(row) {
    if (!this.#hasPerm('Documents_Emission_Reprocess')) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'info', title: 'No tiene permiso para realizar esta acción', showConfirmButton: false, timer: 3000, timerProgressBar: true });
      return;
    }
    const docId = row.Id;
    // Loader a nivel de fila: marca la celda Estado como "Reencolando" durante la solicitud
    const currentPage = this.table?.getPage() || 1;
    const rowComp = this.table?.getRows().find(r => r.getData().Id === docId);
    rowComp?.update({ StatusForTable: { loading: true } });
    try {
      // Endpoint nativo (Rails, sesión propia) — ya no el servidor de sincronización .NET.
      await this.#apiFetch(
        `/api/documents/${docId}/reprocess?doc_type=${encodeURIComponent(row.DocType)}`,
        { method: 'PATCH' }
      );
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Solicitud de reprocesamiento enviada', showConfirmButton: false, timer: 3000, timerProgressBar: true });
    } catch (err) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message, showConfirmButton: false, timer: 3000, timerProgressBar: true });
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

  // Ícono + tooltip para el estado del correo. Los códigos son los `ValidValues`
  // de `U_Status` en la UDT (`config/sap_schemas/outgoing_mails_udt.json`), el
  // mismo catálogo que `Documents::MailQueue::STATUS_*`.
  #emailStatusBadge(code) {
    const map = {
      1: { label: 'Pendiente', icon: 'schedule',     bg: '#f3f4f6', color: '#6b7280' },
      2: { label: 'Enviando',  icon: 'sync',         bg: '#e8f0fe', color: '#1a56db' },
      3: { label: 'Error',     icon: 'error',        bg: '#fdecea', color: '#c0392b' },
      4: { label: 'Enviado',   icon: 'check_circle', bg: '#e8f5ee', color: '#3a7d52' },
      // 5 no existía en el enum del `.NET`: lo agregó la UDT para el documento
      // que no se envía porque la compañía no manda los rechazados por Hacienda
      // (`Documents::MailQueue::STATUS_SKIPPED`).
      5: { label: 'Omitido',   icon: 'block',        bg: '#f5f3ff', color: '#6d28d9' },
    };
    const s = map[Number(code)] ?? { label: String(code ?? ''), icon: 'help', bg: '#f3f4f6', color: '#4b5563' };
    return this.#iconTooltip(s.icon, s.bg, s.color, s.label);
  }

  // El panel se abre de INMEDIATO, con su loader, y la consulta corre después.
  // Este método NO es `async` a propósito: ningún `await` puede colarse entre
  // el click del usuario y la apertura — mismo criterio que `#openInfoModal`.
  #openEmailModal(row) {
    this.#activeEmailRow = row;
    this.otherEmailsFormTarget.classList.add('hidden');
    this.inputEmailToTarget.value = '';
    this.inputEmailCCTarget.value = '';

    this.emailDocNumberTarget.textContent = this.#documentLabel(row);

    this.#openEmailPanel();
    this.#setEmailState('loading');
    this.#loadEmails(row);
  }

  // Cómo se nombra el documento en el encabezado del panel.
  //
  // Los rótulos son los MISMOS que los de las columnas de la tabla ("N° FE" y
  // "N° Ref"), para que se reconozca de dónde salió el número en vez de tener
  // que deducirlo por la forma.
  //
  // El consecutivo de Hacienda (`N° FE`) está vacío hasta que el comprobante se
  // acepta — es el estado normal de un documento en trámite, no un dato
  // faltante (ver `getColumns`). Ahí se cae al número de referencia de SAP
  // (`DocNum`), que existe desde que el documento se creó: un encabezado que
  // dijera "—" no identificaría nada, que es justo lo que se quiere evitar.
  #documentLabel(row) {
    if (row.NumeroConsecutivo) return `N° FE ${row.NumeroConsecutivo}`;
    if (row.Consecutivo)       return `N° Ref ${row.Consecutivo}`;
    return '';
  }

  // Historial de correos del documento, desde la UDT `@CL_FEC_MAILSDETAILS` de
  // SAP (`GET /api/documents/:id/mails`). Reemplaza
  // `GET /api/Email/GetOutgoingMails?docId=N`, que leía la tabla `OutgoingMails`
  // de la base propia del `.NET`: ese detalle ya no se escribe ahí.
  //
  // La llave es el par `DocEntry` + `DocType` —`row.Id` es el `DocEntry`, ver
  // `#mapDocument`—, no el `docId` local que ya no existe en una fila que viene
  // de SAP.
  async #loadEmails(row) {
    try {
      const json = await this.#apiFetch(
        `/api/documents/${row.Id}/mails?doc_type=${encodeURIComponent(row.DocType)}`
      );
      if (this.#activeEmailRow !== row) return; // el usuario ya abrió otro documento

      const mails = json.Data?.Items || [];
      if (!mails.length) { this.#setEmailState('empty'); return; }

      this.#buildEmailTable(mails);
      this.#setEmailState('table');
    } catch (err) {
      if (this.#activeEmailRow !== row) return;

      // Estado propio y no 'empty': decirle "no hay correos" cuando la consulta
      // falló es afirmar algo que no se sabe.
      this.emailErrorTarget.textContent = err.message || 'No se pudieron consultar los correos.';
      this.#setEmailState('error');
      Swal.fire({ toast: true, position: 'top-end', icon: 'error', title: err.message, showConfirmButton: false, timer: 3000, timerProgressBar: true });
    }
  }

  // Alterna entre los cuatro estados visuales del panel de correos
  #setEmailState(state) {
    this.emailLoaderTarget.classList.toggle('hidden', state !== 'loading');
    this.emailTableTarget.classList.toggle('hidden',  state !== 'table');
    this.emailEmptyTarget.classList.toggle('hidden',  state !== 'empty');
    this.emailErrorTarget.classList.toggle('hidden',  state !== 'error');
    this.#updateResendButton();
  }

  // Habilita Reenviar según el contexto:
  //   - Con el form de otros destinatarios ABIERTO: hace falta un "Para" válido
  //     (el CC es opcional, pero si tiene algo tiene que ser válido).
  //   - Con el form CERRADO: alcanza con que haya historial, porque los
  //     destinatarios salen del correo de tipo Envío que el servidor busca solo.
  //
  // "Para" es obligatorio y no "Para o CC": el servidor rechaza un reenvío sin
  // "Para" (`Api::Documents::MailsController#custom_recipients`), así que
  // habilitar el botón con solo un CC ofrecería algo que después falla. El .NET
  // lo resolvía peor — con "Para" vacío ignoraba en silencio el CC escrito y
  // mandaba el correo a los destinatarios originales.
  #updateResendButton() {
    const hasTable        = !this.emailTableTarget.classList.contains('hidden');
    const otherEmailsOpen = !this.otherEmailsFormTarget.classList.contains('hidden');
    const toValue         = this.inputEmailToTarget.value.trim();
    const ccValue         = this.inputEmailCCTarget.value.trim();
    const ccValid         = ccValue.length === 0 || this.#isValidEmailList(ccValue);

    const enabled = otherEmailsOpen
      ? this.#isValidEmail(toValue) && ccValid
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
              ${this.#relativeDateSpan(m.CreatedAt, 'text-sm font-semibold text-gray-800')}
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

  // Registra un reenvío: `POST /api/documents/:id/mails`, que crea la fila de
  // tipo Reenvío en la UDT y la encola. Reemplaza `POST /api/Email/` del .NET
  // (`spResendDocEmail`), que insertaba en la tabla `OutgoingMails` de la base
  // propia.
  //
  // El correo NO sale acá: lo manda `SendElectronicReceiptJob` en su próxima
  // corrida. Por eso el mensaje dice "registrado" y no "enviado" — prometer un
  // envío que todavía no ocurrió es lo que hacía el "Datos listos para el
  // reenvío" del legacy, que además no decía nada útil.
  //
  // Sin "otros destinatarios" el cuerpo va vacío: los destinatarios los resuelve
  // el servidor copiándolos del correo de tipo Envío (1) del documento. Mandar
  // acá los del historial ya cargado sería adivinarle al servidor.
  async resendEmail() {
    const row = this.#activeEmailRow;
    if (!row) return;
    if (!this.#validateEmailFields()) return;

    const otherEmails = !this.otherEmailsFormTarget.classList.contains('hidden');

    try {
      const json = await this.#apiFetch(
        `/api/documents/${row.Id}/mails?doc_type=${encodeURIComponent(row.DocType)}`,
        {
          method: 'POST',
          body: JSON.stringify({
            OtherEmails: otherEmails,
            MailTo:      otherEmails ? this.inputEmailToTarget.value.trim() : '',
            MailCC:      otherEmails ? this.inputEmailCCTarget.value.trim() : '',
          }),
        },
      );
      Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: json.Data?.Message || 'Reenvío registrado.', showConfirmButton: false, timer: 3000, timerProgressBar: true });

      // Los campos se limpian y el formulario se cierra: lo que se pidió ya
      // quedó registrado y aparece como una fila más del historial.
      this.inputEmailToTarget.value = '';
      this.inputEmailCCTarget.value = '';
      this.otherEmailsFormTarget.classList.add('hidden');

      await this.#refreshEmailTable();
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'Error al reenviar correo', text: err.message, confirmButtonText: 'Aceptar' });
    }
  }

  // Vuelve a pedir el historial tras un reenvío. Es la misma consulta de la
  // apertura, así que reusa `#loadEmails`: la única diferencia es que el panel
  // ya estaba abierto.
  async #refreshEmailTable() {
    if (!this.#activeEmailRow) return;

    this.#setEmailState('loading');
    await this.#loadEmails(this.#activeEmailRow);
  }

  // ── Panel lateral Información ─────────────────────────────────────────────

  // El panel se muestra de INMEDIATO, con lo que ya trae la fila (Clave y
  // Fecha de Emisión), y cada sección que depende de una consulta se pinta
  // sola cuando su respuesta llega. Este método NO es `async` a propósito:
  // ningún `await` puede colarse entre la acción del usuario y la apertura.
  //
  // Son tres consultas independientes — Detalles, Respuesta Hacienda y
  // Detalles de intentos — y cada una tiene su propio loader dentro de su
  // sección: la más lenta no retrasa a las otras dos.
  #openInfoModal(row) {
    this.#activeInfoDocId = row.Id;

    this.infoClaveTarget.textContent = row.Clave || '';
    this.#paintFechaEmision(row);

    this.infoPanelBackdropTarget.classList.remove('hidden');
    this.infoModalTarget.classList.remove('translate-x-full');
    document.body.style.overflow = 'hidden';

    // "Detalles" (antes "Error interno") — expandida por defecto en cada
    // apertura (§ ver #toggleErrorSection); el usuario puede colapsarla, pero
    // cada documento nuevo arranca igual.
    this.infoErrorTarget.classList.remove('hidden');
    this.infoErrorChevronTarget.textContent = 'expand_less';
    this.#loadErrorDetails(row);

    // "Detalles de intentos" — colapsada por defecto.
    this.infoAttemptsBodyTarget.classList.add('hidden');
    this.infoAttemptsChevronTarget.textContent = 'expand_more';
    this.#loadAttempts(row);

    this.#loadHaciendaResponse(row);
  }

  // `U_CL_FEC_FechaEmision` la estampa la sincronización recién cuando el
  // comprobante sale hacia Hacienda, así que viene vacía en todo documento que
  // todavía no llegó a ese punto (Pendiente, Error, Reprocesando). Un campo en
  // blanco ahí se lee como un dato que se perdió; el hint dice que la fecha
  // todavía no existe porque el documento no se ha emitido.
  //
  // Si el estado SÍ es uno de los emitidos (3 Enviado, 6 Aceptado,
  // 7 Rechazado — ver #statusLabel) y aun así no hay fecha, el campo queda en
  // blanco: ahí el hint mentiría, porque el documento sí se emitió.
  #paintFechaEmision(row) {
    const fecha    = this.#formatDateTime(row.FechaEmision);
    const emitido  = [3, 6, 7].includes(row.Status);
    const mostrarHint = !fecha && !emitido;

    this.infoFechaEmisionTarget.textContent = mostrarHint
      ? '— El documento aún no se ha emitido ante Hacienda —'
      : fecha;

    this.infoFechaEmisionTarget.classList.toggle('italic',        mostrarHint);
    this.infoFechaEmisionTarget.classList.toggle('text-gray-400', mostrarHint);
    this.infoFechaEmisionTarget.classList.toggle('text-gray-800', !mostrarHint);
  }

  // "Detalles" (antes "Error interno"). Consulta `GET /api/documents/:id`
  // cada vez que se abre el panel en vez de usar el `U_CL_FEC_ErrorDetails`
  // que trajo la búsqueda (ya no viaja en `#mapDocument`, ver el comentario
  // ahí): ese campo lo pisa constantemente la sincronización (reprocesos,
  // `CheckSentDocumentsJob`), así que el valor de la última página del listado
  // puede estar desactualizado frente al estado ACTUAL del documento — pasaba
  // que el panel seguía mostrando el detalle de un intento anterior distinto
  // al estado vigente.
  //
  // El color acompaña el estado FRESCO que trae la misma respuesta: rojo para
  // cualquier estado distinto de Aceptado (6), amarillo suave cuando el
  // documento SÍ quedó aceptado (una observación de Hacienda, no un error).
  // La sección se muestra DESDE YA con su loader: si quedara oculta hasta que
  // responda, el usuario no tendría cómo saber que falta algo por llegar. Solo
  // se oculta al final, cuando ya se sabe que no hay detalle que mostrar.
  async #loadErrorDetails(row) {
    this.infoErrorSectionTarget.classList.remove('hidden');
    this.infoErrorTarget.innerHTML = this.#sectionLoaderHtml('Cargando detalles...');

    try {
      const json = await this.#apiFetch(`/api/documents/${row.Id}?doc_type=${encodeURIComponent(row.DocType)}`);
      if (this.#activeInfoDocId !== row.Id) return; // el usuario ya abrió otro documento

      const details = json.Data?.ErrorDetails;
      if (!details) { this.#hideErrorSection(); return; }

      const tone = json.Data?.Status === 6 ? 'amber' : 'red'; // 6 = Aceptado, ver #statusLabel
      this.infoErrorTarget.innerHTML = this.#formatHaciendaError(details, tone);
    } catch {
      if (this.#activeInfoDocId !== row.Id) return;
      this.#hideErrorSection(); // No bloquear el panel por esto
    }
  }

  #hideErrorSection() {
    this.infoErrorSectionTarget.classList.add('hidden');
    this.infoErrorTarget.innerHTML = '';
  }

  // "Respuesta Hacienda" — solo existe para los documentos rechazados, y por
  // eso antes se consultaba con `await` ANTES de abrir el panel: era la causa
  // de que el panel tardara en aparecer justo en los documentos que más se
  // consultan. Ahora corre como las demás, con su loader en la sección.
  async #loadHaciendaResponse(row) {
    this.#hideHaciendaSection();
    if (row.Status !== 7) return; // Rechazado (`U_CL_FEC_Status`) — ver #statusLabel

    this.infoErrorHaciendaSectionTarget.classList.remove('hidden');
    this.infoErrorHaciendaTarget.innerHTML = this.#sectionLoaderHtml('Cargando respuesta de Hacienda...');

    try {
      const json = await this.#apiFetch(`/api/Documents/issued/${row.Id}/xml-response-message`);
      if (this.#activeInfoDocId !== row.Id) return; // el usuario ya abrió otro documento

      if (!json.Data?.HrRespuestaXml) { this.#hideHaciendaSection(); return; }

      this.infoErrorHaciendaTarget.innerHTML = this.#formatHaciendaError(json.Data.HrRespuestaXml);
    } catch {
      if (this.#activeInfoDocId !== row.Id) return;
      this.#hideHaciendaSection(); // No bloquear el panel por esto
    }
  }

  #hideHaciendaSection() {
    this.infoErrorHaciendaSectionTarget.classList.add('hidden');
    this.infoErrorHaciendaTarget.innerHTML = '';
  }

  toggleErrorSection() {
    const collapsed = this.infoErrorTarget.classList.toggle('hidden');
    this.infoErrorChevronTarget.textContent = collapsed ? 'expand_more' : 'expand_less';
  }

  toggleAttemptsSection() {
    const collapsed = this.infoAttemptsBodyTarget.classList.toggle('hidden');
    this.infoAttemptsChevronTarget.textContent = collapsed ? 'expand_more' : 'expand_less';
  }

  // Expandir/colapsar el detalle de UNA tarjeta de intento (ver #renderAttempts).
  // El botón es siempre el hermano siguiente del <p> que recorta: no hace
  // falta buscar por id porque las tarjetas se arman todas del mismo molde.
  toggleAttemptDetail(event) {
    const button = event.currentTarget;
    const paragraph = button.previousElementSibling;
    const collapsed = paragraph.classList.toggle('line-clamp-3');
    button.textContent = collapsed ? 'Ver más' : 'Ver menos';
  }

  // Consulta el historial de intentos de la cola propia (§37) en segundo
  // plano. La sección arranca colapsada; el loader queda escrito en el body
  // desde ya, así que si el usuario la expande antes de que esto responda, lo
  // único que hay que mostrar es ese loader — no hace falta coordinar con
  // #toggleAttemptsSection.
  async #loadAttempts(row) {
    this.infoAttemptsBodyTarget.innerHTML = this.#sectionLoaderHtml('Cargando intentos...');

    try {
      const json = await this.#apiFetch(`/api/documents/${row.Id}/attempts?doc_type=${encodeURIComponent(row.DocType)}`);
      if (this.#activeInfoDocId !== row.Id) return; // el usuario ya abrió otro documento

      const items = json.Data?.Items || [];
      this.infoAttemptsBodyTarget.innerHTML = items.length
        ? this.#renderAttempts(items)
        : '<p class="text-sm text-gray-400 text-center py-6">No hay intentos registrados</p>';
    } catch (err) {
      if (this.#activeInfoDocId !== row.Id) return;

      this.infoAttemptsBodyTarget.innerHTML =
        `<p class="text-sm text-red-600 text-center py-6">${this.#escapeHtml(err.message || 'No se pudo consultar el historial de intentos.')}</p>`;
    }
  }

  // Loader de UNA sección del panel. Las tres secciones que dependen de una
  // consulta comparten este molde: el panel ya está abierto y cada sección
  // avisa por su cuenta que todavía está cargando.
  #sectionLoaderHtml(label) {
    return `
      <div class="flex items-center justify-center gap-2 py-6 text-sm text-gray-500">
        <svg class="animate-spin h-4 w-4 text-blue-500" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z"></path>
        </svg>
        ${label}
      </div>`;
  }

  // Una tarjeta por intento: fecha relativa arriba a la izquierda, estado como
  // badge arriba a la derecha, y el detalle como cuerpo. El detalle se recorta
  // a 3 líneas cuando es largo — un error con traza completa deformaba la
  // tarjeta y arrastraba a las demás — con un "Ver más" para expandirlo.
  #renderAttempts(items) {
    return items.map((a) => {
      const details = a.Details || 'Sin detalle';
      const isLong = details.length > 160 || details.split('\n').length > 3;

      return `
        <div class="border border-gray-200 rounded-lg p-3">
          <div class="flex items-start justify-between gap-2 mb-1.5">
            ${this.#relativeDateSpan(a.CreatedAt, 'text-xs text-gray-500')}
            ${this.#statusBadge(this.#attemptStatusLabel(a.StatusCode))}
          </div>
          <p class="text-sm text-gray-700 whitespace-pre-wrap break-words${isLong ? ' line-clamp-3' : ''}">${this.#escapeHtml(details)}</p>
          ${isLong ? `
            <button type="button"
                    data-action="click->documents-issued#toggleAttemptDetail"
                    class="mt-1 text-xs font-medium text-blue-600 hover:text-blue-700 cursor-pointer">
              Ver más
            </button>` : ''}
        </div>
      `;
    }).join('');
  }

  // Códigos de `dbo.StatusCodes` (base de la cola, `db/external/sql_server/schema.sql`)
  // — catálogo distinto del `U_CL_FEC_Status` de `#statusLabel`: acá SÍ existe
  // el estado intermedio "Procesando" (2).
  #attemptStatusLabel(code) {
    const map = {
      0: { label: 'Pendiente',    bg: '#fffbeb', color: '#b45309' },
      2: { label: 'Procesando',   bg: '#f5f3ff', color: '#6d28d9' },
      3: { label: 'Enviado',      bg: '#e8f0fe', color: '#1a56db' },
      4: { label: 'Error',        bg: '#fdecea', color: '#c0392b' },
      6: { label: 'Aceptado',     bg: '#e8f5ee', color: '#3a7d52' },
      7: { label: 'Rechazado',    bg: '#fef2f2', color: '#991b1b' },
      8: { label: 'Reprocesando', bg: '#fff7ed', color: '#c2410c' },
    };
    return map[code] || { label: 'N/A', bg: '#f3f4f6', color: '#6b7280' };
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
      Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'No hay datos para mostrar', showConfirmButton: false, timer: 3000, timerProgressBar: true });
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
    const { isConfirmed } = await Swal.fire({
      title: 'Descarga masiva de documentos',
      text: 'Se creará una solicitud de descarga masiva según los filtros aplicados. Los archivos serán enviados al correo del usuario que ejecuta la acción.',
      icon: 'info',
      showCancelButton: true,
      confirmButtonText: 'Confirmar',
      cancelButtonText: 'Cancelar'
    });
    if (!isConfirmed) return;
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
          Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Solicitud creada con éxito!!!', showConfirmButton: false, timer: 3000, timerProgressBar: true });
        } catch (err) {
          Swal.fire({ icon: 'error', title: 'Error al crear solicitud de descarga masiva', text: err.message, confirmButtonText: 'Aceptar' });
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

  // `tone` decide la paleta de las tarjetas: 'red' (default, rechazo/error) o
  // 'amber' — un amarillo suave para cuando el documento SÍ quedó Aceptado y
  // lo que Hacienda mandó en el mismo campo es una observación, no un motivo
  // de rechazo (ver #loadErrorDetails). La sección "Respuesta Hacienda" sigue
  // llamando esto sin `tone`: ahí siempre es un rechazo, nunca amarillo.
  #formatHaciendaError(text, tone = 'red') {
    if (!text) return '';

    const palette = tone === 'amber'
      ? { border: 'border-amber-200', bg: 'bg-amber-50', text: 'text-amber-800',
          badgeBg: 'bg-amber-100', badgeText: 'text-amber-700' }
      : { border: 'border-red-200', bg: 'bg-red-50', text: 'text-red-800',
          badgeBg: 'bg-red-100', badgeText: 'text-red-700' };

    // Parsear las entradas de Hacienda: `código, ""mensaje"", fila, columna`.
    //
    // ⚠️ El disparador es QUE HAYA ENTRADAS, no que el texto traiga corchetes.
    // Hacienda envuelve la lista en `[ … ]` cuando RECHAZA ("...tiene los
    // siguientes errores: [ … ]"), pero cuando ACEPTA con observaciones manda
    // las mismas entradas sueltas, sin corchetes. Buscar `[` primero y salir
    // por el card simple si no estaba dejaba todas las observaciones de un
    // documento aceptado apiladas en un solo bloque —incluido el encabezado de
    // columnas— aunque fueran dos o tres observaciones distintas.
    const entries = [];
    const regex = /(-?\d+),\s*""([\s\S]*?)"",\s*-?\d+,\s*-?\d+/g;
    let match;
    let firstEntryIndex = -1;
    while ((match = regex.exec(text)) !== null) {
      if (firstEntryIndex === -1) firstEntryIndex = match.index;
      entries.push({ code: match[1], message: match[2].trim() });
    }

    // Sin entradas reconocibles → card simple con el texto tal cual
    if (entries.length === 0) {
      return `
        <div class="rounded-lg border ${palette.border} ${palette.bg} p-3">
          <p class="text-sm ${palette.text} leading-relaxed break-all">${this.#escapeHtml(text)}</p>
        </div>`;
    }

    // Todo lo anterior a la primera entrada es el mensaje general de Hacienda
    // ("Este comprobante fue recibido en el ambiente de pruebas…"). Se le
    // quitan el encabezado de columnas y el corchete de apertura, que son
    // andamiaje del formato y no información para el usuario.
    const preamble = text.slice(0, firstEntryIndex)
      .replace(/codigo\s*,\s*mensaje\s*,\s*fila\s*,\s*columna/i, '')
      .replace(/\[/g, '')
      .trim();

    let html = '';

    if (preamble) {
      html += `<p class="text-sm text-gray-600 mb-3 leading-relaxed break-all">${this.#escapeHtml(preamble)}</p>`;
    }

    html += '<div class="space-y-2">';
    for (const e of entries) {
      html += `
        <div class="rounded-lg border ${palette.border} ${palette.bg} p-3">
          <span class="inline-block text-xs font-semibold ${palette.badgeText} ${palette.badgeBg} px-2 py-0.5 rounded-full mb-1.5">
            Código ${this.#escapeHtml(e.code)}
          </span>
          <p class="text-sm ${palette.text} leading-relaxed break-all">${this.#escapeHtml(e.message)}</p>
        </div>`;
    }
    html += '</div>';

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

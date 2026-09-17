import TabulatorController from 'vendor/clavisco/tabulator/controllers/tabulator_controller';
import { Storage, SStore } from 'vendor/clavisco/core';
import Swal from 'sweetalert2';
import { showLoading, hideLoading } from 'vendor/clavisco/overlay';
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale';

/**
 * UdfsController — Campos definidos por usuario (UDFs).
 *
 * Replica el componente Angular UdfsComponent (configuration/udfs):
 *   - Carga inicial (forkJoin en Angular → Promise.all aquí):
 *       GET /api/Udf/GetUdfs?searchUdfsForHeader=true
 *       GET /api/Udf/GetConfiguredUdfs?companyId={id}&Category=true
 *     Se hace merge: la lista base de UDFs recibe el estado configurado de
 *     la compañía (IsActive, IsRequired, IsRendered, IsTypehead, DataSource,
 *     TargetToOverride, PostTransactionObject) y el IsActive de cada valor
 *     disponible (MappedValues).
 *   - Tabla Tabulator editable:
 *       #, Nombre, Descripción, Tipo, Obligatorio, Activo, Valores Disponibles
 *     Obligatorio/Activo son toggles con interdependencia (Visible = Activo).
 *     Valores Disponibles es un multiselect (solo para UDFs con MappedValues).
 *   - Botón Guardar → POST /api/Udf/SaveUdfs con { udfs, companyID, TableId: 'OPCH' }.
 *
 * Tipo de dato (FieldType → etiqueta), equivalente al pipe udfMetadataType:
 *   String→Texto, Int32→Numérico, Double→Decimal, DateTime→Fecha.
 *
 * Las definiciones de cabecera usan TableId 'OPCH' (searchUdfsForHeader = true).
 */
export default class extends TabulatorController {
  static targets = [...TabulatorController.targets];
  static values  = { ...TabulatorController.values };

  // ── Estado ────────────────────────────────────────────────────────────────

  #companyId = null;
  #searchUdfsForHeader = true;   // pestaña "Definiciones de cabecera"

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  connect() {
    const company   = SStore.get('CurrentCompany');
    this.#companyId  = company?.companyId ? parseInt(company.companyId) : null;

    super.connect();   // construye la tabla y dispara la carga vía ajaxRequestFunc
  }

  // ── Configuración Tabulator ────────────────────────────────────────────────

  getTableConfig() {
    return {
      ...super.getTableConfig(),
      data: undefined,   // evita que el [] heredado suprima la carga vía ajaxRequestFunc
      height:    '100%',
      maxHeight: undefined,
      layout: 'fitColumns',
      placeholder: 'No hay campos definidos por usuario',
      pagination: true,
      paginationSize: 10,
      paginationSizeSelector: [5, 10, 15],
      paginationCounter: 'rows',
      locale: TABULATOR_LOCALE,
      langs:  TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      columnDefaults: { headerSort: false },
      columns: this.getColumns(),
      // Carga vía el data-loader de Tabulator (igual que companies): dataLoaderLoading
      // muestra el spinner a nivel de tabla durante el fetch. Sin paginationMode:'remote'
      // => paginacion local sobre el dataset completo.
      ajaxURL: '/api/Udf/GetUdfs',
      ajaxRequestFunc: () => this.#loadData(),
      ajaxResponse:    (_url, _params, response) => response,
    };
  }

  // ── Columnas ──────────────────────────────────────────────────────────────

  getColumns() {
    const checkbox = (field, title) => ({
      title,
      field,
      hozAlign: 'center',
      headerHozAlign: 'center',
      width: 110,
      formatter: (cell) => this.#boolBadge(cell.getValue()),
      cellClick: (_e, cell) => this.#toggleFlag(cell, field),
    });

    return [
      { title: '#',           field: 'RegisterNumber', width: 60, hozAlign: 'center' },
      { title: 'Nombre',      field: 'Name',           minWidth: 140, widthGrow: 2 },
      { title: 'Descripción', field: 'Description',    minWidth: 160, widthGrow: 3 },
      { title: 'Tipo',        field: 'FieldTypeClm',   width: 110 },
      checkbox('IsRequired', 'Obligatorio'),
      checkbox('IsActive',   'Activo'),
      {
        title: 'Valores Disponibles',
        field: 'ValuesList',
        minWidth: 180,
        widthGrow: 3,
        editor: 'list',
        editorParams: (cell) => ({
          multiselect: true,
          values: (cell.getRow().getData().MappedValues || [])
            .map((v) => ({ label: v.Description, value: v.Value })),
        }),
        editable: (cell) => (cell.getRow().getData().MappedValues || []).length > 0,
        formatter: (cell) => {
          const row = cell.getRow().getData();
          const available = Array.isArray(row.MappedValues) ? row.MappedValues : [];
          const list = Array.isArray(cell.getValue()) ? cell.getValue() : [];

          // Sin valores disponibles para este campo → no editable
          if (!available.length) return '<span class="text-gray-400 text-xs">—</span>';

          // Hay valores disponibles pero ninguno seleccionado → invitar a seleccionar
          if (!list.length) {
            const label = available.length === 1 ? 'valor disponible' : 'valores disponibles';
            return `<span class="inline-flex items-center gap-0.5 text-xs text-blue-600 border border-dashed border-blue-300 rounded-full px-2 py-0.5 cursor-pointer">
              <span class="material-icons" style="font-size:14px; line-height:1;">add</span>${available.length} ${label}
            </span>`;
          }

          // Con selección → chips sólidos
          const labels = list.map((val) =>
            available.find((v) => String(v.Value) === String(val))?.Description ?? val
          );
          return labels
            .map((l) => `<span class="inline-block bg-blue-50 text-blue-700 rounded-full px-2 py-0.5 text-xs mr-1 mb-0.5">${l}</span>`)
            .join('');
        },
      },
    ];
  }

  // ── Toggle de checkboxes con interdependencia ──────────────────────────────
  //
  // Reglas:
  //   - Visible (IsRendered) siempre es igual a Activo (IsActive).
  //   - Al desactivar, Obligatorio queda en false.
  //   - Obligatorio implica Activo (y, por tanto, Visible).

  #toggleFlag(cell, field) {
    const row  = cell.getRow();
    const data = row.getData();
    let { IsActive: act, IsRequired: req } = data;

    switch (field) {
      case 'IsActive':
        act = !act;
        if (!act) req = false;   // inactivo ⇒ no obligatorio
        break;
      case 'IsRequired':
        req = !req;
        if (req) act = true;     // obligatorio ⇒ activo
        break;
    }

    // Visible siempre sigue a Activo
    row.update({ IsActive: act, IsRendered: act, IsRequired: req });
  }

  /** Indicador booleano estilo mail-parser: círculo azul (sí) / círculo gris (no). */
  #boolBadge(value) {
    return value
      ? `<span class="material-icons text-base" style="color:#1a56db;">check_circle_outline</span>`
      : `<span class="material-icons text-base" style="color:#9ca3af;">radio_button_unchecked</span>`;
  }

  // ── Carga de datos ─────────────────────────────────────────────────────────

  // Retorna el array de filas merge-eado. Lo invoca ajaxRequestFunc, de modo que
  // Tabulator muestra dataLoaderLoading (spinner a nivel de tabla) durante el fetch.
  async #loadData() {
    try {
      const [udfsRes, configuredRes] = await Promise.all([
        this.#apiFetch(`/api/Udf/GetUdfs?searchUdfsForHeader=${this.#searchUdfsForHeader}`),
        this.#apiFetch(`/api/Udf/GetConfiguredUdfs?companyId=${this.#companyId}&Category=${this.#searchUdfsForHeader}`),
      ]);

      const collection = this.#mergeUdfs(udfsRes?.Data ?? [], configuredRes?.Data ?? []);
      const rows = collection.map((udf, index) => ({
        ...udf,
        RegisterNumber: index + 1,
        FieldTypeClm:   this.#typeLabel(udf.FieldType),
        IsRendered:     !!udf.IsActive,   // Visible siempre = Activo
        ValuesList:     (udf.MappedValues ?? []).filter((v) => v.IsActive).map((v) => v.Value),
      }));

      if (udfsRes?.Message && !udfsRes?.Data?.length) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'warning',
          title: udfsRes.Message,
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        });
      }
      return rows;
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: err.message || 'Error al cargar los campos definidos por usuario.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      return [];
    }
  }

  /** Merge de la lista base con el estado configurado de la compañía. */
  #mergeUdfs(baseUdfs, configuredUdfs) {
    const collection = baseUdfs.map((u) => ({
      ...u,
      MappedValues: u.Values ? this.#parseValues(u.Values) : [],
    }));

    configuredUdfs.forEach((cfg) => {
      const local = collection.find((u) => u.Name === cfg.Name);
      if (!local) return;

      local.IsActive             = cfg.IsActive;
      local.IsRequired           = cfg.IsRequired;
      local.IsRendered           = cfg.IsRendered;
      local.IsTypehead           = cfg.IsTypehead;
      local.DataSource           = cfg.DataSource;
      local.PostTransactionObject = cfg.PostTransactionObject;
      local.TargetToOverride     = cfg.TargetToOverride;

      const cfgValues = cfg.Values ? this.#parseValues(cfg.Values) : [];
      if (cfgValues.length && !cfg.DataSource) {
        cfgValues.forEach((cv) => {
          const localVal = local.MappedValues.find((v) => String(v.Value) === String(cv.Value));
          if (localVal) localVal.IsActive = cv.IsActive;
        });
      }
    });

    return collection;
  }

  #parseValues(raw) {
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  #typeLabel(fieldType) {
    return ({
      String:   'Texto',
      Int32:    'Numérico',
      Double:   'Decimal',
      DateTime: 'Fecha',
    })[fieldType] ?? 'No definido';
  }

  // ── Guardar ───────────────────────────────────────────────────────────────

  async save() {
    const rows = this.table?.getData() ?? [];
    const selected = rows.filter((r) => r.IsActive);

    const udfs = selected.map((r) => {
      const valuesList = Array.isArray(r.ValuesList) ? r.ValuesList : [];
      const values = valuesList.length
        ? JSON.stringify(
            (r.MappedValues ?? [])
              .filter((v) => valuesList.some((sel) => String(sel) === String(v.Value)))
              .map((v) => ({ ...v, IsActive: true }))
          )
        : r.Values;

      return {
        Name:                  r.Name,
        Description:           r.Description,
        FieldType:             r.FieldType,
        Values:                values,
        DataSource:            r.DataSource,
        TargetToOverride:      r.TargetToOverride,
        PostTransactionObject: r.PostTransactionObject,
        IsTypehead:            r.IsTypehead,
        IsActive:              r.IsActive,
        IsRequired:            r.IsRequired,
        IsRendered:            r.IsRendered,
      };
    });

    const payload = {
      udfs,
      companyID: this.#companyId,
      TableId:   this.#searchUdfsForHeader ? 'OPCH' : 'PHC1',
    };

    showLoading('Guardando...');
    try {
      await this.#apiFetch('/api/Udf/SaveUdfs', {
        method: 'POST',
        body:   JSON.stringify(payload),
      });
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'success',
        title: 'Campos actualizados exitosamente.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      });
      this.table?.setData();   // recarga via ajaxRequestFunc (loader a nivel de tabla)
    } catch (err) {
      await Swal.fire({
        icon: 'error',
        title: 'Error al guardar los campos definidos por usuario',
        text: err.message,
        confirmButtonText: 'Aceptar'
      });
    } finally {
      hideLoading();
    }
  }

  // ── apiFetch ──────────────────────────────────────────────────────────────

  async #apiFetch(url, options = {}) {
    const session = Storage.get('Session') || {};
    const token   = session.access_token;

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

    const hasBody = response.status !== 204 &&
                    response.headers.get('content-length') !== '0' &&
                    response.headers.get('content-type')?.includes('application/json');
    if (!hasBody) return { Message: decodedMessage || null };

    const json = await response.json();
    if (decodedMessage && !json.Message) json.Message = decodedMessage;
    return json;
  }
}

import { Controller } from '@hotwired/stimulus'
import { TabulatorFull as Tabulator } from 'tabulator-tables'
import { Storage, SStore } from 'vendor/clavisco/core'
import { showToast, showAlert, ALERT_TYPES, confirm } from 'vendor/clavisco/alerts'
import { showLoading, hideLoading } from 'vendor/clavisco/overlay'
import { TABULATOR_LOCALE, TABULATOR_LANGS } from 'controllers/tabulator_locale'

// ── Constantes de dominio ──────────────────────────────────
const RETURN_URL = '/documents/receptions'

// CondicionImpuesto que habilitan TaxFactor
const TAX_FACTOR_CONDITIONS = new Set(['03', '05'])

// Mensajes que requieren DetalleMensaje
const DETAIL_REQUIRED_MESSAGES = new Set(['2', '3'])

// Longitud del DetalleMensaje: máximo 160; mínimo 5 solo si se ingresa texto
const DETAIL_MIN_LENGTH = 5
const DETAIL_MAX_LENGTH = 160

// DocTypes.Factura
const DOC_TYPE_FACTURA = 1

// Debounce (ms) para el autocomplete de documento base
const AUTOCOMPLETE_DEBOUNCE = 260

export default class extends Controller {
  static values = { docId: Number }

  static targets = [
    // Acordeón recepción
    'receptAccordion', 'receptAccordionBody', 'receptAccordionIcon',
    'receptMensaje', 'receptCondicionImpuesto', 'receptTaxFactor', 'receptCodigoActividad', 'receptDetalleMensaje',
    'errorReceptMensaje', 'errorReceptTaxFactor', 'errorReceptCodigoActividad', 'errorReceptDetalleMensaje', 'counterReceptDetalleMensaje',
    // Tabs
    'tabsContainer',
    'tabBtnCabecera', 'tabBtnLineas', 'tabBtnOtrosCargos',
    'tabCabecera', 'tabLineas', 'tabOtrosCargos',
    // Cabecera
    'selectRefDocType', 'inputRefDocEntry', 'refDocAutocompleteList', 'loadingRefDoc',
    'checkCloseRefDoc',
    'inputCardCode', 'supplierAutocompleteList', 'errorCardCode',
    'inputDocDate', 'inputCardName', 'inputDocDueDate', 'inputNumAtCard',
    'inputTaxDate', 'inputDocCur', 'inputComments', 'commentsCharCount',
    'udfsContainer',
    'apInvoiceLinesTable',
    'totalsSubtotal', 'totalsOtrosCargos', 'totalsImpuestos', 'totalsDescuento', 'totalsTotal',
    'btnCreateDraft', 'btnCreateSap',
    // Líneas
    'xmlLinesTable', 'sapLinesTable',
    // Otros Cargos
    'otrosCargosTable',
    // Loading overlay
    'loadingOverlay', 'loadingMessage',
    // Modales
    'currencyMismatchModal', 'currencyMismatchXmlCode', 'currencyMismatchSelect', 'currencyMismatchSave',
    'toleranceModal', 'toleranceDocCurrency', 'toleranceSelect',
    'confirmRefreshModal',
    'successModal', 'successModalMessage',
    // Preview panel
    'previewBackdrop', 'previewPanel', 'previewBody',
    // Item selection panel
    'itemPanelBackdrop', 'itemPanel', 'itemPanelLineInfo',
    'itemInputItem', 'itemSelectItem', 'itemItemList',
    'itemInputWarehouse', 'itemSelectWarehouse', 'itemWarehouseList',
    'itemQuantity', 'itemQuantityRow',
    'itemInputAccount', 'itemSelectAccount', 'itemAccountList',
    'itemInputProject', 'itemSelectProject', 'itemProjectList',
    'itemDimIcon', 'itemDimBody',
    'itemDimRow1', 'itemDimRow2', 'itemDimRow3', 'itemDimRow4', 'itemDimRow5',
    'itemDim1', 'itemDim2', 'itemDim3', 'itemDim4', 'itemDim5',
    // Otros Cargos panel
    'ocPanelBackdrop', 'ocPanel', 'ocPanelLineInfo',
    'ocQuantityRow', 'ocQuantity',
    'ocItemRow', 'ocInputItem', 'ocSelectItem', 'ocItemList',
    'ocWarehouseRow', 'ocInputWarehouse', 'ocSelectWarehouse', 'ocWarehouseList',
    'ocInputTaxCode', 'ocSelectTaxCode', 'ocTaxCodeList',
    'ocInputAccount', 'ocSelectAccount', 'ocAccountList',
    'ocInputProject', 'ocSelectProject', 'ocProjectList',
    'ocFreightRow', 'ocSelectFreight',   // modo 2: cargo adicional SAP
    'ocMode1Fields', 'ocMode2Fields',     // wrappers visibles según modo
    'ocDimIcon', 'ocDimBody',
    'ocDimRow1', 'ocDimRow2', 'ocDimRow3', 'ocDimRow4', 'ocDimRow5',
    'ocDim1', 'ocDim2', 'ocDim3', 'ocDim4', 'ocDim5',
    // Otros Cargos result tables
    'ocApLinesSection', 'ocApLinesTable',
    'ocChargesSection', 'ocChargesTable',
    // Panel edición de dimensiones post-agregado
    'dimEditBackdrop', 'dimEditPanel', 'dimEditLineInfo',
    'dimEditRow1', 'dimEditRow2', 'dimEditRow3', 'dimEditRow4', 'dimEditRow5',
    'dimEdit1', 'dimEdit2', 'dimEdit3', 'dimEdit4', 'dimEdit5',
  ]

  // ── Estado interno ─────────────────────────────────────
  #docId            = null
  #companyId        = null
  #session          = null
  #shouldRecept     = false

  // Datos de catálogos
  #activityCodes    = []
  #accountList      = []
  #taxCodeList      = []
  #itemSAPList      = []
  #warehouseList    = []
  #projectList      = []
  #supplierList     = []
  #docTypeList      = []
  #companyCurrencies= []
  #xmlToleranceAmounts = []
  #defaultTaxForXML = ''
  #dynamicUdfs      = []
  #sendReceptAndApInv = false
  #freightChargesMode = 1   // 1 = Artículos (tabla APInvoiceLines), 2 = Otros Cargos (tabla DocumentAdditionalExpenses)
  #dimensionList      = []  // IDimensions[] — solo las dimensiones configuradas en SAP
  #freightList        = []  // FreightModel[] — cargos adicionales para modo 2
  #dimEditContext     = null // { type: 'sap'|'other', id } — contexto del panel de edición de dims
  #useMatchAuto       = false // flag de empresa: ejecutar match automático al abrir Líneas
  #matchAutoRan       = false // guard: el match automático ya se ejecutó una vez

  // Datos del XML
  #xmlDoc           = null
  #xmlDocCopy       = null
  #xmlDoc2          = null   // cargos del XML
  #docCurrency      = ''
  #docTypeXML       = null

  // Estado del formulario Cabecera
  #cardCodeValue    = ''
  #selectedSupplierId = null
  #selectedDocEntry = null
  #closeRefDocument = false
  #supplierExtraDays= 0

  // Estado de líneas de factura
  #apInvoiceLines   = []     // líneas principales
  #otherChargeLines = []     // líneas de otros cargos
  #idItemTable      = 0
  #selectedXmlLine  = null   // línea XML actualmente seleccionada para agregar
  #selectedItemLines = []    // líneas XML seleccionadas para agregar juntas (multi-select)
  #selectedOcLines  = []     // líneas XML de cargo seleccionadas para Otros Cargos (multi-select)
  #ocApLines        = []     // líneas DocumentAPInvoiceLines agregadas desde Otros Cargos (solo para display)
  #errorOnCreate    = false

  // Preview doc (reception)
  #previewDocument  = null

  // Tolerancia — resolver promise externo
  #toleranceResolve = null
  #currencyResolve  = null

  // Debounce timer para autocomplete
  #refDocDebounceTimer = null

  // Mapeo de UDFs completado
  #mappedUdfs = []

  // Instancias Tabulator
  #xmlLinesTabulator        = null
  #sapLinesTabulator        = null
  #otrosCargosTabulator     = null
  #apInvoiceLinesTabulator  = null
  #ocApLinesTabulator       = null
  #ocChargesTabulator       = null

  // ── connect ───────────────────────────────────────────
  connect() {
    this.#docId     = this.docIdValue
    this.#session   = Storage.get('Session') || {}
    const company   = SStore.get('CurrentCompany')

    if (company) {
      this.#companyId         = company.companyId
      this.#sendReceptAndApInv = !!company.SendReceptAndApInv
    }

    // Leer parámetros de query string
    const params = new URLSearchParams(window.location.search)
    this.#docTypeXML   = params.has('xmlDocType') ? Number(params.get('xmlDocType')) : null
    this.#shouldRecept = sessionStorage.getItem('shouldRecept') === 'true'

    if (this.#shouldRecept) {
      this.receptAccordionTarget.classList.remove('hidden')
    }

    this.#loadAll()
  }

  disconnect() {
    sessionStorage.removeItem('shouldRecept')
    if (this.#refDocDebounceTimer) clearTimeout(this.#refDocDebounceTimer)
    this.#xmlLinesTabulator?.destroy()
    this.#sapLinesTabulator?.destroy()
    this.#otrosCargosTabulator?.destroy()
    this.#apInvoiceLinesTabulator?.destroy()
    this.#ocApLinesTabulator?.destroy()
    this.#ocChargesTabulator?.destroy()
  }

  // ── Carga inicial paralela ─────────────────────────────
  async #loadAll() {
    if (!this.#companyId) {
      showToast('No tiene una compañía seleccionada. Seleccione una antes de continuar.', 'warning')
      return
    }
    if (this.#docTypeXML === null) {
      showToast('Tipo de documento XML no especificado', 'error')
      Turbo.visit(this.#getReturnUrl())
      return
    }

    this.#showLoading('Cargando información...')

    try {
      const [
        accountsRes, docXmlRes, docChargesRes, taxRes, itemsRes,
        companyRes, dimensionsRes, warehouseRes, projectsRes, currenciesRes,
        freightRes, activityRes
      ] = await Promise.all([
        this.#apiFetch('/api/Account/GetAccounts'),
        this.#apiFetch(`/api/Documents/GetDocAPInvoiceInfoXML?docId=${this.#docId}`),
        this.#apiFetch(`/api/Documents/GetDocAPInvoiceCharges?docId=${this.#docId}`),
        this.#apiFetch(`/api/Tax?CompanyId=${this.#companyId}`),
        this.#apiFetch('/api/Item/GetItems'),
        this.#apiFetch(`/api/companies/${this.#companyId}`),
        this.#apiFetch('/api/Companies/GetDimensionsAndCntrCost'),
        this.#apiFetch(`/api/Warehouse?CompanyId=${this.#companyId}`),
        this.#apiFetch('/api/Project'),
        this.#apiFetch(`/api/Companies/${this.#companyId}/currencies`),
        this.#apiFetch('/api/Companies/GetAdditionalFreights'),
        this.#apiFetch(`/api/Companies/${this.#companyId}/activity-codes`).catch(() => null),
      ])

      if (accountsRes?.Data?.length)     this.#accountList      = accountsRes.Data
      if (docXmlRes?.Data)               this.#xmlDoc           = docXmlRes.Data
      if (docChargesRes?.Data)           this.#xmlDoc2          = docChargesRes.Data
      if (taxRes?.Data?.length)          this.#taxCodeList      = taxRes.Data
      if (itemsRes?.Data?.length)        this.#itemSAPList      = itemsRes.Data
      if (companyRes?.Data) {
        this.#xmlToleranceAmounts = companyRes.Data.XmlToleranceAmounts ?? []
        this.#defaultTaxForXML    = companyRes.Data.DefaultTaxForXML    ?? ''
        this.#freightChargesMode  = companyRes.Data.FreightCharges === 2 ? 2 : 1
      }
      if (dimensionsRes?.Data?.length)   this.#dimensionList    = dimensionsRes.Data
      if (warehouseRes?.Data?.length)    this.#warehouseList    = warehouseRes.Data
      if (projectsRes?.Data?.length)     this.#projectList      = projectsRes.Data
      if (currenciesRes?.Data)           this.#companyCurrencies = currenciesRes.Data ?? []
      if (freightRes?.Data?.length)      this.#freightList        = freightRes.Data
      this.#activityCodes = activityRes?.Data ?? activityRes ?? []
      this.#populateActivitySelect()
    } catch (err) {
      this.#hideLoading()
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al cargar datos', message: err.message })
      return
    }

    // Segunda carga (proveedores, UDFs, tipos de doc base)
    try {
      const [suppliersRes, udfsRes, docTypeBaseRes] = await Promise.all([
        this.#apiFetch('/api/BusinessPartners'),
        this.#apiFetch(`/api/Udf/GetConfiguredUdfs?companyId=${this.#companyId}&Category=true`),
        this.#apiFetch('/api/Documents/GetDocTypeBase'),
      ])

      if (suppliersRes?.Data)    this.#supplierList  = suppliersRes.Data
      if (udfsRes?.Data)         this.#dynamicUdfs   = udfsRes.Data
      if (docTypeBaseRes?.Data)  this.#docTypeList   = docTypeBaseRes.Data
    } catch (err) {
      showToast(`Advertencia al cargar catálogos: ${err.message}`, 'warning')
    }

    // Flag de empresa: ¿ejecutar match automático al abrir el tab Líneas?
    // Puente estático equivalente al legacy assets/data/CompanyUseMatchAuto.json
    await this.#loadMatchAutoFlag()

    this.#hideLoading()
    await this.#validateAndApplyDocXML()
  }

  // ── Flag de match automático (puente estático) ────────
  async #loadMatchAutoFlag() {
    try {
      const res  = await fetch('/CompanyUseMatchAuto.json', { headers: { Accept: 'application/json' } })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = await res.json()
      this.#useMatchAuto = !!json?.Data?.UseMatchAuto
    } catch (err) {
      this.#useMatchAuto = false
      console.warn('No se pudo leer CompanyUseMatchAuto.json, match automático deshabilitado:', err)
    }
  }

  // ── Validación de moneda del XML ───────────────────────
  async #validateAndApplyDocXML() {
    if (!this.#xmlDoc) {
      this.#finishSetup()
      return
    }

    const xmlCur = this.#xmlDoc.DocCur
    const match  = this.#companyCurrencies.find(c => c.Code === xmlCur)

    if (match) {
      this.#applyXMLDocToState(xmlCur)
    } else {
      const result = await this.#openCurrencyMismatchModal(xmlCur)
      if (!result?.code) {
        showToast('Debe seleccionar una moneda para continuar', 'warning')
        return
      }
      if (result.save) {
        this.#apiFetch(`/api/Companies/${this.#companyId}/currency-map`, {
          method: 'POST',
          body: JSON.stringify({ XmlCurrencyCode: xmlCur, MappedCurrencyCode: result.code }),
        }).catch(() => {})
      }
      this.#applyXMLDocToState(result.code)
    }
  }

  #applyXMLDocToState(docCur) {
    const symbol = this.#companyCurrencies.find(c => c.Code === docCur)?.Symbol ?? docCur
    this.#xmlDoc.DocCur = docCur
    this.#docCurrency   = symbol

    this.#xmlDoc.DocReceptXMLLines.forEach(line => {
      line.DocCur    = symbol
      line.Available = line.Quantity
    })

    if (this.#xmlDoc2?.DocChargesXMLLines?.length) {
      this.#xmlDoc2.DocCur = docCur
      this.#xmlDoc2.DocChargesXMLLines.forEach(line => {
        line.DocCur    = symbol
        line.Available = line.Quantity
      })
    }

    this.#finishSetup()
  }

  #finishSetup() {
    this.#populateDropdowns()
    this.#renderDynamicUdfs()
    this.#prefillHeaderFromXML()
    this.#patchSupplierFromXML()
    this.#initializeTables()
    this.#loadReceptPreviewIfNeeded()
    this.tabsContainerTarget.classList.remove('hidden')
  }

  // ── Poblar dropdowns ───────────────────────────────────
  #populateDropdowns() {
    // RefDocType
    const refSelect = this.selectRefDocTypeTarget
    this.#docTypeList.forEach(d => {
      const opt = document.createElement('option')
      opt.value       = d.DocType
      opt.textContent = d.DocTypeShow
      refSelect.appendChild(opt)
    })

    // Item panel — autocomplete fields usan listas en memoria, no necesitan poblar selects

    // OC panel — autocomplete fields usan listas en memoria, no necesitan poblar selects

    // OC panel — Cargos adicionales SAP (modo 2)
    const freightSel = this.ocSelectFreightTarget
    freightSel.innerHTML = '<option value="">-- Seleccione cargo --</option>'
    this.#freightList.forEach(f => {
      const opt = document.createElement('option')
      opt.value       = f.ExpenseCode
      opt.textContent = `${f.ExpenseCode} - ${f.Name}`
      freightSel.appendChild(opt)
    })

    // Item panel — Dimensiones
    this.#dimensionList.forEach(dim => {
      const code = dim.DimCode  // 1-5
      const itemRowTarget = this[`itemDimRow${code}Target`]
      const itemSelTarget = this[`itemDim${code}Target`]
      if (!itemRowTarget || !itemSelTarget) return
      const itemLabel = itemRowTarget.querySelector('label')
      if (itemLabel) itemLabel.textContent = dim.DimName || `Dimensión ${code}`
      const blankOpt = document.createElement('option')
      blankOpt.value = ''; blankOpt.textContent = 'Ninguna'
      itemSelTarget.appendChild(blankOpt)
      dim.CenterCost?.forEach(cc => {
        const opt = document.createElement('option')
        opt.value = cc.PrcCode; opt.textContent = `${cc.PrcCode} - ${cc.PrcName}`
        itemSelTarget.appendChild(opt)
      })
      itemRowTarget.classList.remove('hidden')
    })

    // OC panel — Dimensiones (solo las configuradas en SAP)
    this.#dimensionList.forEach(dim => {
      const code = dim.DimCode  // 1-5
      const rowTarget  = this[`ocDimRow${code}Target`]
      const selTarget  = this[`ocDim${code}Target`]
      if (!rowTarget || !selTarget) return

      // Label dinámico
      const label = rowTarget.querySelector('label')
      if (label) label.textContent = dim.DimName || `Dimensión ${code}`

      // Opción vacía
      const blank = document.createElement('option')
      blank.value       = ''
      blank.textContent = 'Ninguna'
      selTarget.appendChild(blank)

      // Centros de costo
      dim.CenterCost?.forEach(cc => {
        const opt = document.createElement('option')
        opt.value       = cc.PrcCode
        opt.textContent = `${cc.PrcCode} - ${cc.PrcName}`
        selTarget.appendChild(opt)
      })

      // Mostrar fila
      rowTarget.classList.remove('hidden')
    })
  }

  // ── UDFs dinámicos ─────────────────────────────────────
  #renderDynamicUdfs() {
    if (!this.#dynamicUdfs.length) return
    const container = this.udfsContainerTarget

    this.#dynamicUdfs.forEach(udf => {
      const wrapper = document.createElement('div')

      if (udf.Values) {
        // Select
        const mapped = JSON.parse(udf.Values)
        wrapper.innerHTML = `
          <label class="block text-xs font-medium text-gray-600 mb-1">${udf.Description}${udf.IsRequired ? ' <span class="text-red-500">*</span>' : ''}</label>
          <select name="udf_${udf.Name}" data-udf-name="${udf.Name}"
                  class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 bg-white">
            <option value="">-- Seleccione --</option>
            ${mapped.map(v => `<option value="${v.Value}">${v.Description}</option>`).join('')}
          </select>`
      } else {
        // Text input
        wrapper.innerHTML = `
          <label class="block text-xs font-medium text-gray-600 mb-1">${udf.Description}${udf.IsRequired ? ' <span class="text-red-500">*</span>' : ''}</label>
          <input type="text" name="udf_${udf.Name}" data-udf-name="${udf.Name}"
                 class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500">`
      }
      container.appendChild(wrapper)
    })
  }

  // ── Pre-relleno del formulario desde xmlDoc ────────────
  #prefillHeaderFromXML() {
    if (!this.#xmlDoc) return

    const taxDate = this.#xmlDoc.TaxDate ? this.#xmlDoc.TaxDate.split('T')[0] : ''

    this.inputDocDateTarget.value    = taxDate
    this.inputTaxDateTarget.value    = taxDate
    this.inputCardNameTarget.value   = this.#xmlDoc.CardName   ?? ''
    this.inputNumAtCardTarget.value  = this.#xmlDoc.NumAtCard  ?? ''
    this.inputCommentsTarget.value   = this.#xmlDoc.Comments   ?? ''
    this.inputDocCurTarget.value     = this.#xmlDoc.DocCur     ?? ''
    this.commentsCharCountTarget.textContent = (this.#xmlDoc.Comments ?? '').length

    // POCL24 en OthersRecepts → RefDocType = Orden de Compra
    const pocl24 = this.#xmlDoc.OthersRecepts?.find(r => r.Codigo === 'POCL24')
    if (pocl24?.Valor) {
      this.inputRefDocEntryTarget.value = pocl24.Valor
    }

    // DocDueDate inicial = TaxDate (sin ExtraDays todavía)
    this.inputDocDueDateTarget.value = taxDate
  }

  #patchSupplierFromXML() {
    if (!this.#xmlDoc) return
    const sup = this.#supplierList.find(s => s.LicTradNum?.includes(this.#xmlDoc.LicTradNum))
    if (sup) {
      this.inputCardCodeTarget.value = sup.FullName
      this.#cardCodeValue            = sup.FullName
      this.#selectedSupplierId       = sup.CardCode
      this.#supplierExtraDays        = sup.ExtraDays ?? 0
      this.#updateDocDueDate()
      this.#updateHeaderFormValidity()
    } else if (this.#xmlDoc.LicTradNum) {
      showToast(`El proveedor ${this.#xmlDoc.CardName} con la cédula ${this.#xmlDoc.LicTradNum} no existe en SAP`, 'warning')
    }
  }

  // ── Inicialización de tablas Tabulator ─────────────────
  #initializeTables() {
    this.#initXmlLinesTable()
    this.#initSapLinesTable()
    this.#initOtrosCargosTable()
    this.#initApInvoiceLinesTable()
    this.#initOcApLinesTable()
    this.#initOcChargesTable()
    this.#setupOcTooltip()
  }

  #initXmlLinesTable() {
    this.#xmlLinesTabulator = new Tabulator(this.xmlLinesTableTarget, {
      data:           this.#xmlDoc?.DocReceptXMLLines ?? [],
      layout:         'fitColumns',
      maxHeight:      '320px',
      placeholder:    'Sin líneas',
      locale:         TABULATOR_LOCALE,
      langs:          TABULATOR_LANGS,
      columnDefaults: { headerSort: false },
      selectable:      true,
      selectableRangeMode: 'click',
      columns: [
        { formatter: 'rowSelection', titleFormatter: 'rowSelection', hozAlign: 'center', headerHozAlign: 'center', width: 40, headerSort: false },
        { title: 'Código',      field: 'Code',      widthGrow: 1 },
        { title: 'Detalle',     field: 'Detail',    widthGrow: 2 },
        { title: 'Cantidad',    field: 'Quantity',  hozAlign: 'right', width: 90 },
        { title: 'Precio',      field: 'UnitPrice', hozAlign: 'right', width: 120,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Descuento',   field: 'Discount',  hozAlign: 'right', width: 110,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Impuesto',    field: 'ImpTarifa', hozAlign: 'right', width: 90,
          formatter: (cell) => `${cell.getValue() ?? 0}%` },
        { title: 'Monto Línea', field: 'TotalLine', hozAlign: 'right', width: 130,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Disponible',  field: 'Available', hozAlign: 'right', width: 100,
          formatter: (cell) => {
            const val = cell.getValue() ?? 0
            return `<span class="${val <= 0 ? 'text-green-600 font-semibold' : ''}">${val}</span>`
          }
        },
        { title: 'Acción', field: '_action', hozAlign: 'center', width: 70,
          formatter: (cell) => {
            const available = cell.getRow().getData().Available ?? 0
            const disabled  = available <= 0
            return `<button type="button" title="Agregar" ${disabled ? 'disabled' : ''}
                      class="p-1.5 ${disabled ? 'text-gray-300 cursor-not-allowed' : 'text-blue-600 hover:bg-blue-50'} rounded transition-colors">
                      <span class="material-icons text-base">add_circle_outline</span>
                    </button>`
          },
          cellClick: (_e, cell) => {
            const data = cell.getRow().getData()
            if ((data.Available ?? 0) <= 0) return
            const line = this.#xmlDoc?.DocReceptXMLLines?.find(l => l.RowId === data.RowId)
            if (!line) return
            // Si hay filas marcadas, agregar todas juntas; si no, solo esta línea
            const selected = this.#xmlLinesTabulator.getSelectedRows()
              .map(r => this.#xmlDoc?.DocReceptXMLLines?.find(l => l.RowId === r.getData().RowId))
              .filter(Boolean)
            const lines = selected.length > 0 ? selected : [line]
            this.#openItemSelectionForLines(lines)
          },
        },
      ],
    })
  }

  #initSapLinesTable() {
    this.#sapLinesTabulator = new Tabulator(this.sapLinesTableTarget, {
      data:           [...this.#apInvoiceLines],
      layout:         'fitColumns',
      maxHeight:      '320px',
      placeholder:    'Sin líneas',
      locale:         TABULATOR_LOCALE,
      langs:          TABULATOR_LANGS,
      columnDefaults: { headerSort: false },
      selectable:      true,
      selectableRangeMode: 'click',
      columns: [
        { formatter: 'rowSelection', titleFormatter: 'rowSelection', hozAlign: 'center', headerHozAlign: 'center', width: 40, headerSort: false },
        { title: 'Código SAP', field: 'ItemCode',       widthGrow: 1 },
        { title: 'Código XML', field: 'ItemCodeXML',    widthGrow: 1 },
        { title: 'Detalle',    field: 'ItemNameEdited', widthGrow: 2,
          editor: 'input',
          cellEdited: (cell) => this.#onSapLineCellEdited(cell) },
        { title: 'Cuenta',     field: 'SapAccountCode', widthGrow: 2,
          editor: this.#makeAutocompleteEditor(
            this.#accountList,
            a => `${a.FormatCode} - ${a.AcctName}`,
            a => a.AcctCode,
          ),
          formatter: (cell) => {
            const acc = this.#accountList.find(a => a.AcctCode === cell.getValue())
            return acc ? `${acc.FormatCode} - ${acc.AcctName}` : (cell.getValue() || '—')
          },
          cellEdited: (cell) => this.#onSapLineCellEdited(cell) },
        { title: 'Proyecto',   field: 'ProjectCode',    widthGrow: 1,
          editor: this.#makeAutocompleteEditor(
            this.#projectList,
            p => `${p.Code} - ${p.Name}`,
            p => p.Code,
          ),
          formatter: (cell) => {
            const prj = this.#projectList.find(p => p.Code === cell.getValue())
            return prj ? `${prj.Code} - ${prj.Name}` : (cell.getValue() || '—')
          },
          cellEdited: (cell) => this.#onSapLineCellEdited(cell) },
        { title: 'Cantidad',   field: 'Quantity',       hozAlign: 'right', width: 90 },
        { title: 'Almacén',    field: 'WhsCode',        width: 90 },
        { title: 'Precio',     field: 'UnitPrice',      hozAlign: 'right', width: 120,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Descuento',  field: 'Disc',           hozAlign: 'right', width: 110,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Impuesto',   field: 'TaxCode',        width: 100,
          editor: this.#makeAutocompleteEditor(
            this.#taxCodeList,
            t => t.TaxCode,
            t => t.TaxCode,
          ),
          cellEdited: (cell) => this.#onSapLineCellEdited(cell) },
        { title: 'Monto',      field: 'LineTotal',      hozAlign: 'right', width: 130,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Acciones',   field: '_actions',       hozAlign: 'center', width: 110,
          formatter: () => `
            <button type="button" data-action-type="dim" data-tooltip="Ajustar dimensiones"
                    class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors">
              <span class="material-icons text-base">tune</span>
            </button>
            <button type="button" data-action-type="delete" data-tooltip="Eliminar"
                    class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors">
              <span class="material-icons text-base">delete</span>
            </button>`,
          cellClick: (_e, cell) => {
            const btn  = _e.target.closest('[data-action-type]')
            if (!btn) return
            const data = cell.getRow().getData()
            if (btn.dataset.actionType === 'dim') {
              this.#openDimEditPanel('item', data.TableId, data)
            } else {
              const selected = this.#sapLinesTabulator.getSelectedRows()
              const ids = selected.length > 0
                ? selected.map(r => r.getData().TableId)
                : [data.TableId]
              this.#confirmAndRemoveSapLines(ids)
            }
          },
        },
      ],
    })
  }

  // ── Editor autocomplete personalizado ──────────────────
  // Retorna una función editor compatible con Tabulator.
  // El dropdown se monta en document.body con position:fixed para evitar
  // el overflow:hidden de las celdas (mismo patrón que el tooltip system).
  #makeAutocompleteEditor(list, labelFn, valueFn) {
    return (cell, onRendered, success, cancel) => {
      const dropId = `cl-ac-${Math.random().toString(36).slice(2)}`

      const input       = document.createElement('input')
      input.type        = 'text'
      input.placeholder = 'Buscar...'
      input.style.cssText = [
        'width:100%', 'padding:2px 6px', 'border:1px solid #3b82f6',
        'outline:none', 'font-size:12px', 'box-sizing:border-box',
        'background:#fff', 'color:#111827',
      ].join(';')

      // Mostrar la etiqueta del valor actual
      const currentItem = list.find(i => valueFn(i) === cell.getValue())
      input.value = currentItem ? labelFn(currentItem) : (cell.getValue() || '')

      const cleanup = () => document.getElementById(dropId)?.remove()

      const showDropdown = (filter) => {
        cleanup()
        const rect  = input.getBoundingClientRect()
        const drop  = document.createElement('div')
        drop.id     = dropId
        drop.style.cssText = [
          'position:fixed',
          `top:${rect.bottom + 2}px`,
          `left:${rect.left}px`,
          `width:${Math.max(rect.width, 260)}px`,
          'background:#fff',
          'border:1px solid #e5e7eb',
          'border-radius:6px',
          'box-shadow:0 4px 12px rgba(0,0,0,.15)',
          'max-height:200px',
          'overflow-y:auto',
          'z-index:99999',
          'font-size:12px',
        ].join(';')

        const items = filter
          ? list.filter(i => labelFn(i).toLowerCase().includes(filter) || valueFn(i).toLowerCase().includes(filter))
          : list.slice(0, 80)

        if (!items.length) {
          drop.innerHTML = `<div style="padding:8px 10px;color:#9ca3af">Sin resultados</div>`
        } else {
          items.forEach(i => {
            const opt = document.createElement('div')
            opt.style.cssText = 'padding:6px 10px;cursor:pointer;color:#374151;white-space:nowrap;overflow:hidden;text-overflow:ellipsis'
            opt.textContent   = labelFn(i)
            opt.title         = labelFn(i)
            opt.addEventListener('mousedown', e => {
              e.preventDefault()   // evita que el blur del input se dispare primero
              cleanup()
              success(valueFn(i))
            })
            opt.addEventListener('mouseenter', () => { opt.style.background = '#eff6ff' })
            opt.addEventListener('mouseleave', () => { opt.style.background = '' })
            drop.appendChild(opt)
          })
        }

        document.body.appendChild(drop)
      }

      onRendered(() => {
        input.focus()
        showDropdown('')
      })

      input.addEventListener('input',   () => showDropdown(input.value.toLowerCase()))
      input.addEventListener('blur',    () => setTimeout(() => { cleanup(); cancel() }, 200))
      input.addEventListener('keydown', e => {
        if (e.key === 'Escape') { cleanup(); cancel() }
        if (e.key === 'Tab')    { cleanup(); cancel() }
      })

      return input
    }
  }

  #onSapLineCellEdited(cell) {
    const field   = cell.getColumn().getField()
    const rowData = cell.getRow().getData()
    const apLine  = this.#apInvoiceLines.find(l => l.TableId === rowData.TableId)
    if (!apLine) return

    apLine[field] = cell.getValue()

    if (field === 'SapAccountCode') {
      const acc = this.#accountList.find(a => a.AcctCode === cell.getValue())
      apLine.SapAccountName = acc ? `${acc.FormatCode}-${acc.AcctName}` : ''
    }

    if (field === 'TaxCode') {
      const tax = this.#taxCodeList.find(t => t.TaxCode === cell.getValue())
      if (tax) {
        apLine.TaxRate   = String(tax.TaxRate ?? 0)
        apLine.TaxAmount = ((apLine.UnitPrice * apLine.Quantity) - apLine.Disc) * (Number(apLine.TaxRate) / 100)
        apLine.LineTotal = ((apLine.UnitPrice * apLine.Quantity) - apLine.Disc) + apLine.TaxAmount
        cell.getRow().update({ LineTotal: apLine.LineTotal })
        this.#calculateTotals()
      }
    }

    if (field === 'ProjectCode') {
      const prj = this.#projectList.find(p => p.Code === cell.getValue())
      apLine.ProjectName = prj ? `${prj.Code}-${prj.Name}` : ''
    }

    this.#renderApInvoiceLinesHeader()
  }

  #removeSapLineByTableId(tableId) {
    const idx = this.#apInvoiceLines.findIndex(l => l.TableId === tableId)
    if (idx < 0) return
    const line = this.#apInvoiceLines[idx]

    const xmlLine = this.#xmlDoc?.DocReceptXMLLines?.find(l => l.RowId === line.RowId)
    if (xmlLine) xmlLine.Available += line.Quantity

    this.#apInvoiceLines.splice(idx, 1)
    this.#renderSapLinesTable()
    this.#renderXmlLinesTable()
    this.#renderApInvoiceLinesHeader()
    this.#calculateTotals()
  }

  // ── Confirmación de borrado (siempre, 1 o varias filas) ───
  #confirmDelete(count) {
    const msg = count > 1
      ? `¿Está seguro de que desea eliminar las ${count} filas seleccionadas? Esta acción no se puede deshacer.`
      : '¿Está seguro de que desea eliminar esta fila? Esta acción no se puede deshacer.'
    return confirm(msg, 'Eliminar')
  }

  async #confirmAndRemoveSapLines(ids) {
    if (!ids?.length) return
    if (!(await this.#confirmDelete(ids.length))) return
    ids.forEach(id => this.#removeSapLineByTableId(id))
    this.#sapLinesTabulator?.deselectRow()
  }

  async #confirmAndRemoveOcApLines(ids) {
    if (!ids?.length) return
    if (!(await this.#confirmDelete(ids.length))) return
    ids.forEach(id => this.#removeOcApLine(id))
    this.#ocApLinesTabulator?.deselectRow()
  }

  async #confirmAndRemoveOcCharges(codes) {
    if (!codes?.length) return
    if (!(await this.#confirmDelete(codes.length))) return
    codes.forEach(code => this.#removeOcCharge(code))
    this.#ocChargesTabulator?.deselectRow()
  }

  #initOtrosCargosTable() {
    this.#otrosCargosTabulator = new Tabulator(this.otrosCargosTableTarget, {
      data:            this.#xmlDoc2?.DocChargesXMLLines ?? [],
      layout:          'fitColumns',
      maxHeight:       '320px',
      placeholder:     'Sin cargos adicionales',
      locale:          TABULATOR_LOCALE,
      langs:           TABULATOR_LANGS,
      columnDefaults:  { headerSort: false },
      selectable:      true,
      selectableRangeMode: 'click',
      columns: [
        { formatter: 'rowSelection', titleFormatter: 'rowSelection', hozAlign: 'center', headerHozAlign: 'center', width: 40, headerSort: false },
        { title: 'Código',     field: 'Code',      widthGrow: 1 },
        { title: 'Detalle',    field: 'Detail',    widthGrow: 2 },
        { title: 'Cantidad',   field: 'Quantity',  hozAlign: 'right', width: 90 },
        { title: 'Precio',     field: 'UnitPrice', hozAlign: 'right', width: 120,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Disponible', field: 'Available', hozAlign: 'right', width: 100 },
        { title: 'Acción',     field: '_action',   hozAlign: 'center', width: 70,
          formatter: () => `<button type="button" data-tooltip="Agregar"
                              class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors">
                              <span class="material-icons text-base">add_circle_outline</span>
                            </button>`,
          cellClick: (_e, cell) => {
            const rowData = cell.getRow().getData()
            const line    = this.#xmlDoc2?.DocChargesXMLLines?.find(l => l.RowId === rowData.RowId)
            if (!line) return
            // Si hay filas seleccionadas, usar todas; si no, solo esta línea
            const selected = this.#otrosCargosTabulator.getSelectedRows().map(r => {
              return this.#xmlDoc2?.DocChargesXMLLines?.find(l => l.RowId === r.getData().RowId)
            }).filter(Boolean)
            const lines = selected.length > 0 ? selected : [line]
            this.#openOcSelectionForLines(lines)
          },
        },
      ],
    })
  }

  #initApInvoiceLinesTable() {
    this.#apInvoiceLinesTabulator = new Tabulator(this.apInvoiceLinesTableTarget, {
      data:           [...this.#apInvoiceLines],
      layout:         'fitColumns',
      maxHeight:      '240px',
      placeholder:    'Sin líneas agregadas',
      locale:         TABULATOR_LOCALE,
      langs:          TABULATOR_LANGS,
      columnDefaults: { headerSort: false },
      columns: [
        { title: 'Código SAP', field: 'ItemCode',       widthGrow: 1 },
        { title: 'Código XML', field: 'ItemCodeXML',    widthGrow: 1 },
        { title: 'Detalle',    field: 'ItemNameEdited', widthGrow: 2 },
        { title: 'Cuenta',     field: 'SapAccountName', widthGrow: 2 },
        { title: 'Proyecto',   field: 'ProjectName',    widthGrow: 1 },
        { title: 'Cantidad',   field: 'Quantity',       hozAlign: 'right', width: 90 },
        { title: 'Almacén',    field: 'WhsCode',        width: 90 },
        { title: 'Precio',     field: 'UnitPrice',      hozAlign: 'right', width: 120,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Descuento',  field: 'Disc',           hozAlign: 'right', width: 110,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Impuesto',   field: 'TaxCode',        width: 90 },
        { title: 'Monto',      field: 'LineTotal',      hozAlign: 'right', width: 130,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
      ],
    })
  }

  #initOcApLinesTable() {
    this.#ocApLinesTabulator = new Tabulator(this.ocApLinesTableTarget, {
      data:            [],
      layout:          'fitColumns',
      maxHeight:       '280px',
      placeholder:     'Sin líneas agregadas',
      locale:          TABULATOR_LOCALE,
      langs:           TABULATOR_LANGS,
      columnDefaults:  { headerSort: false },
      selectable:      true,
      selectableRangeMode: 'click',
      columns: [
        { formatter: 'rowSelection', titleFormatter: 'rowSelection', hozAlign: 'center', headerHozAlign: 'center', width: 40, headerSort: false },
        { title: 'Código XML',  field: 'ItemCodeXML',    widthGrow: 1 },
        { title: 'Detalle',     field: 'ItemNameEdited', widthGrow: 2,
          editor: 'input', editorParams: { elementAttributes: { maxlength: 200 } },
          cellEdited: (cell) => { cell.getRow().getData().ItemNameEdited = cell.getValue() } },
        { title: 'Cuenta',      field: 'SapAccountName', widthGrow: 2,
          editor: this.#makeAutocompleteEditor(
            this.#accountList,
            a => `${a.FormatCode} - ${a.AcctName}`,
            a => `${a.FormatCode} - ${a.AcctName}`,
          ),
          cellEdited: (cell) => {
            const row  = cell.getRow()
            const data = row.getData()
            const acc  = this.#accountList.find(a => `${a.FormatCode} - ${a.AcctName}` === cell.getValue())
            if (acc) { data.SapAccountCode = acc.AcctCode; data.SapAccountName = cell.getValue() }
          },
        },
        { title: 'Proyecto',    field: 'ProjectName',    widthGrow: 1,
          editor: this.#makeAutocompleteEditor(
            this.#projectList,
            p => `${p.Code} - ${p.Name}`,
            p => `${p.Code}-${p.Name}`,   // valueFn → escribe directo en ProjectName
          ),
          cellEdited: (cell) => {
            const data = cell.getRow().getData()
            // Sincronizar ProjectCode (lo que va a SAP) desde el valor seleccionado
            const raw = cell.getValue()   // formato "Code - Name" (del labelFn del autocomplete)
            const prj = this.#projectList.find(p => `${p.Code} - ${p.Name}` === raw || `${p.Code}-${p.Name}` === raw)
            if (prj) data.ProjectCode = prj.Code
          },
        },
        { title: 'Cantidad',    field: 'Quantity',       hozAlign: 'right', width: 90 },
        { title: 'Impuesto',    field: 'TaxCode',        width: 120,
          editor: this.#makeAutocompleteEditor(
            this.#taxCodeList,
            t => `${t.TaxCode} (${t.TaxRate}%)`,
            t => t.TaxCode,
          ),
          cellEdited: (cell) => {
            const data   = cell.getRow().getData()
            const taxObj = this.#taxCodeList.find(t => t.TaxCode === cell.getValue())
            if (!taxObj) return
            data.TaxCode   = taxObj.TaxCode
            data.TaxRate   = String(taxObj.TaxRate)
            const net      = (data.UnitPrice * data.Quantity) - (data.Disc ?? 0)
            data.TaxAmount = net * (Number(taxObj.TaxRate) / 100)
            data.LineTotal = net + data.TaxAmount
            cell.getRow().update(data)
            this.#renderApInvoiceLinesHeader()
            this.#calculateTotals()
          },
        },
        { title: 'Monto',       field: 'LineTotal',      hozAlign: 'right', width: 130,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Acciones',    field: '_actions',       hozAlign: 'center', width: 100,
          formatter: () => `
            <button type="button" data-action-type="dim" data-tooltip="Ajustar dimensiones"
                    class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors">
              <span class="material-icons text-base">tune</span>
            </button>
            <button type="button" data-action-type="delete" data-tooltip="Eliminar"
                    class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors">
              <span class="material-icons text-base">delete</span>
            </button>`,
          cellClick: (_e, cell) => {
            const btn  = _e.target.closest('[data-action-type]')
            if (!btn) return
            const data = cell.getRow().getData()
            if (btn.dataset.actionType === 'dim') {
              this.#openDimEditPanel('sap', data.TableId, data)
            } else {
              const selected = this.#ocApLinesTabulator.getSelectedRows()
              const ids = selected.length > 0
                ? selected.map(r => r.getData().TableId)
                : [data.TableId]
              this.#confirmAndRemoveOcApLines(ids)
            }
          },
        },
      ],
    })
  }

  #initOcChargesTable() {
    this.#ocChargesTabulator = new Tabulator(this.ocChargesTableTarget, {
      data:            [],
      layout:          'fitColumns',
      maxHeight:       '280px',
      placeholder:     'Sin cargos adicionales',
      locale:          TABULATOR_LOCALE,
      langs:           TABULATOR_LANGS,
      columnDefaults:  { headerSort: false },
      selectable:      true,
      selectableRangeMode: 'click',
      columns: [
        { formatter: 'rowSelection', titleFormatter: 'rowSelection', hozAlign: 'center', headerHozAlign: 'center', width: 40, headerSort: false },
        { title: 'Código',         field: 'ExpenseCode', width: 100 },
        { title: 'Detalle',        field: 'Remarks',     widthGrow: 3 },
        { title: 'Tarifa Impuesto',field: 'TaxCode',     width: 150,
          editor: this.#makeAutocompleteEditor(
            this.#taxCodeList,
            t => `${t.TaxCode} (${t.TaxRate}%)`,
            t => t.TaxCode,
          ),
          cellEdited: (cell) => {
            const data   = cell.getRow().getData()
            const taxObj = this.#taxCodeList.find(t => t.TaxCode === cell.getValue())
            if (!taxObj) return
            data.TaxCode = taxObj.TaxCode
            const net    = data.OriginalLineTotal ?? data.LineTotal
            const taxAmount = net * (Number(taxObj.TaxRate) / 100)
            data.LineTotal  = Number((net + taxAmount).toFixed(2))
            cell.getRow().update(data)
            this.#calculateTotals()
          },
        },
        { title: 'Monto Cargo',    field: 'LineTotal',   hozAlign: 'right', width: 140,
          formatter: (cell) => this.#fmtMoney(cell.getValue(), this.#docCurrency) },
        { title: 'Acciones',       field: '_actions',    hozAlign: 'center', width: 100,
          formatter: () => `
            <button type="button" data-action-type="dim" data-tooltip="Ajustar dimensiones"
                    class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors">
              <span class="material-icons text-base">tune</span>
            </button>
            <button type="button" data-action-type="delete" data-tooltip="Eliminar"
                    class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors">
              <span class="material-icons text-base">delete</span>
            </button>`,
          cellClick: (_e, cell) => {
            const btn  = _e.target.closest('[data-action-type]')
            if (!btn) return
            const data = cell.getRow().getData()
            if (btn.dataset.actionType === 'dim') {
              this.#openDimEditPanel('other', data.ExpenseCode, data)
            } else {
              const selected = this.#ocChargesTabulator.getSelectedRows()
              const codes = selected.length > 0
                ? selected.map(r => r.getData().ExpenseCode)
                : [data.ExpenseCode]
              this.#confirmAndRemoveOcCharges(codes)
            }
          },
        },
      ],
    })
  }

  #setupOcTooltip() {
    if (!document.getElementById('cl-tabulator-tooltip')) {
      const tip = document.createElement('div')
      tip.id = 'cl-tabulator-tooltip'
      tip.style.cssText = [
        'position:fixed', 'z-index:9999', 'pointer-events:none',
        'background:#1f2937', 'color:#fff', 'padding:2px 8px',
        'border-radius:4px', 'font-size:12px', 'white-space:nowrap',
        'opacity:0', 'transition:opacity 0.15s',
      ].join(';')
      document.body.appendChild(tip)
    }
    const tip = document.getElementById('cl-tabulator-tooltip')
    ;[this.ocApLinesTableTarget, this.ocChargesTableTarget].forEach(container => {
      let activeBtn = null
      container.addEventListener('mouseover', (e) => {
        const btn = e.target.closest('[data-tooltip]')
        if (btn && btn !== activeBtn) {
          activeBtn = btn
          tip.textContent = btn.dataset.tooltip
          tip.style.opacity = '1'
        } else if (!btn) {
          activeBtn = null
          tip.style.opacity = '0'
        }
      })
      container.addEventListener('mousemove', (e) => {
        if (!activeBtn) return
        tip.style.left = (e.clientX + 10) + 'px'
        tip.style.top  = (e.clientY - 32) + 'px'
      })
      container.addEventListener('mouseleave', () => {
        activeBtn = null
        tip.style.opacity = '0'
      })
    })
  }

  // ── Render methods (setData en instancias ya inicializadas) ────
  #renderXmlLinesTable() {
    this.#xmlLinesTabulator?.setData(this.#xmlDoc?.DocReceptXMLLines ?? [])
  }

  #renderOtrosCargosTable() {
    this.#otrosCargosTabulator?.setData(this.#xmlDoc2?.DocChargesXMLLines ?? [])
  }

  #renderOcApLinesTable() {
    this.#ocApLinesTabulator?.setData([...this.#ocApLines])
    // Solo visible en modo 1 (Artículos) y cuando hay datos
    const show = this.#freightChargesMode === 1 && this.#ocApLines.length > 0
    this.ocApLinesSectionTarget.classList.toggle('hidden', !show)
  }

  #renderOcChargesTable() {
    this.#ocChargesTabulator?.setData([...this.#otherChargeLines])
    // Solo visible en modo 2 (Otros Cargos) y cuando hay datos
    const show = this.#freightChargesMode === 2 && this.#otherChargeLines.length > 0
    this.ocChargesSectionTarget.classList.toggle('hidden', !show)
  }

  #renderSapLinesTable() {
    // Excluir líneas que provienen de Otros Cargos — esas se gestionan en su propio tab
    const ocIds = new Set(this.#ocApLines.map(l => l.TableId))
    const lines = this.#apInvoiceLines.filter(l => !ocIds.has(l.TableId))
    this.#sapLinesTabulator?.setData(lines)
  }

  #renderApInvoiceLinesHeader() {
    this.#apInvoiceLinesTabulator?.setData([...this.#apInvoiceLines])
  }

  // ── Acordeón de recepción ──────────────────────────────
  toggleReceptAccordion() {
    const body = this.receptAccordionBodyTarget
    const icon = this.receptAccordionIconTarget
    body.classList.toggle('hidden')
    icon.style.transform = body.classList.contains('hidden') ? 'rotate(0deg)' : 'rotate(180deg)'
  }

  // ── Carga datos de previsualización para el acordeón ──
  async #loadReceptPreviewIfNeeded() {
    if (!this.#shouldRecept) return
    try {
      const data = await this.#apiFetch(`/api/Documents/GetDocumentInfoPreview?documentId=${this.#docId}`)
      if (data?.Data) {
        this.#previewDocument = data.Data
        const r = data.Data.Reception
        if (r) {
          if (r.Mensaje)            this.receptMensajeTarget.value = String(r.Mensaje)
          if (r.CondicionImpuesto)  this.receptCondicionImpuestoTarget.value = r.CondicionImpuesto
          if (r.TaxFactor)          this.receptTaxFactorTarget.value = r.TaxFactor
          if (r.CodigoActividad)    this.receptCodigoActividadTarget.value = r.CodigoActividad
          if (r.DetalleMensaje)     this.receptDetalleMensajeTarget.value = r.DetalleMensaje
        }
        this.#updateReceptDetalleCounter()
        // Aplicar lógica inicial de TaxFactor
        this.onReceptCondicionChange()
      }
    } catch (_err) {
      // Error no crítico
    }
  }

  // ── Eventos del acordeón de recepción ─────────────────
  onReceptCondicionChange() {
    const condicion = this.receptCondicionImpuestoTarget.value
    const taxInput  = this.receptTaxFactorTarget

    if (TAX_FACTOR_CONDITIONS.has(condicion)) {
      taxInput.disabled = false
      taxInput.classList.remove('bg-gray-100', 'text-gray-400', 'cursor-not-allowed')
    } else {
      taxInput.disabled = true
      taxInput.value    = ''
      taxInput.classList.add('bg-gray-100', 'text-gray-400', 'cursor-not-allowed')
      this.errorReceptTaxFactorTarget.classList.add('hidden')
    }
  }

  onReceptMensajeChange() {
    const mensaje  = this.receptMensajeTarget.value
    const required = DETAIL_REQUIRED_MESSAGES.has(mensaje)
    const textarea = this.receptDetalleMensajeTarget

    if (required) {
      textarea.placeholder = 'Detalle requerido para esta respuesta'
    } else {
      textarea.placeholder  = 'Detalle del mensaje (opcional)'
      this.errorReceptDetalleMensajeTarget.classList.add('hidden')
    }
  }

  // Contador de caracteres del detalle: N/160. En rojo cuando hay texto pero por
  // debajo del mínimo (5); el mínimo solo aplica si se ingresó algún mensaje.
  onReceptDetalleMensajeInput() {
    this.errorReceptDetalleMensajeTarget.classList.add('hidden')
    this.#updateReceptDetalleCounter()
  }

  #updateReceptDetalleCounter() {
    if (!this.hasCounterReceptDetalleMensajeTarget) return
    const len   = this.receptDetalleMensajeTarget.value.trim().length
    const short = len > 0 && len < DETAIL_MIN_LENGTH
    this.counterReceptDetalleMensajeTarget.textContent = short
      ? `Mínimo ${DETAIL_MIN_LENGTH} caracteres · ${len}/${DETAIL_MAX_LENGTH}`
      : `${len}/${DETAIL_MAX_LENGTH}`
    this.counterReceptDetalleMensajeTarget.classList.toggle('text-red-600', short)
    this.counterReceptDetalleMensajeTarget.classList.toggle('text-gray-400', !short)
  }

  // ── Previsualización (acordeón) ────────────────────────
  async previewReceptDoc() {
    if (!this.#previewDocument) {
      showToast('No hay documento para previsualizar. Cargue un documento primero.', 'warning')
      return
    }
    this.#fillPreviewPanel(this.#previewDocument)
    this.#openPreview()
  }

  #fillPreviewPanel(data) {
    const sections = []
    sections.push(`<div class="grid grid-cols-2 gap-3">`)
    sections.push(this.#previewField('Consecutivo', data.NumeroConsecutivo))
    sections.push(this.#previewField('Fecha Emisión', data.FechaEmision))
    sections.push(this.#previewField('Clave', data.Clave))
    sections.push(this.#previewField('Moneda', data.ResumenFactura?.CodigoMoneda))
    sections.push(this.#previewField('Total', data.ResumenFactura?.TotalComprobante))
    sections.push(`</div>`)
    this.previewBodyTarget.innerHTML = sections.join('')
  }

  #previewField(label, value) {
    return `<div><p class="text-xs text-gray-500">${label}</p><p class="text-sm font-medium text-gray-800">${value ?? '—'}</p></div>`
  }

  // ── Tabs ───────────────────────────────────────────────
  switchTab(event) {
    const tab = event.currentTarget.dataset.tab

    const allPanels = [this.tabCabeceraTarget, this.tabLineasTarget, this.tabOtrosCargosTarget]
    const allBtns   = [this.tabBtnCabeceraTarget, this.tabBtnLineasTarget, this.tabBtnOtrosCargosTarget]

    allPanels.forEach(p => p.classList.add('hidden'))
    allBtns.forEach(b => {
      b.classList.remove('text-blue-600', 'border-blue-600')
      b.classList.add('text-gray-500', 'border-transparent')
    })

    const panelMap = { cabecera: this.tabCabeceraTarget, lineas: this.tabLineasTarget, 'otros-cargos': this.tabOtrosCargosTarget }
    const btnMap   = { cabecera: this.tabBtnCabeceraTarget, lineas: this.tabBtnLineasTarget, 'otros-cargos': this.tabBtnOtrosCargosTarget }

    panelMap[tab].classList.remove('hidden')
    btnMap[tab].classList.remove('text-gray-500', 'border-transparent')
    btnMap[tab].classList.add('text-blue-600', 'border-blue-600')

    // Al cambiar a Líneas: bloquear CardCode y reforzar redraw de tablas
    if (tab === 'lineas') {
      this.inputCardCodeTarget.disabled = true
      requestAnimationFrame(() => {
        this.#xmlLinesTabulator?.redraw(true)
        this.#sapLinesTabulator?.redraw(true)
      })
      // Match automático: agregar las líneas ya mapeadas una sola vez
      if (this.#useMatchAuto && !this.#matchAutoRan) {
        this.#matchAutoRan = true
        this.#addAutomaticLines()
      }
    }

    // Al cambiar a Otros Cargos: redraw de tablas del panel
    if (tab === 'otros-cargos') {
      requestAnimationFrame(() => {
        this.#otrosCargosTabulator?.redraw(true)
        this.#ocApLinesTabulator?.redraw(true)
        this.#ocChargesTabulator?.redraw(true)
      })
    }
  }

  // ── Formulario Cabecera ────────────────────────────────
  onRefDocTypeChange() {
    const value = this.selectRefDocTypeTarget.value
    const entry = this.inputRefDocEntryTarget

    if (!value) {
      entry.value    = ''
      entry.disabled = true
      entry.classList.add('bg-gray-100', 'text-gray-400', 'cursor-not-allowed')
      this.#selectedDocEntry = null
      this.checkCloseRefDocTarget.disabled = true
    } else {
      entry.disabled = false
      entry.classList.remove('bg-gray-100', 'text-gray-400', 'cursor-not-allowed')
    }
    this.refDocAutocompleteListTarget.classList.add('hidden')
  }

  onRefDocEntryInput() {
    clearTimeout(this.#refDocDebounceTimer)
    const value   = this.inputRefDocEntryTarget.value.trim()
    const docType = this.selectRefDocTypeTarget.value

    if (!value || !docType) {
      this.refDocAutocompleteListTarget.classList.add('hidden')
      return
    }

    this.#refDocDebounceTimer = setTimeout(async () => {
      this.loadingRefDocTarget.classList.remove('hidden')
      try {
        const data = await this.#apiFetch(`/api/Documents/sap?docType=${docType}&searchCriteria=${encodeURIComponent(value)}`)
        const docs = data?.Data ?? []
        this.#renderRefDocAutocomplete(docs)

        // Si hay exactamente 1 resultado → seleccionar automáticamente
        if (docs.length === 1) {
          this.#selectRefDoc(docs[0])
        }
      } catch (_) {
        this.refDocAutocompleteListTarget.classList.add('hidden')
      } finally {
        this.loadingRefDocTarget.classList.add('hidden')
      }
    }, AUTOCOMPLETE_DEBOUNCE)
  }

  #renderRefDocAutocomplete(docs) {
    const list = this.refDocAutocompleteListTarget
    list.innerHTML = ''

    if (!docs.length) {
      list.classList.add('hidden')
      return
    }

    docs.forEach(doc => {
      const item = document.createElement('div')
      item.className = 'px-3 py-2 hover:bg-blue-50 cursor-pointer text-sm'
      item.dataset.testid = `option-doc-${doc.DocNum}`
      item.textContent = `#${doc.DocNum} - ${doc.CardCode}, ${doc.CardName}`
      item.addEventListener('click', () => this.#selectRefDoc(doc))
      list.appendChild(item)
    })

    list.classList.remove('hidden')
  }

  #selectRefDoc(doc) {
    this.inputRefDocEntryTarget.value = `#${doc.DocNum} - ${doc.CardCode}, ${doc.CardName}`
    this.#selectedDocEntry             = doc.DocEntry
    this.refDocAutocompleteListTarget.classList.add('hidden')
    this.checkCloseRefDocTarget.disabled = false
  }

  // ── OC Panel — autocomplete helpers ───────────────────
  // Helper genérico: filtra una lista, renderiza el dropdown y cierra al seleccionar
  #renderOcAutocomplete({ listTarget, inputTarget, hiddenTarget, items, labelFn, valueFn }) {
    const query = inputTarget.value.toLowerCase().trim()
    listTarget.innerHTML = ''

    const filtered = query
      ? items.filter(i => labelFn(i).toLowerCase().includes(query)).slice(0, 30)
      : items.slice(0, 30)

    if (!filtered.length) {
      listTarget.classList.add('hidden')
      return
    }

    filtered.forEach(item => {
      const div = document.createElement('div')
      div.className = 'px-3 py-2 hover:bg-blue-50 cursor-pointer text-sm truncate'
      div.textContent = labelFn(item)
      div.addEventListener('mousedown', e => {
        e.preventDefault()   // evita que el input pierda foco antes del click
        inputTarget.value  = labelFn(item)
        hiddenTarget.value = valueFn(item)
        listTarget.classList.add('hidden')
      })
      listTarget.appendChild(div)
    })

    listTarget.classList.remove('hidden')
  }

  #closeAllOcDropdowns(except = null) {
    const lists = ['ocItemList', 'ocWarehouseList', 'ocTaxCodeList', 'ocAccountList', 'ocProjectList']
    lists.forEach(name => {
      const t = this[`${name}Target`]
      if (t !== except) t.classList.add('hidden')
    })
  }

  // Impuesto
  onOcTaxCodeInput()  { this.#renderOcAutocomplete({ listTarget: this.ocTaxCodeListTarget, inputTarget: this.ocInputTaxCodeTarget, hiddenTarget: this.ocSelectTaxCodeTarget, items: this.#taxCodeList, labelFn: t => `${t.TaxCode} (${t.TaxRate}%)`, valueFn: t => t.TaxCode }) }
  onOcTaxCodeFocus()  { this.#closeAllOcDropdowns(this.ocTaxCodeListTarget); this.#renderOcAutocomplete({ listTarget: this.ocTaxCodeListTarget, inputTarget: this.ocInputTaxCodeTarget, hiddenTarget: this.ocSelectTaxCodeTarget, items: this.#taxCodeList, labelFn: t => `${t.TaxCode} (${t.TaxRate}%)`, valueFn: t => t.TaxCode }) }

  // ── Item panel — autocomplete handlers ────────────────────
  #closeAllItemDropdowns(except = null) {
    const lists = ['itemItemList', 'itemWarehouseList', 'itemAccountList', 'itemProjectList']
    lists.forEach(name => {
      const t = this[`${name}Target`]
      if (t !== except) t.classList.add('hidden')
    })
  }

  onItemItemInput()      { this.#renderOcAutocomplete({ listTarget: this.itemItemListTarget, inputTarget: this.itemInputItemTarget, hiddenTarget: this.itemSelectItemTarget, items: this.#itemSAPList, labelFn: i => i.FullName || `${i.ItemCode} - ${i.ItemName}`, valueFn: i => i.ItemCode }) }
  onItemItemFocus()      { this.#closeAllItemDropdowns(this.itemItemListTarget); this.#renderOcAutocomplete({ listTarget: this.itemItemListTarget, inputTarget: this.itemInputItemTarget, hiddenTarget: this.itemSelectItemTarget, items: this.#itemSAPList, labelFn: i => i.FullName || `${i.ItemCode} - ${i.ItemName}`, valueFn: i => i.ItemCode }) }

  onItemWarehouseInput() { this.#renderOcAutocomplete({ listTarget: this.itemWarehouseListTarget, inputTarget: this.itemInputWarehouseTarget, hiddenTarget: this.itemSelectWarehouseTarget, items: this.#warehouseList, labelFn: w => `${w.WhCode} — ${w.WhName}`, valueFn: w => w.WhCode }) }
  onItemWarehouseFocus() { this.#closeAllItemDropdowns(this.itemWarehouseListTarget); this.#renderOcAutocomplete({ listTarget: this.itemWarehouseListTarget, inputTarget: this.itemInputWarehouseTarget, hiddenTarget: this.itemSelectWarehouseTarget, items: this.#warehouseList, labelFn: w => `${w.WhCode} — ${w.WhName}`, valueFn: w => w.WhCode }) }

  onItemAccountInput()   { this.#renderOcAutocomplete({ listTarget: this.itemAccountListTarget, inputTarget: this.itemInputAccountTarget, hiddenTarget: this.itemSelectAccountTarget, items: this.#accountList, labelFn: a => `${a.FormatCode} - ${a.AcctName}`, valueFn: a => a.AcctCode }) }
  onItemAccountFocus()   { this.#closeAllItemDropdowns(this.itemAccountListTarget); this.#renderOcAutocomplete({ listTarget: this.itemAccountListTarget, inputTarget: this.itemInputAccountTarget, hiddenTarget: this.itemSelectAccountTarget, items: this.#accountList, labelFn: a => `${a.FormatCode} - ${a.AcctName}`, valueFn: a => a.AcctCode }) }

  onItemProjectInput()   { this.#renderOcAutocomplete({ listTarget: this.itemProjectListTarget, inputTarget: this.itemInputProjectTarget, hiddenTarget: this.itemSelectProjectTarget, items: this.#projectList, labelFn: p => `${p.Code} - ${p.Name}`, valueFn: p => p.Code }) }
  onItemProjectFocus()   { this.#closeAllItemDropdowns(this.itemProjectListTarget); this.#renderOcAutocomplete({ listTarget: this.itemProjectListTarget, inputTarget: this.itemInputProjectTarget, hiddenTarget: this.itemSelectProjectTarget, items: this.#projectList, labelFn: p => `${p.Code} - ${p.Name}`, valueFn: p => p.Code }) }

  // Artículo SAP
  onOcItemInput()  { this.#renderOcAutocomplete({ listTarget: this.ocItemListTarget, inputTarget: this.ocInputItemTarget, hiddenTarget: this.ocSelectItemTarget, items: this.#itemSAPList, labelFn: i => i.FullName || `${i.ItemCode} - ${i.ItemName}`, valueFn: i => i.ItemCode }) }
  onOcItemFocus()  { this.#closeAllOcDropdowns(this.ocItemListTarget); this.#renderOcAutocomplete({ listTarget: this.ocItemListTarget, inputTarget: this.ocInputItemTarget, hiddenTarget: this.ocSelectItemTarget, items: this.#itemSAPList, labelFn: i => i.FullName || `${i.ItemCode} - ${i.ItemName}`, valueFn: i => i.ItemCode }) }

  // Almacén
  onOcWarehouseInput()  { this.#renderOcAutocomplete({ listTarget: this.ocWarehouseListTarget, inputTarget: this.ocInputWarehouseTarget, hiddenTarget: this.ocSelectWarehouseTarget, items: this.#warehouseList, labelFn: w => `${w.WhCode} — ${w.WhName}`, valueFn: w => w.WhCode }) }
  onOcWarehouseFocus()  { this.#closeAllOcDropdowns(this.ocWarehouseListTarget); this.#renderOcAutocomplete({ listTarget: this.ocWarehouseListTarget, inputTarget: this.ocInputWarehouseTarget, hiddenTarget: this.ocSelectWarehouseTarget, items: this.#warehouseList, labelFn: w => `${w.WhCode} — ${w.WhName}`, valueFn: w => w.WhCode }) }

  // Cuenta SAP
  onOcAccountInput()  { this.#renderOcAutocomplete({ listTarget: this.ocAccountListTarget, inputTarget: this.ocInputAccountTarget, hiddenTarget: this.ocSelectAccountTarget, items: this.#accountList, labelFn: a => `${a.FormatCode} - ${a.AcctName}`, valueFn: a => a.AcctCode }) }
  onOcAccountFocus()  { this.#closeAllOcDropdowns(this.ocAccountListTarget); this.#renderOcAutocomplete({ listTarget: this.ocAccountListTarget, inputTarget: this.ocInputAccountTarget, hiddenTarget: this.ocSelectAccountTarget, items: this.#accountList, labelFn: a => `${a.FormatCode} - ${a.AcctName}`, valueFn: a => a.AcctCode }) }

  // Proyecto
  onOcProjectInput()  { this.#renderOcAutocomplete({ listTarget: this.ocProjectListTarget, inputTarget: this.ocInputProjectTarget, hiddenTarget: this.ocSelectProjectTarget, items: this.#projectList, labelFn: p => `${p.Code} - ${p.Name}`, valueFn: p => p.Code }) }
  onOcProjectFocus()  { this.#closeAllOcDropdowns(this.ocProjectListTarget); this.#renderOcAutocomplete({ listTarget: this.ocProjectListTarget, inputTarget: this.ocInputProjectTarget, hiddenTarget: this.ocSelectProjectTarget, items: this.#projectList, labelFn: p => `${p.Code} - ${p.Name}`, valueFn: p => p.Code }) }

  onCardCodeFocus() {
    const filterValue = this.inputCardCodeTarget.value.toLowerCase()
    const filtered    = filterValue
      ? this.#supplierList.filter(s =>
          s.CardCode?.toLowerCase().includes(filterValue) ||
          s.CardName?.toLowerCase().includes(filterValue)
        )
      : this.#supplierList.slice(0, 20)
    this.#renderSupplierAutocomplete(filtered)
  }

  onCardCodeInput() {
    const filterValue = this.inputCardCodeTarget.value.toLowerCase()
    const filtered    = this.#supplierList.filter(s =>
      s.CardCode?.toLowerCase().includes(filterValue) ||
      s.CardName?.toLowerCase().includes(filterValue)
    )
    this.#renderSupplierAutocomplete(filtered)
  }

  #renderSupplierAutocomplete(suppliers) {
    const list = this.supplierAutocompleteListTarget
    list.innerHTML = ''

    if (!suppliers.length) {
      list.classList.add('hidden')
      return
    }

    suppliers.slice(0, 20).forEach(sup => {
      const item = document.createElement('div')
      item.className = 'px-3 py-2 hover:bg-blue-50 cursor-pointer text-sm'
      item.dataset.testid = `option-${sup.CardCode}`
      item.textContent    = sup.FullName
      item.addEventListener('click', () => this.#selectSupplier(sup))
      list.appendChild(item)
    })

    list.classList.remove('hidden')
  }

  #selectSupplier(sup) {
    this.inputCardCodeTarget.value = sup.FullName
    this.#cardCodeValue            = sup.FullName
    this.#selectedSupplierId       = sup.CardCode
    this.#supplierExtraDays        = sup.ExtraDays ?? 0
    this.supplierAutocompleteListTarget.classList.add('hidden')
    this.errorCardCodeTarget.classList.add('hidden')
    this.#updateDocDueDate()
    this.#updateHeaderFormValidity()
  }

  onTaxDateChange() {
    this.#updateDocDueDate()
  }

  #updateDocDueDate() {
    const taxDateVal = this.inputTaxDateTarget.value
    if (!taxDateVal) return
    const taxDate = new Date(taxDateVal)
    taxDate.setDate(taxDate.getDate() + this.#supplierExtraDays)
    this.inputDocDueDateTarget.value = taxDate.toISOString().split('T')[0]
  }

  setToday(event) {
    const field  = event.currentTarget.dataset.field
    const target = this[`${field}Target`]
    if (target) {
      target.value = new Date().toISOString().split('T')[0]
      if (field === 'inputTaxDate') this.#updateDocDueDate()
    }
  }

  onCommentsInput() {
    this.commentsCharCountTarget.textContent = this.inputCommentsTarget.value.length
  }

  // ── Validez del formulario Cabecera ───────────────────
  #updateHeaderFormValidity() {
    const valid = !!this.#selectedSupplierId

    this.btnCreateDraftTarget.disabled = !valid
    this.btnCreateSapTarget.disabled   = !valid

    if (valid) {
      this.tabBtnLineasTarget.classList.remove('hidden')
      if (this.#xmlDoc2?.DocChargesXMLLines?.length) {
        this.tabBtnOtrosCargosTarget.classList.remove('hidden')
      }
    } else {
      this.tabBtnLineasTarget.classList.add('hidden')
      this.tabBtnOtrosCargosTarget.classList.add('hidden')
    }
  }

  // ── Botón Refrescar ────────────────────────────────────
  refreshData() {
    this.confirmRefreshModalTarget.classList.remove('hidden')
  }

  closeConfirmRefresh() {
    this.confirmRefreshModalTarget.classList.add('hidden')
  }

  confirmRefresh() {
    window.location.reload()
  }

  // ── Panel lateral de selección de ítem ────────────────
  openItemSelection(event) {
    const rowId = Number(event.currentTarget.dataset.rowId)
    const line  = this.#xmlDoc?.DocReceptXMLLines?.find(l => l.RowId === rowId)
    if (!line || (line.Available ?? 0) <= 0) {
      showToast('Esta línea ya está agregada', 'warning')
      return
    }
    this.#openItemSelectionForLine(line)
  }

  #openItemSelectionForLine(line) {
    if ((line.Available ?? 0) <= 0) {
      showToast('Esta línea ya está agregada', 'warning')
      return
    }
    this.#openItemSelectionForLines([line])
  }

  // Abre el panel de selección de ítem para una o varias líneas XML.
  // En modo multi se aplican artículo/almacén/cuenta/proyecto/impuesto comunes y
  // se usa el Disponible de cada línea como cantidad (campo Cantidad oculto).
  #openItemSelectionForLines(lines) {
    const available = (lines ?? []).filter(l => (l.Available ?? 0) > 0)
    if (available.length === 0) {
      showToast('Las líneas seleccionadas ya fueron agregadas completamente', 'warning')
      return
    }

    this.#selectedItemLines = available
    this.#selectedXmlLine   = available[0]
    const isMulti = available.length > 1

    if (!isMulti) {
      const l = available[0]
      this.itemPanelLineInfoTarget.innerHTML =
        `<span class="font-semibold">${l.Code}</span> — ${l.Detail}` +
        `<span class="ml-3 text-blue-600 font-medium">Disponible: ${l.Available}</span>`
      this.itemQuantityTarget.value = l.Available
      this.itemQuantityTarget.max   = l.Available
    } else {
      this.itemPanelLineInfoTarget.innerHTML =
        `<span class="font-semibold">${available.length} líneas seleccionadas</span>` +
        ` — se usará la cantidad disponible de cada una`
    }

    // En multi se oculta la cantidad (se usa el Disponible de cada línea)
    this.itemQuantityRowTarget.classList.toggle('hidden', isMulti)

    this.#openItemPanel()
  }

  cancelItemSelection() {
    this.#selectedXmlLine = null
    this.#closeItemPanel()
  }

  #openItemPanel() {
    this.itemPanelBackdropTarget.classList.remove('hidden')
    this.itemPanelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  #closeItemPanel() {
    this.itemPanelTarget.classList.add('translate-x-full')
    this.itemPanelBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
    // Reset autocomplete inputs
    this.itemInputItemTarget.value       = ''
    this.itemSelectItemTarget.value      = ''
    this.itemInputWarehouseTarget.value  = ''
    this.itemSelectWarehouseTarget.value = ''
    this.itemInputAccountTarget.value    = ''
    this.itemSelectAccountTarget.value   = ''
    this.itemInputProjectTarget.value    = ''
    this.itemSelectProjectTarget.value   = ''
    this.#closeAllItemDropdowns()
    // Reset dimensiones
    ;[this.itemDim1Target, this.itemDim2Target, this.itemDim3Target, this.itemDim4Target, this.itemDim5Target]
      .forEach(el => { el.value = '' })
    this.itemDimBodyTarget.classList.add('hidden')
    this.itemDimIconTarget.style.transform = 'rotate(0deg)'
    // Restaurar visibilidad de Cantidad y limpiar selección multi
    this.itemQuantityRowTarget.classList.remove('hidden')
    this.#selectedItemLines = []
  }

  confirmItemSelection() {
    const lines = this.#selectedItemLines.length
      ? this.#selectedItemLines
      : (this.#selectedXmlLine ? [this.#selectedXmlLine] : [])
    if (lines.length === 0) return

    const isMulti   = lines.length > 1
    const itemCode  = this.itemSelectItemTarget.value
    const whsCode   = this.itemSelectWarehouseTarget.value
    const enteredQty = Number(this.itemQuantityTarget.value)
    const accCode   = this.itemSelectAccountTarget.value
    const prjCode   = this.itemSelectProjectTarget.value

    if (!itemCode || !whsCode) {
      showToast('Complete artículo y almacén', 'warning')
      return
    }
    if (!isMulti && !enteredQty) {
      showToast('Indique la cantidad', 'warning')
      return
    }

    const itemSAP = this.#itemSAPList.find(i => i.ItemCode === itemCode)
    const acc     = this.#accountList.find(a => a.AcctCode === accCode)
    const prj     = this.#projectList.find(p => p.Code === prjCode)

    // Dimensiones comunes del panel (se aplican a todas las líneas)
    const dims = [
      this.itemDim1Target.value, this.itemDim2Target.value, this.itemDim3Target.value,
      this.itemDim4Target.value, this.itemDim5Target.value,
    ]
    const selectedDims = dims.filter(Boolean).join(', ')

    let added = 0
    lines.forEach(line => {
      const quantity = isMulti ? (line.Available ?? 0) : enteredQty
      if (quantity <= 0) return

      const taxEntry = this.#resolveTaxForLine(line)
      const disc     = line.Quantity ? (line.Discount / line.Quantity) * quantity : 0

      const apLine = {
        RowId:          line.RowId,
        TableId:        this.#idItemTable++,
        ItemCode:       itemCode,
        InvtItem:       itemSAP?.InvntItem ?? '',
        SapAccountCode: acc?.AcctCode      ?? '',
        SapAccountName: acc ? `${acc.FormatCode}-${acc.AcctName}` : '',
        ItemCodeXML:    line.Code,
        ItemNameXML:    line.Detail,
        ItemNameEdited: line.Detail,
        LineCurr:       line.DocCur,
        Quantity:       quantity,
        UnitPrice:      line.UnitPrice,
        Disc:           disc,
        TaxCode:        taxEntry.TaxCode,
        TaxRate:        String(line.ImpTarifa ?? 0),
        TaxAmount:      0,
        LineTotal:      0,
        WhsCode:        whsCode,
        Dimension1:  dims[0],
        Dimension2:  dims[1],
        Dimension3:  dims[2],
        Dimension4:  dims[3],
        Dimension5:  dims[4],
        SelectedDimensions: selectedDims,
        IsSelected:     false,
        XmlUndMed:      line.XmlUndMed      ?? '',
        XmlUndMedComercial: line.XmlUndMedComercial ?? '',
        XmlCodType:     line.XmlCodType     ?? '',
        ProjectCode:    prjCode,
        ProjectName:    prj ? `${prj.Code}-${prj.Name}` : '',
      }

      apLine.TaxAmount = ((apLine.UnitPrice * quantity) - disc) * (Number(apLine.TaxRate) / 100)
      apLine.LineTotal = ((apLine.UnitPrice * quantity) - disc) + apLine.TaxAmount

      this.#apInvoiceLines.push(apLine)
      line.Available = (line.Available - quantity)
      added++
    })

    if (added === 0) {
      showToast('No se agregó ninguna línea', 'warning')
      return
    }

    this.#renderXmlLinesTable()
    this.#renderSapLinesTable()
    this.#renderApInvoiceLinesHeader()
    this.#calculateTotals()
    this.#xmlLinesTabulator?.deselectRow()
    this.#closeItemPanel()
    this.#selectedXmlLine   = null
    this.#selectedItemLines = []
  }

  #resolveTaxForLine(xmlLine) {
    const impTarifa = xmlLine.ImpTarifa ?? 0
    const match     = this.#taxCodeList.find(t =>
      Number(t.TaxRate ?? t.Percent ?? 0) === Number(impTarifa)
    )
    return match ? { TaxCode: match.TaxCode } : { TaxCode: this.#defaultTaxForXML }
  }

  // ── Match automático ──────────────────────────────────
  // Porta AddAutomaticLines del legacy (lines.component.ts):
  // consulta /api/Documents/MatchAutomatic con las líneas del XML y, por cada
  // línea que el backend devuelve ya mapeada a un ItemCode de SAP disponible,
  // agrega automáticamente la línea a la tabla de envío a SAP con su cuenta,
  // dimensiones, impuesto y cantidad pre-seleccionados.
  async #addAutomaticLines() {
    const xmlLines = this.#xmlDoc?.DocReceptXMLLines ?? []
    if (xmlLines.length === 0) return

    const cardCode   = this.inputCardCodeTarget.value.split(' - ')[0].trim()
    const pocl24     = this.inputRefDocEntryTarget.value || ''
    const docBaseType = Number(this.selectRefDocTypeTarget.value) || 0

    const payload = {
      CardCode:      cardCode,
      CompanyId:     this.#companyId,
      POCL24:        pocl24,
      DocBaseType:   docBaseType,
      DocumentsLines: xmlLines.map(x => this.#toMatchAutoLine(x)),
    }

    this.#showLoading('Buscando líneas mapeadas...')
    let res
    try {
      res = await this.#apiFetch('/api/Documents/MatchAutomatic', {
        method: 'POST',
        body:   JSON.stringify(payload),
      })
    } catch (err) {
      this.#hideLoading()
      showToast(`Error al obtener las líneas automáticas: ${err.message}`, 'error')
      return
    }
    this.#hideLoading()

    const matchedLines = res?.Data?.DocumentsLines
    if (!Array.isArray(matchedLines)) {
      showToast(res?.Message || 'Se produjo un error al obtener las líneas para realizar el match', 'warning')
      return
    }

    let added = 0
    matchedLines.forEach(line => {
      const itemSAP = this.#itemSAPList.find(i => i.ItemCode === line.ItemCode)
      if (!itemSAP || !(line.Available > 0) || !line.ItemCode) return

      // Cuenta automática por FormatCode
      let selectedAcc = null
      if (line.FormatCode && line.FormatCode > 0) {
        selectedAcc = this.#accountList.find(a => a.FormatCode === line.FormatCode) ?? null
      }

      // Dimensiones automáticas (solo si están configuradas en SAP)
      const d1 = this.#resolveDimensionAuto(line.Dimension1, 1)
      const d2 = this.#resolveDimensionAuto(line.Dimension2, 2)
      const d3 = this.#resolveDimensionAuto(line.Dimension3, 3)
      const d4 = this.#resolveDimensionAuto(line.Dimension4, 4)
      const d5 = this.#resolveDimensionAuto(line.Dimension5, 5)
      const selectedDim = [d1, d2, d3, d4, d5]
        .filter(d => d.valid)
        .map(d => d.tooltip)
        .join('')

      const fullName  = itemSAP.FullName ?? `${itemSAP.ItemCode}`
      const quantity  = Number(line.Quantity) || 0
      const unitPrice = Number(line.UnitPrice) || 0
      const discount  = Number(line.Discount) || 0
      const taxEntry  = line.TaxCode ? { TaxCode: line.TaxCode } : this.#resolveTaxForLine(line)
      const taxRate   = Number(line.ImpTarifa ?? 0)

      const apLine = {
        RowId:          line.RowId,
        TableId:        this.#idItemTable++,
        ItemCode:       fullName.split('-')[0],
        InvtItem:       itemSAP.InvntItem ?? '',
        SapAccountCode: selectedAcc ? selectedAcc.AcctCode : '',
        SapAccountName: selectedAcc ? `${selectedAcc.FormatCode}-${selectedAcc.AcctName}` : '',
        ItemCodeXML:    line.Code,
        ItemNameXML:    line.Detail,
        ItemNameEdited: line.Detail,
        LineCurr:       line.DocCur,
        Quantity:       quantity,
        UnitPrice:      unitPrice,
        Disc:           discount,
        TaxCode:        taxEntry.TaxCode,
        TaxRate:        String(taxRate),
        TaxAmount:      0,
        LineTotal:      0,
        WhsCode:        line.DfltWH ?? '',
        Dimension1:     d1.valid ? line.Dimension1 : '',
        Dimension2:     d2.valid ? line.Dimension2 : '',
        Dimension3:     d3.valid ? line.Dimension3 : '',
        Dimension4:     d4.valid ? line.Dimension4 : '',
        Dimension5:     d5.valid ? line.Dimension5 : '',
        SelectedDimensions: selectedDim,
        IsSelected:     false,
        XmlUndMed:          line.XmlUndMed          ?? '',
        XmlUndMedComercial: line.XmlUndMedComercial ?? '',
        XmlCodType:         line.XmlCodType         ?? '',
        ProjectCode:    '',
        ProjectName:    '',
        BaseLine:       line.BaseLine,
        BaseEntry:      line.BaseEntry,
        BaseType:       line.BaseType,
        OpenQty:        line.OpenQty,
        MedicineRegistration: line.MedicineRegistration,
        PharmaceuticalForm:   line.PharmaceuticalForm,
      }

      // Cálculo de impuesto y total (consistente con confirmItemSelection)
      apLine.TaxAmount = ((unitPrice * quantity) - discount) * (taxRate / 100)
      apLine.LineTotal = ((unitPrice * quantity) - discount) + apLine.TaxAmount

      this.#apInvoiceLines.push(apLine)
      added++

      // Marcar la línea XML como ya consumida (Available = 0)
      const xmlLine = this.#xmlDoc?.DocReceptXMLLines?.find(l => l.RowId === line.RowId)
      if (xmlLine) xmlLine.Available = 0

      // Reflejar también en los cargos del XML si corresponde
      const chargeLine = this.#xmlDoc2?.DocChargesXMLLines?.find(l => l.RowId === line.RowId)
      if (chargeLine) chargeLine.Available = 0
    })

    if (added > 0) {
      this.#renderXmlLinesTable()
      this.#renderSapLinesTable()
      this.#renderApInvoiceLinesHeader()
      this.#calculateTotals()
    } else {
      showToast('No se encontraron líneas para cargar automáticamente', 'info')
    }
  }

  // Mapea una línea del XML al shape DocReceptXMLInfoLines que espera MatchAutomatic
  #toMatchAutoLine(x) {
    return {
      RowId:        x.RowId,
      Code:         x.Code,
      Detail:       x.Detail,
      DocCur:       x.DocCur,
      Quantity:     x.Quantity,
      UnitPrice:    x.UnitPrice,
      Discount:     x.Discount,
      TaxAmount:    x.TaxAmount,
      ImpTarifa:    x.ImpTarifa ?? 0,
      TotalLine:    x.TotalLine,
      TaxCode:      x.TaxCode,
      Selected:     x.Selected,
      IsMatchSelected: x.IsMatchSelected,
      Available:    x.Available,
      Dimension1:   x.Dimension1,
      Dimension2:   x.Dimension2,
      Dimension3:   x.Dimension3,
      Dimension4:   x.Dimension4,
      Dimension5:   x.Dimension5,
      SelectedDimensions: x.SelectedDimensions,
      IsSelected:   x.IsSelected,
      XmlCodType:   x.XmlCodType,
      XmlUndMed:    x.XmlUndMed,
      XmlUndMedComercial: x.XmlUndMedComercial ?? '',
      FormatCode:   x.FormatCode,
      BaseLine:     x.BaseLine,
      BaseEntry:    x.BaseEntry,
      BaseType:     x.BaseType,
      OpenQty:      x.OpenQty,
      MedicineRegistration: x.MedicineRegistration,
      PharmaceuticalForm:   x.PharmaceuticalForm,
    }
  }

  // Valida una dimensión automática contra las dimensiones configuradas en SAP.
  // Retorna { valid, name, tooltip } — replica AddDimensionsAtumatic del legacy.
  #resolveDimensionAuto(prcCode, dimCode) {
    if (!prcCode) return { valid: false, name: '', tooltip: '' }
    const dim = this.#dimensionList.find(d => Number(d.DimCode) === Number(dimCode))
    const cc  = dim?.CenterCost?.find(c => c.PrcCode === prcCode)
    if (!cc) return { valid: false, name: '', tooltip: '' }
    return { valid: true, name: cc.PrcName, tooltip: `Dimension ${dimCode}: ${cc.PrcName}; ` }
  }

  // ── Otros Cargos — panel lateral ──────────────────────
  #openOcSelectionForLines(lines) {
    const available = lines.filter(l => (l.Available ?? 0) > 0)
    if (available.length === 0) {
      showToast('Las líneas seleccionadas ya fueron agregadas completamente', 'warning')
      return
    }

    this.#selectedOcLines = available
    const isMulti = available.length > 1

    // Info de línea(s)
    if (!isMulti) {
      const l = available[0]
      this.ocPanelLineInfoTarget.innerHTML =
        `<span class="font-semibold">${l.Code}</span> — ${l.Detail}` +
        `<span class="ml-3 text-blue-600 font-medium">Disponible: ${l.Available}</span>`
      this.ocQuantityTarget.value = l.Available
      this.ocQuantityTarget.max   = l.Available
    } else {
      this.ocPanelLineInfoTarget.innerHTML =
        `<span class="font-semibold">${available.length} líneas seleccionadas</span>` +
        ` — se usará la cantidad disponible de cada una`
    }

    // Cantidad: solo en modo 1, y ocultar si es multi-selección
    const isMode1 = this.#freightChargesMode === 1
    this.ocQuantityRowTarget.classList.toggle('hidden', !isMode1 || isMulti)

    // Campos exclusivos de modo 1 (Artículo, Almacén, Cuenta, Proyecto, Impuesto)
    this.ocMode1FieldsTarget.classList.toggle('hidden', !isMode1)
    // Campos exclusivos de modo 2 (Cargo adicional SAP)
    this.ocMode2FieldsTarget.classList.toggle('hidden', isMode1)

    // Reset campos autocomplete
    this.ocInputItemTarget.value      = '';  this.ocSelectItemTarget.value      = ''
    this.ocInputWarehouseTarget.value = '';  this.ocSelectWarehouseTarget.value = ''
    this.ocInputTaxCodeTarget.value   = '';  this.ocSelectTaxCodeTarget.value   = ''
    this.ocInputAccountTarget.value   = '';  this.ocSelectAccountTarget.value   = ''
    this.ocInputProjectTarget.value   = '';  this.ocSelectProjectTarget.value   = ''
    this.ocSelectFreightTarget.value  = ''
    this.#closeAllOcDropdowns()

    // Pre-seleccionar impuesto por ImpTarifa de la primera línea
    const resolved = this.#resolveTaxForLine(available[0])
    if (resolved.TaxCode) {
      const taxObj = this.#taxCodeList.find(t => t.TaxCode === resolved.TaxCode)
      if (taxObj) {
        this.ocInputTaxCodeTarget.value  = `${taxObj.TaxCode} (${taxObj.TaxRate}%)`
        this.ocSelectTaxCodeTarget.value = taxObj.TaxCode
      }
    }

    // Reset dimensiones
    ;[this.ocDim1Target, this.ocDim2Target, this.ocDim3Target, this.ocDim4Target, this.ocDim5Target]
      .forEach(el => { el.value = '' })
    this.ocDimBodyTarget.classList.add('hidden')
    this.ocDimIconTarget.style.transform = 'rotate(0deg)'

    this.ocPanelBackdropTarget.classList.remove('hidden')
    this.ocPanelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  // ── Panel edición de dimensiones post-agregado ────────
  #openDimEditPanel(type, id, rowData) {
    this.#dimEditContext = { type, id }

    // Info de la fila
    const label = type === 'item'
      ? `${rowData.ItemCodeXML} — ${rowData.ItemNameEdited}`
      : type === 'sap'
        ? `${rowData.ItemCodeXML} — ${rowData.ItemNameEdited}`
        : `${rowData.ExpenseCode} — ${rowData.Remarks}`
    this.dimEditLineInfoTarget.textContent = label

    // Poblar selects desde #dimensionList y pre-seleccionar valores actuales
    this.#dimensionList.forEach(dim => {
      const code     = dim.DimCode   // 1-5
      const rowEl    = this[`dimEditRow${code}Target`]
      const selEl    = this[`dimEdit${code}Target`]
      if (!rowEl || !selEl) return

      const label = rowEl.querySelector('label')
      if (label) label.textContent = dim.DimName || `Dimensión ${code}`

      // Poblar solo si aún vacío
      if (selEl.options.length === 0) {
        const blank = document.createElement('option')
        blank.value = ''; blank.textContent = 'Ninguna'
        selEl.appendChild(blank)
        dim.CenterCost?.forEach(cc => {
          const opt = document.createElement('option')
          opt.value = cc.PrcCode
          opt.textContent = `${cc.PrcCode} - ${cc.PrcName}`
          selEl.appendChild(opt)
        })
      }

      // Pre-seleccionar valor actual
      const currentVal = (type === 'item' || type === 'sap')
        ? rowData[`Dimension${code}`]
        : rowData[`DistributionRule${code > 1 ? code : ''}`]
      selEl.value = currentVal ?? ''

      rowEl.classList.remove('hidden')
    })

    this.dimEditBackdropTarget.classList.remove('hidden')
    this.dimEditPanelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  saveDimEdit() {
    const { type, id } = this.#dimEditContext ?? {}
    if (!type || id === undefined) return

    const dims = [1,2,3,4,5].map(i => this[`dimEdit${i}Target`]?.value ?? '')
    const selectedDimensions = dims.filter(Boolean).join(', ')

    if (type === 'item') {
      const line = this.#apInvoiceLines.find(l => l.TableId === id)
      if (line) {
        line.Dimension1 = dims[0]; line.Dimension2 = dims[1]; line.Dimension3 = dims[2]
        line.Dimension4 = dims[3]; line.Dimension5 = dims[4]
        line.SelectedDimensions = selectedDimensions
        this.#renderSapLinesTable()
      }
    } else if (type === 'sap') {
      const line = this.#ocApLines.find(l => l.TableId === id)
      if (line) {
        line.Dimension1 = dims[0]; line.Dimension2 = dims[1]; line.Dimension3 = dims[2]
        line.Dimension4 = dims[3]; line.Dimension5 = dims[4]
        line.SelectedDimensions = selectedDimensions
        this.#renderOcApLinesTable()
      }
    } else {
      const charge = this.#otherChargeLines.find(c => c.ExpenseCode === id)
      if (charge) {
        charge.DistributionRule  = dims[0]; charge.DistributionRule2 = dims[1]
        charge.DistributionRule3 = dims[2]; charge.DistributionRule4 = dims[3]
        charge.DistributionRule5 = dims[4]
        charge.SelectedDimensions = selectedDimensions
        this.#renderOcChargesTable()
      }
    }

    this.cancelDimEdit()
  }

  cancelDimEdit() {
    this.#dimEditContext = null
    this.dimEditPanelTarget.classList.add('translate-x-full')
    this.dimEditBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
  }

  toggleItemDimensions() {
    const body   = this.itemDimBodyTarget
    const icon   = this.itemDimIconTarget
    const hidden = body.classList.toggle('hidden')
    icon.style.transform = hidden ? 'rotate(0deg)' : 'rotate(90deg)'
  }

  toggleOcDimensions() {
    const body    = this.ocDimBodyTarget
    const icon    = this.ocDimIconTarget
    const hidden  = body.classList.toggle('hidden')
    icon.style.transform = hidden ? 'rotate(0deg)' : 'rotate(90deg)'
  }

  // Botón "Agregar seleccionados" en toolbar (acción pública Stimulus)
  addSelectedOcLines() {
    const selectedRows = this.#otrosCargosTabulator?.getSelectedRows() ?? []
    if (selectedRows.length === 0) {
      showToast('Seleccione al menos una línea', 'warning')
      return
    }
    const lines = selectedRows.map(r => {
      return this.#xmlDoc2?.DocChargesXMLLines?.find(l => l.RowId === r.getData().RowId)
    }).filter(Boolean)
    this.#openOcSelectionForLines(lines)
  }

  cancelOcSelection() {
    this.#selectedOcLines = []
    this.#closeAllOcDropdowns()
    this.ocPanelTarget.classList.add('translate-x-full')
    this.ocPanelBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
  }

  confirmOcSelection() {
    const lines = this.#selectedOcLines
    if (!lines.length) return

    const isMulti   = lines.length > 1
    const taxCode   = this.ocSelectTaxCodeTarget.value
    const accCode   = this.ocSelectAccountTarget.value
    const prjCode   = this.ocSelectProjectTarget.value
    const itemCode  = this.ocSelectItemTarget.value
    const whsCode   = this.ocSelectWarehouseTarget.value
    const acc       = this.#accountList.find(a => a.AcctCode === accCode)
    const prj       = this.#projectList.find(p => p.Code === prjCode)
    const itemSAP   = this.#itemSAPList.find(i => i.ItemCode === itemCode)
    const taxObj    = this.#taxCodeList.find(t => t.TaxCode === taxCode)
    const taxRate   = Number(taxObj?.TaxRate ?? 0)
    const dims      = [
      this.ocDim1Target.value,
      this.ocDim2Target.value,
      this.ocDim3Target.value,
      this.ocDim4Target.value,
      this.ocDim5Target.value,
    ]
    const selectedDims = dims.filter(Boolean).join(', ')

    // Validaciones modo 1
    if (this.#freightChargesMode === 1) {
      if (!itemCode) { showToast('Seleccione un artículo SAP', 'warning'); return }
      if (!whsCode)  { showToast('Seleccione un almacén', 'warning');     return }
    }

    // Validar cantidad solo para selección individual
    if (!isMulti) {
      const qty = Number(this.ocQuantityTarget.value)
      if (!qty || qty <= 0) { showToast('La cantidad debe ser mayor a 0', 'warning'); return }
    }

    lines.forEach(line => {
      const quantity  = isMulti ? line.Available : Number(this.ocQuantityTarget.value)
      const disc      = (line.Discount / Math.max(line.Quantity, 1)) * quantity
      const taxAmount = ((line.UnitPrice * quantity) - disc) * (taxRate / 100)
      const lineTotal = ((line.UnitPrice * quantity) - disc) + taxAmount

      if (this.#freightChargesMode === 1) {
        // ── Modo 1: DocumentAPInvoiceLines ──
        const apLine = {
          RowId:          line.RowId,
          TableId:        this.#idItemTable++,
          ItemCode:       itemCode,
          InvtItem:       itemSAP?.InvntItem ?? '',
          SapAccountCode: acc?.AcctCode ?? '',
          SapAccountName: acc ? `${acc.FormatCode}-${acc.AcctName}` : '',
          ItemCodeXML:    line.Code,
          ItemNameXML:    line.Detail,
          ItemNameEdited: line.Detail,
          LineCurr:       line.DocCur ?? this.#docCurrency,
          Quantity:       quantity,
          UnitPrice:      line.UnitPrice,
          Disc:           disc,
          TaxCode:        taxCode,
          TaxRate:        String(taxRate),
          TaxAmount:      taxAmount,
          LineTotal:      lineTotal,
          WhsCode:        whsCode,
          Dimension1:     dims[0], Dimension2: dims[1], Dimension3: dims[2],
          Dimension4:     dims[3], Dimension5: dims[4],
          SelectedDimensions: selectedDims,
          IsSelected:     false,
          XmlUndMed:      line.XmlUndMed          ?? '',
          XmlUndMedComercial: line.XmlUndMedComercial ?? '',
          XmlCodType:     line.XmlCodType          ?? '',
          ProjectCode:    prjCode,
          ProjectName:    prj ? `${prj.Code}-${prj.Name}` : '',
        }
        this.#apInvoiceLines.push(apLine)
        this.#ocApLines.push(apLine)

      } else {
        // ── Modo 2: ChargesAPInvoiceBase ──
        // ExpenseCode viene del select de cargos adicionales seleccionado por el usuario
        const expenseCode = Number(this.ocSelectFreightTarget.value || 0)
        if (!expenseCode) { showToast('Seleccione un cargo adicional SAP', 'warning'); return }
        const existing    = this.#otherChargeLines.find(c => c.ExpenseCode === expenseCode)

        if (existing) {
          existing.LineTotal         = Number((existing.LineTotal + lineTotal).toFixed(2))
          existing.OriginalLineTotal = existing.LineTotal
          existing.TaxCode           = taxCode
          // Registrar row asociada para poder restaurar Available al eliminar
          existing._xmlRowIds = [...(existing._xmlRowIds ?? []), { rowId: line.RowId, qty: quantity }]
        } else {
          this.#otherChargeLines.push({
            ExpenseCode:       expenseCode,
            Remarks:           line.Detail ?? '',
            TaxCode:           taxCode,
            LineTotal:         Number(lineTotal.toFixed(2)),
            OriginalLineTotal: Number(lineTotal.toFixed(2)),
            DistributionRule:  dims[0],
            DistributionRule2: dims[1],
            DistributionRule3: dims[2],
            DistributionRule4: dims[3],
            DistributionRule5: dims[4],
            IsSelected:        false,
            SelectedDimensions: selectedDims,
            _xmlRowIds:        [{ rowId: line.RowId, qty: quantity }],
          })
        }
      }

      line.Available = (line.Available - quantity)
    })

    this.#renderOtrosCargosTable()
    if (this.#freightChargesMode === 1) {
      this.#renderOcApLinesTable()
    } else {
      this.#renderOcChargesTable()
    }
    this.#renderSapLinesTable()
    this.#renderApInvoiceLinesHeader()
    this.#calculateTotals()

    this.#otrosCargosTabulator?.deselectRow()
    this.cancelOcSelection()
  }

  // ── Eliminación en tablas Otros Cargos ────────────────
  #removeOcApLine(tableId) {
    const idx = this.#ocApLines.findIndex(l => l.TableId === tableId)
    if (idx < 0) return
    const line = this.#ocApLines[idx]

    // Restaurar disponible en la línea XML de origen
    const xmlChargeLine = this.#xmlDoc2?.DocChargesXMLLines?.find(l => l.RowId === line.RowId)
    if (xmlChargeLine) xmlChargeLine.Available += line.Quantity

    this.#ocApLines.splice(idx, 1)
    const mainIdx = this.#apInvoiceLines.findIndex(l => l.TableId === tableId)
    if (mainIdx >= 0) this.#apInvoiceLines.splice(mainIdx, 1)

    this.#renderOtrosCargosTable()
    this.#renderOcApLinesTable()
    this.#renderSapLinesTable()
    this.#renderApInvoiceLinesHeader()
    this.#calculateTotals()
  }

  #removeOcCharge(expenseCode) {
    const idx = this.#otherChargeLines.findIndex(c => c.ExpenseCode === expenseCode)
    if (idx < 0) return
    const charge = this.#otherChargeLines[idx]

    // Restaurar Available en cada línea XML que aportó a este cargo
    ;(charge._xmlRowIds ?? []).forEach(({ rowId, qty }) => {
      const xmlLine = this.#xmlDoc2?.DocChargesXMLLines?.find(l => l.RowId === rowId)
      if (xmlLine) xmlLine.Available = (xmlLine.Available ?? 0) + qty
    })

    this.#otherChargeLines.splice(idx, 1)

    this.#renderOtrosCargosTable()
    this.#renderOcChargesTable()
    this.#calculateTotals()
  }

  // ── Totales ────────────────────────────────────────────
  #calculateTotals() {
    let subTotal = 0, descuento = 0, impuestos = 0, total = 0, otrosCargos = 0

    this.#apInvoiceLines.forEach(line => {
      subTotal  += line.UnitPrice * line.Quantity
      descuento += line.Disc
      impuestos += line.TaxAmount
    })

    this.#otherChargeLines.forEach(line => { otrosCargos += line.LineTotal ?? 0 })

    total = (subTotal - descuento) + impuestos + otrosCargos

    this.totalsSubtotalTarget.textContent    = this.#fmtMoney(subTotal,    this.#docCurrency)
    this.totalsImpuestosTarget.textContent   = this.#fmtMoney(impuestos,   this.#docCurrency)
    this.totalsDescuentoTarget.textContent   = this.#fmtMoney(descuento,   this.#docCurrency)
    this.totalsOtrosCargosTarget.textContent = this.#fmtMoney(otrosCargos, this.#docCurrency)
    this.totalsTotalTarget.textContent       = this.#fmtMoney(total,        this.#docCurrency)

    this.#currentTotal      = total
    this.#currentSubTotal   = subTotal
    this.#currentDescuento  = descuento
    this.#currentImpuestos  = impuestos
    this.#currentOtrosCargos= otrosCargos
  }

  #currentTotal       = 0
  #currentSubTotal    = 0
  #currentDescuento   = 0
  #currentImpuestos   = 0
  #currentOtrosCargos = 0

  // ── Validación de UDFs ─────────────────────────────────
  #validateUdfs() {
    let valid = true
    this.#mappedUdfs = []

    this.#dynamicUdfs.forEach(udf => {
      const el  = this.udfsContainerTarget.querySelector(`[data-udf-name="${udf.Name}"]`)
      const val = el?.value ?? ''

      if (!val && udf.IsRequired) {
        showToast('Faltan datos requeridos en UDFs', 'warning')
        valid = false
      }

      this.#mappedUdfs.push({ Name: udf.Name, Value: val })
    })

    return valid
  }

  // ── Validación tolerancia ──────────────────────────────
  async #totalIsValid() {
    if (!this.#xmlDoc?.TotalFactura) return true

    const docCur   = this.#xmlDoc.DocCur ?? ''
    const tolerance= this.#xmlToleranceAmounts.find(t => t.CurrencyCode === docCur)

    if (tolerance !== undefined || !this.#xmlToleranceAmounts.length) {
      return this.#validateTotalRange(tolerance?.Tolerance ?? 0, docCur)
    }

    // Moneda sin tolerancia → abrir modal
    const selected = await this.#openToleranceModal(docCur)
    if (!selected) return false
    return this.#validateTotalRange(selected.Tolerance, docCur)
  }

  #validateTotalRange(tolerance, docCur) {
    const xmlTotal = this.#xmlDoc.TotalFactura
    const high     = xmlTotal + tolerance
    const low      = Math.max(0, xmlTotal - tolerance)

    if (this.#currentTotal >= low && this.#currentTotal <= high) return true

    showToast(
      `El monto de la factura (${this.#fmtMoney(this.#currentTotal, docCur)}) no coincide con el XML (${this.#fmtMoney(xmlTotal, docCur)}). Tolerancia: ${tolerance}`,
      'warning'
    )
    return false
  }

  // ── Crear factura ──────────────────────────────────────
  async createDraft()  { await this.#doCreate(true)  }
  async createInSap()  { await this.#doCreate(false) }
  cancel()             { Turbo.visit('/documents/receptions') }

  async #doCreate(isDraft) {
    if (!this.#selectedSupplierId) {
      showToast('El formulario contiene errores: proveedor requerido', 'warning')
      return
    }

    if (this.#docTypeXML !== DOC_TYPE_FACTURA) {
      showToast('Solo se pueden crear facturas desde este módulo', 'warning')
      return
    }

    if (!this.#validateUdfs()) return

    const totalValid = await this.#totalIsValid()
    if (!totalValid) return

    const receptAndCreate = this.#sendReceptAndApInv && this.#shouldRecept
    if (receptAndCreate && !this.#errorOnCreate) {
      if (!this.#validateReceptForm()) {
        showToast('Verificar la información de la recepción, existen datos pendientes', 'warning')
        return
      }
    }

    this.#showLoading('Creando factura, espere por favor...')

    try {
      const payload = this.#buildPayload(isDraft)

      if (receptAndCreate && !this.#errorOnCreate) {
        await this.#submitWithRecept(payload)
      } else {
        await this.#submitAPInvoiceOnly(payload, isDraft)
      }
    } catch (err) {
      this.#hideLoading()
      showAlert({ type: ALERT_TYPES.ERROR, title: 'Error al crear la factura', message: err.message || 'Error al crear la factura' })
    }
  }

  async #submitAPInvoiceOnly(payload, isDraft) {
    const response = await this.#apiFetch('/api/documents/ap-invoices', {
      method: 'POST',
      body:   JSON.stringify(payload),
    })
    this.#hideLoading()

    if (response?.Data) {
      const msg = response.Message
        ? response.Message
        : `Documento número ${response.Data.DocNum} creado correctamente`
      this.#showSuccess(msg)
    } else {
      showAlert({ type: ALERT_TYPES.WARNING, title: 'Aviso', message: response?.Message ?? 'Error desconocido' })
    }
  }

  async #submitWithRecept(payload) {
    // Convertir payload a CreateReceptAndApInv
    const bandejaReceptor  = this.#previewDocument?.Reception?.BandejaReceptor ?? ''
    const feToken          = JSON.parse(sessionStorage.getItem('currentFEUser') || '{}')?.access_token ?? ''
    const userId           = this.#session.UserId ?? ''

    const receptAndApInvPayload = {
      APInvoice: {
        ...payload.APInvoice,
        U_APEmail_FE: bandejaReceptor,
      },
      CompanyId: payload.CompanyId,
      UpdateConsecutivoDoc: {
        docId:  this.#docId,
        feToken,
        docnum: 0,
      },
      Reception: {
        Recepcion: this.#buildReception(userId),
        editInfo:  false,
      },
    }

    const response = await this.#apiFetch('/api/documents/ap-invoices-with-recept', {
      method: 'POST',
      body:   JSON.stringify(receptAndApInvPayload),
    })
    this.#hideLoading()

    if (!response?.Data) {
      this.#errorOnCreate = true
      showToast(`Error: ${response?.Message ?? 'Error desconocido'}`, 'error')
      return
    }
    if (!response.Data.Reception) {
      showToast(`Error: ${response?.Message}`, 'error')
      return
    }
    if (!response.Data.ApInvoiceResponse) {
      this.#errorOnCreate = true
      showToast(`Recepción creada #${response.Data.Reception.AcceptId} pero error en factura: ${response.Message}`, 'warning')
      return
    }

    const msg = response.Message
      ? response.Message
      : `Documentos creados: recepción #${response.Data.Reception.AcceptId}, factura #${response.Data.ApInvoiceResponse.DocNum}`
    this.#showSuccess(msg)
  }

  #buildPayload(isDraft) {
    const cardCode = this.inputCardCodeTarget.value.split(' - ')[0].trim()

    const apInvoice = {
      CardCode:    cardCode,
      CardName:    this.inputCardNameTarget.value,
      DocCur:      this.inputDocCurTarget.value,
      NumAtCard:   this.inputNumAtCardTarget.value,
      DocDate:     this.inputDocDateTarget.value    || null,
      DocDueDate:  this.inputDocDueDateTarget.value || null,
      TaxDate:     this.inputTaxDateTarget.value    || null,
      Comments:    this.inputCommentsTarget.value,
      RefDocType:  Number(this.selectRefDocTypeTarget.value) || 0,
      DocBaseList: this.#selectedDocEntry ? [this.#selectedDocEntry] : [],
      APInvoiceLines: this.#apInvoiceLines,
      TotalFactura: 0,
      SupplierGetModel: '',
      LicTradNum:  '',
      U_APEmail_FE: '',
      MappedUdfs:  this.#mappedUdfs,
      DocumentAdditionalExpenses: this.#otherChargeLines,
      DocObjectCode: isDraft ? 'oPurchaseInvoices' : '',
      DocumentReferences: this.#selectedDocEntry ? [{
        RefObjType: Number(this.selectRefDocTypeTarget.value),
        RefDocEntr: this.#selectedDocEntry,
      }] : undefined,
      CloseRefDocument: !isDraft && this.#closeRefDocument,
    }

    const feToken = JSON.parse(sessionStorage.getItem('currentFEUser') || '{}')?.access_token ?? ''

    return {
      APInvoice: apInvoice,
      CompanyId: parseInt(this.#companyId),
      UpdateConsecutivoDoc: {
        docId:  this.#docId,
        feToken,
        docnum: 0,
      },
    }
  }

  #buildReception(userId) {
    return {
      Id:               this.#docId,
      Mensaje:          parseInt(this.receptMensajeTarget.value) || 0,
      DetalleMensaje:   this.receptDetalleMensajeTarget.value,
      Sucursal:         1,
      Terminal:         1,
      CompanyId:        parseInt(this.#companyId),
      CondicionImpuesto:this.receptCondicionImpuestoTarget.value,
      TaxFactor:        this.receptTaxFactorTarget.value,
      CodigoActividad:  this.receptCodigoActividadTarget.value,
      UserId:           userId,
    }
  }

  #populateActivitySelect() {
    if (!this.hasReceptCodigoActividadTarget) return
    const sel = this.receptCodigoActividadTarget
    const current = sel.value
    sel.innerHTML = '<option value="">-- Seleccione --</option>'
    // El popup nativo del <select> se ensancha hasta la opción más larga; un
    // nombre de actividad largo desborda el panel hacia la izquierda. Se trunca
    // el nombre en la etiqueta (el código queda íntegro) y el completo va en `title`.
    const MAX = 45
    this.#activityCodes.forEach(a => {
      const code = a.Code ?? a.code ?? ''
      const name = a.Name ?? a.Description ?? a.name ?? ''
      const short = name.length > MAX ? `${name.slice(0, MAX).trimEnd()}…` : name
      const opt  = document.createElement('option')
      opt.value       = code
      opt.textContent = `${code} - ${short}`
      opt.title       = `${code} - ${name}`
      sel.appendChild(opt)
    })
    if (current) sel.value = current
    if (!sel.value && this.#activityCodes.length === 1) {
      sel.value = this.#activityCodes[0].Code ?? this.#activityCodes[0].code ?? ''
    }
  }

  #validateReceptForm() {
    if (!this.#shouldRecept) return true
    const msg     = this.receptMensajeTarget.value
    const codigo  = this.receptCodigoActividadTarget.value
    const detalle = this.receptDetalleMensajeTarget.value.trim()

    // DetalleMensaje: requerido según el tipo de mensaje + longitud.
    // El mínimo de 5 caracteres solo aplica cuando se ingresó texto.
    let detalleValid = true
    if (DETAIL_REQUIRED_MESSAGES.has(msg) && !detalle) {
      this.errorReceptDetalleMensajeTarget.textContent = 'El detalle del mensaje es requerido para esta respuesta.'
      this.errorReceptDetalleMensajeTarget.classList.remove('hidden')
      detalleValid = false
    } else if (detalle && detalle.length < DETAIL_MIN_LENGTH) {
      this.errorReceptDetalleMensajeTarget.textContent = `El detalle del mensaje debe tener al menos ${DETAIL_MIN_LENGTH} caracteres.`
      this.errorReceptDetalleMensajeTarget.classList.remove('hidden')
      this.#updateReceptDetalleCounter()
      detalleValid = false
    } else {
      this.errorReceptDetalleMensajeTarget.classList.add('hidden')
    }

    return !!msg && codigo.length === 6 && detalleValid
  }

  // ── Modal de moneda mismatch ───────────────────────────
  #openCurrencyMismatchModal(xmlCode) {
    return new Promise(resolve => {
      this.#currencyResolve = resolve
      this.currencyMismatchXmlCodeTarget.textContent = xmlCode

      const select = this.currencyMismatchSelectTarget
      select.innerHTML = '<option value="">-- Seleccione --</option>'
      this.#companyCurrencies.forEach(c => {
        const opt       = document.createElement('option')
        opt.value       = c.Code
        opt.textContent = `${c.Code} — ${c.Name}`
        select.appendChild(opt)
      })

      this.currencyMismatchModalTarget.classList.remove('hidden')
    })
  }

  confirmCurrencyMismatch() {
    const code = this.currencyMismatchSelectTarget.value
    const save = this.currencyMismatchSaveTarget.checked
    this.currencyMismatchModalTarget.classList.add('hidden')
    this.#currencyResolve?.({ code, save })
    this.#currencyResolve = null
  }

  cancelCurrencyMismatch() {
    this.currencyMismatchModalTarget.classList.add('hidden')
    this.#currencyResolve?.({ code: null, save: false })
    this.#currencyResolve = null
  }

  // ── Modal de tolerancia ────────────────────────────────
  #openToleranceModal(docCur) {
    return new Promise(resolve => {
      this.#toleranceResolve = resolve
      this.toleranceDocCurrencyTarget.textContent = docCur

      const select = this.toleranceSelectTarget
      select.innerHTML = '<option value="">-- Seleccione --</option>'
      this.#xmlToleranceAmounts.forEach((t, i) => {
        const opt       = document.createElement('option')
        opt.value       = i
        opt.textContent = `${t.CurrencyCode} — ${t.Tolerance}`
        select.appendChild(opt)
      })

      this.toleranceModalTarget.classList.remove('hidden')
    })
  }

  confirmTolerance() {
    const idx = this.toleranceSelectTarget.value
    this.toleranceModalTarget.classList.add('hidden')
    this.#toleranceResolve?.(idx !== '' ? this.#xmlToleranceAmounts[Number(idx)] : null)
    this.#toleranceResolve = null
  }

  cancelTolerance() {
    this.toleranceModalTarget.classList.add('hidden')
    this.#toleranceResolve?.(null)
    this.#toleranceResolve = null
  }

  // ── Modales de feedback ────────────────────────────────
  #showSuccess(message) {
    this.successModalMessageTarget.textContent = message
    this.successModalTarget.classList.remove('hidden')
  }

  closeSuccessModal() {
    this.successModalTarget.classList.add('hidden')
    Turbo.visit(this.#getReturnUrl())
  }

  // ── Preview panel ──────────────────────────────────────
  #openPreview() {
    this.previewBackdropTarget.classList.remove('hidden')
    this.previewPanelTarget.classList.remove('translate-x-full')
    document.body.style.overflow = 'hidden'
  }

  closePreview() {
    this.previewPanelTarget.classList.add('translate-x-full')
    this.previewBackdropTarget.classList.add('hidden')
    document.body.style.overflow = ''
  }

  // ── Loading overlay ────────────────────────────────────
  #showLoading(message = 'Cargando...') {
    this.loadingMessageTarget.textContent = message
    this.loadingOverlayTarget.classList.remove('hidden')
  }

  #hideLoading() {
    this.loadingOverlayTarget.classList.add('hidden')
  }

  // ── URL de retorno ─────────────────────────────────────
  #getReturnUrl() {
    return RETURN_URL
  }

  // ── Formato de moneda ──────────────────────────────────
  #fmtMoney(value, currency = '') {
    if (value == null || value === '') return '—'
    const num = parseFloat(value)
    if (isNaN(num)) return String(value)
    const formatted = num.toLocaleString('es-CR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    return currency ? `${currency} ${formatted}` : formatted
  }

  // ── apiFetch — patrón estándar del proyecto ────────────
  async #apiFetch(url, options = {}) {
    const apiTarget = options.headers?.['API'] ?? 'ApiAppUrl'

    const token     = (Storage.get('Session') || {}).access_token
    const company   = SStore.get('CurrentCompany')
    const companyId = company?.companyId ?? this.#companyId

    const headers = {
      'Content-Type':             'application/json',
      'API':                      apiTarget,
      'X-Skip-Error-Interceptor': 'true',
      ...(token     ? { Authorization:   `Bearer ${token}`  } : {}),
      ...(companyId ? { 'Cl-Company-Id': String(companyId)  } : {}),
      ...(options.headers || {}),
    }

    const response = await fetch(url, { ...options, headers })

    const clMessage = response.headers.get('cl-message')
    const decoded   = clMessage ? (() => {
      try { return decodeURIComponent(clMessage) } catch { return clMessage }
    })() : null

    if (!response.ok) {
      const text = await response.text().catch(() => response.statusText)
      throw new Error(decoded || text || `HTTP ${response.status}`)
    }

    const hasBody = response.status !== 204 &&
      response.headers.get('content-length') !== '0' &&
      response.headers.get('content-type')?.includes('application/json')

    if (!hasBody) return { Message: decoded || null }

    const json = await response.json()
    if (decoded && !json.Message) json.Message = decoded
    return json
  }
}

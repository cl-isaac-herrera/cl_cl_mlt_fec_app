import { Controller } from '@hotwired/stimulus'
import { TabulatorFull as Tabulator } from 'tabulator-tables'
import { Storage, SStore } from 'vendor/clavisco/core'
import Swal from 'sweetalert2'
import { TABULATOR_LOCALE, TABULATOR_LANGS, TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale'
import {
  DOC_TYPE, DocTypes, IdentificationType, ForeignNonResidentIdentification,
  IdentificationTypeFEC, ID_LENGTH, CondicionVenta, CondicionVentaFE, CondicionVentaREP,
  TipoDocRefList, TipoDocRefNotesList, TipoDocRefREPList, CodigoRefList, PaymentMethod, CurrencyATV,
  CURRENCY_SYMBOL, ProductType, ExonerationDocType, TipoTransaccion, CodigoDescuentoList,
  CodigoTarifaList, InstExoList,
} from 'controllers/create_document_constants'

const MAX_REFERENCES = 10
const MAX_MEDIO_PAGO = 4
const MAX_EMAILS = 4
const MAX_SURTIDOS = 20
const CABYS_DEBOUNCE = 350
const ACTIVITY_DEBOUNCE = 250
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const VOLUMETRIC_TAXES = new Set(['03', '04', '05', '06'])
// Impuestos a nivel de fábrica (combustible, alcohol, bebida/jabón, cemento)
const FACTORY_LEVEL_TAXES = new Set(['03', '04', '05', '12'])
// Descuentos que fuerzan ImpuestoAsumidoEmisorFabrica = ImpuestoNeto
const ROYALTY_BONUS_DISCOUNTS = new Set(['01', '03'])
// Tipos de impuesto cuya base imponible = subtotal + impuesto (especiales)
const BASE_IMP_TAXES = new Set(['02', '04', '05', '12'])

export default class extends Controller {
  static values = { docType: String }

  static targets = [
    'title', 'btnSubmit', 'btnSubmitLabel',
    'fechaFact', 'docTypeSelect', 'condicionVenta', 'condicionVentaOtrosWrap', 'condicionVentaOtros',
    'currency', 'exchangeRate', 'plazoCreditoWrap', 'plazoCredito',
    'actividadEmisorWrap', 'labelCodigoActividad', 'codigoActividadInterno', 'activityAutocomplete',
    'titleAccDatosCliente', 'rcprNombre', 'rcprIdeTipo', 'rcprIdeNumero',
    'actividadReceptorWrap', 'codigoActividadExterno', 'registroFiscalWrap', 'registroFiscal8707',
    'actividadEmisorRequiredMark', 'actividadReceptorRequiredMark', 'identificacionRequiredMark',
    'ubicacionRequiredMark',
    'otrasSenasExtranjeroWrap', 'otrasSenasExtranjero',
    'ubicacionSection', 'provincia', 'canton', 'distrito', 'barrio', 'otrasSenas',
    'emailSimpleWrap', 'email', 'telefonoWrap', 'telefono', 'telefonoCharCount', 'emailCCWrap', 'emailCC',
    'emailMultiWrap', 'btnAddEmail', 'emailList',
    'btnAddReference', 'referenceList',
    'titleAccItems', 'btnAddItem', 'btnAddItemLabel', 'itemsTable',
    'btnAddMedioPago', 'medioPagoTable',
    'totalSubtotal', 'totalImpuestos', 'totalDescuento', 'totalTotal',
    'accordionPanel',
    'customerBackdrop', 'customerPanel', 'customerSearchInput', 'customerTable',
    'productBackdrop', 'productPanel', 'productSearchInput', 'productTable',
    'itemBackdrop', 'itemPanel', 'itemPanelTitle', 'itemCabys', 'itemCabysLoading', 'cabysAutocomplete',
    'repPaymentBackdrop', 'repPaymentPanel', 'repPaymentPanelTitle', 'repPaymentDesc', 'repPaymentMonto',
    'repPaymentTaxType', 'repPaymentTaxOtroWrap', 'repPaymentTaxOtro', 'repPaymentTaxOtroRequired', 'repPaymentTaxOtroCount',
    'repPaymentCodigoTarifaWrap', 'repPaymentCodigoTarifa', 'repPaymentTaxRate',
    'repPaymentSubTotal', 'repPaymentTaxAmount', 'repPaymentTotal',
    'itemCode', 'itemProductType', 'itemTipoTransaccion', 'itemDescription', 'itemPriceLabel',
    'itemPrice', 'itemQuantity', 'itemDiscount', 'itemUnit', 'unitAutocomplete', 'itemCommercialUnit',
    'itemDiscountCode', 'itemDiscountCodeOtroWrap', 'itemDiscountCodeOtro',
    'itemProductExtraWrap', 'itemRegistroMedicamento', 'itemFormaFarmaceutica', 'itemVin',
    'itemTaxType', 'itemTaxOtroWrap', 'itemTaxOtro', 'itemBebidaJabonWrap', 'itemBebidaJabon',
    'itemCodigoTarifaWrap', 'itemCodigoTarifa', 'itemTaxRate',
    'itemIvaFabricaWrap', 'itemIvaFabrica', 'itemImpAsumidoWrap', 'itemImpAsumido',
    'itemBaseImponibleWrap', 'itemBaseImponible', 'itemCantidadUnidadWrap', 'itemCantidadUnidad',
    'itemVolumenUnidadWrap', 'itemVolumenUnidad', 'itemRegalia',
    'surtidoSection', 'surtidoIcon', 'surtidoBody', 'surtidoCabys', 'surtidoTipo', 'surtidoCodigo',
    'surtidoUnidad', 'surtidoDescripcion', 'surtidoCantidad', 'surtidoPrecio', 'surtidoTarifa', 'surtidoBodyTable',
    'exoneracionIcon', 'exoneracionBody', 'exoTipoDoc', 'exoTipoDocOtroWrap', 'exoTipoDocOtro',
    'exoNumeroDoc', 'exoFecha', 'exoArticulo', 'exoInciso',
    'exoInstitucion', 'exoInstitucionOtroWrap', 'exoInstitucionOtro', 'exoTarifa', 'exoMonto',
    'itemSubTotal', 'itemTaxAmount', 'itemTaxNeto', 'itemLineTotal',
    'termSucSelect',
    'successModal', 'successTitle', 'successSubtitle',
    'loadingOverlay', 'loadingMessage',
  ]

  #docType = ''
  #companyId = null
  #session = null
  #company = null

  #pharmaceuticalForms = []
  #activityCodes = []
  #provinces = []
  #country = []
  #impuestoTypes = []
  #unitProducto = []
  #unitServicio = []
  #unitOptions = []
  #customerTabulator = null
  #customerTotalRecords = 0
  #productTabulator = null
  #itemsTabulator = null
  #medioPagoTabulator = null
  #tableBuilt = { items: false, medioPago: false }
  #productTotalRecords = 0
  #terminalSucList = []

  #identificationTypeList = []
  #conditionSaleList = []
  #docTypeRefList = []
  #codeRefList = []

  #items = []
  #references = []
  #mediosPago = []
  #emails = []
  #surtidos = []
  #terminal = '0'
  #sucursal = '0'
  #docId = 0
  #selectedCurrencySymbol = CURRENCY_SYMBOL.CRC

  #subTotal = 0
  #impuestos = 0
  #descuento = 0
  #total = 0

  #editingItemId = null
  #idItemSeq = 0
  #surtidoSeq = 0
  #cabysTimer = null
  #activityTimer = null
  #custTimer = null
  #prodTimer = null
  #unitTimer = null
  #docClickHandler = null
  #cabysTooltipEl = null

  connect() {
    this.#docType = this.docTypeValue
    this.#session = Storage.get('Session') || {}
    this.#company = SStore.get('CurrentCompany')
    this.#companyId = this.#company?.companyId ?? null

    this.#fillSelect(this.docTypeSelectTarget, DocTypes, 'Id', 'Name')
    this.docTypeSelectTarget.value = this.#docType
    this.fechaFactTarget.value = this.#today()

    this.#fillSelect(this.itemProductTypeTarget, ProductType, 'Id', 'Value')
    this.#fillSelect(this.itemTipoTransaccionTarget, TipoTransaccion, 'Id', 'Value')
    this.#fillSelect(this.itemDiscountCodeTarget, CodigoDescuentoList, 'Id', 'Value', '-- Ninguno --')
    this.#fillSelect(this.itemCodigoTarifaTarget, CodigoTarifaList, 'Id', 'Value', '-- Seleccione --')
    this.#fillSelect(this.repPaymentCodigoTarifaTarget, CodigoTarifaList, 'Id', 'Value')
    this.#fillSelect(this.surtidoTipoTarget, ProductType, 'Id', 'Value')
    this.#fillSelect(this.exoTipoDocTarget, ExonerationDocType, 'Id', 'Value')
    this.#fillSelect(this.exoInstitucionTarget, InstExoList, 'Id', 'Value', '-- Ninguna --')
    this.#fillSelect(this.currencyTarget, CurrencyATV, 'Id', 'Value')
    this.currencyTarget.value = 'CRC'

    this.#docClickHandler = this.#onDocumentClick.bind(this)
    document.addEventListener('mousedown', this.#docClickHandler)
    this.#cabysTooltipEl = document.createElement('div')
    this.#cabysTooltipEl.style.cssText = 'position:fixed;z-index:9999;max-width:340px;display:none;pointer-events:none;background:#1f2937;color:#fff;padding:8px 10px;border-radius:8px;box-shadow:0 8px 24px rgba(0,0,0,.25);font-size:11px;line-height:1.35'
    document.body.appendChild(this.#cabysTooltipEl)

    if (!this.#companyId) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Seleccione una compañía antes de crear un documento.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }
    this.#loadInitialData()
  }

  #onDocumentClick(e) {
    const pairs = [
      [this.hasUnitAutocompleteTarget ? this.unitAutocompleteTarget : null, this.hasItemUnitTarget ? this.itemUnitTarget : null],
      [this.hasCabysAutocompleteTarget ? this.cabysAutocompleteTarget : null, this.hasItemCabysTarget ? this.itemCabysTarget : null],
      [this.hasActivityAutocompleteTarget ? this.activityAutocompleteTarget : null, this.hasCodigoActividadInternoTarget ? this.codigoActividadInternoTarget : null],
    ]
    pairs.forEach(([box, input]) => {
      if (box && !box.classList.contains('hidden') && !box.contains(e.target) && e.target !== input) box.classList.add('hidden')
    })
    this.#hideCabysTooltip()
  }

  disconnect() {
    [this.#cabysTimer, this.#activityTimer, this.#custTimer, this.#prodTimer, this.#unitTimer].forEach(t => t && clearTimeout(t))
    if (this.#docClickHandler) document.removeEventListener('mousedown', this.#docClickHandler)
    if (this.#cabysTooltipEl) this.#cabysTooltipEl.remove()
    this.#customerTabulator?.destroy()
    this.#productTabulator?.destroy()
    this.#itemsTabulator?.destroy()
    this.#medioPagoTabulator?.destroy()
    this.#tableBuilt = { items: false, medioPago: false }
    document.body.style.overflow = ''
  }

  async #loadInitialData() {
    this.#showLoading('Cargando información…')
    try {
      const [pharma, activity, provinces, country, impuesto, unitP, unitS] = await Promise.all([
        this.#apiFetch('/api/Documents/GetPharmaceuticalForms').catch(() => null),
        this.#apiFetch(`/api/Companies/${this.#companyId}/activity-codes`).catch(() => null),
        this.#fetchJson('/Provinces.json'),
        this.#fetchJson('/Country.json'),
        this.#fetchJson('/ImpuestoType.json'),
        this.#fetchJson('/UnidadMedidaTypeProducto.json'),
        this.#fetchJson('/UnidadMedidaTypeServicio.json'),
      ])
      this.#pharmaceuticalForms = pharma?.Data ?? pharma ?? []
      this.#activityCodes = activity?.Data ?? activity ?? []
      if (this.#activityCodes.length === 1) {
        const a = this.#activityCodes[0]
        const code = a.Code ?? a.code ?? ''
        const name = a.Name ?? a.Description ?? a.name ?? ''
        this.codigoActividadInternoTarget.value = `${code} - ${name}`
        this.codigoActividadInternoTarget.dataset.code = code
      }
      this.#provinces = provinces?.Provinces ?? []
      this.#country = country?.Country ?? []
      this.#impuestoTypes = (impuesto?.ImpuestoType ?? []).filter(t => t.active)
      this.#unitProducto = unitP?.UnidadMedidaType ?? []
      this.#unitServicio = unitS?.UnidadMedidaType ?? []
    } catch (err) {
      this.#hideLoading()
      Swal.fire({
        icon: 'error',
        title: 'Error al cargar datos',
        text: err.message,
        confirmButtonText: 'Aceptar'
      })
      return
    }
    this.#hideLoading()

    this.#fillSelect(this.itemTaxTypeTarget, this.#impuestoTypes, 'value', 'annotation')
    this.#fillSelect(this.repPaymentTaxTypeTarget, this.#impuestoTypes, 'value', 'annotation')
    this.#fillSelect(this.provinciaTarget, this.#provinces, 'ProvinceId', 'ProvinceName', '-- Seleccione --')
    this.#unitOptions = this.#unitProducto
    const pf = this.#pharmaceuticalForms.map(f => ({
      Id: f.Id ?? f.Code ?? f.value ?? f.Codigo ?? '',
      Name: f.Description ?? f.Name ?? f.annotation ?? f.Descripcion ?? '',
    }))
    this.#fillSelect(this.itemFormaFarmaceuticaTarget, pf, 'Id', 'Name', '-- Ninguna --')

    this.setDocTypeString()
    this.#loadTerminalSucursal()

    this.#references = [this.#newReference()]
    this.#mediosPago = [this.#newMedioPago()]
    this.#emails = ['']
    this.#renderReferences()
    this.#renderMediosPago()
    this.#renderEmails()
    this.#renderItems()
    this.#recalcTotals()
  }

  setDocTypeString() {
    const t = this.#docType
    this.titleAccDatosClienteTarget.textContent = 'Datos del Cliente'
    this.labelCodigoActividadTarget.textContent = 'Emisor'
    this.registroFiscalWrapTarget.classList.add('hidden')
    this.#showTarget(this.ubicacionSectionTarget, true)
    this.#showTarget(this.actividadReceptorWrapTarget, true)
    this.#showTarget(this.actividadEmisorWrapTarget, true)
    this.#showTarget(this.plazoCreditoWrapTarget, true)
    this.#showTarget(this.telefonoWrapTarget, true)
    this.#showTarget(this.emailCCWrapTarget, true)
    this.#showTarget(this.condicionVentaOtrosWrapTarget, true)
    this.#showTarget(this.emailSimpleWrapTarget, true)
    this.#showTarget(this.emailMultiWrapTarget, false)
    // Posición no-FEC: telefono dentro del grid de emailSimpleWrap, antes del CC
    this.emailSimpleWrapTarget.insertBefore(this.telefonoWrapTarget, this.emailCCWrapTarget)
    this.titleAccItemsTarget.textContent = 'Datos de Ítems'
    this.btnAddItemLabelTarget.textContent = 'Agregar Ítems'
    this.#docTypeRefList = [...TipoDocRefList]
    this.#codeRefList = [...CodigoRefList]
    let defaultCond = '01'

    switch (t) {
      case DOC_TYPE.FEE:
        this.titleTarget.textContent = 'Factura Electrónica de Exportación'
        this.#identificationTypeList = [...ForeignNonResidentIdentification]
        this.#conditionSaleList = [...CondicionVentaFE]
        this.#showTarget(this.ubicacionSectionTarget, false)
        break
      case DOC_TYPE.FE:
        this.titleTarget.textContent = 'Factura Electrónica'
        this.#identificationTypeList = [...IdentificationType]
        this.#conditionSaleList = [...CondicionVentaFE]
        break
      case DOC_TYPE.ND:
      case DOC_TYPE.NC:
        this.titleTarget.textContent = (t === DOC_TYPE.ND) ? 'Nota de Débito Electrónica' : 'Nota de Crédito Electrónica'
        this.#identificationTypeList = [{ Id: '', Name: 'Ninguna' }, ...ForeignNonResidentIdentification]
        this.#conditionSaleList = [...CondicionVenta]
        this.#docTypeRefList = [...TipoDocRefNotesList]
        break
      case DOC_TYPE.FEC:
        this.titleTarget.textContent = 'Factura Electrónica de Compra'
        this.titleAccDatosClienteTarget.textContent = 'Datos del Emisor'
        this.labelCodigoActividadTarget.textContent = 'Receptor'
        this.registroFiscalWrapTarget.classList.remove('hidden')
        this.#identificationTypeList = [...IdentificationTypeFEC]
        this.#conditionSaleList = [...CondicionVentaFE]
        this.#showTarget(this.emailSimpleWrapTarget, false)
        this.#showTarget(this.emailMultiWrapTarget, true)
        // Posición FEC: telefono standalone antes del bloque de emails múltiples
        this.emailMultiWrapTarget.insertAdjacentElement('beforebegin', this.telefonoWrapTarget)
        break
      case DOC_TYPE.REP:
        this.titleTarget.textContent = 'Recibo Electronico de Pago'
        this.#identificationTypeList = [...ForeignNonResidentIdentification]
        this.#conditionSaleList = [...CondicionVentaREP]
        this.#docTypeRefList = [...TipoDocRefREPList]
        this.#showTarget(this.ubicacionSectionTarget, false)
        this.#showTarget(this.actividadReceptorWrapTarget, false)
        this.#showTarget(this.actividadEmisorWrapTarget, false)
        this.#showTarget(this.plazoCreditoWrapTarget, false)
        this.#showTarget(this.telefonoWrapTarget, false)
        this.#showTarget(this.emailCCWrapTarget, false)
        this.#showTarget(this.condicionVentaOtrosWrapTarget, false)
        this.titleAccItemsTarget.textContent = 'Informacion de pago'
        this.btnAddItemLabelTarget.textContent = 'Agregar pago'
        defaultCond = '09'
        break
    }

    // Actividad receptor: visible para FEC (requerido), FE, ND, NC (opcional)
    this.#showTarget(this.actividadReceptorWrapTarget, [DOC_TYPE.FEC, DOC_TYPE.FE, DOC_TYPE.ND, DOC_TYPE.NC].includes(t))

    // Asteriscos requeridos dinámicos
    const actEmisorReq = [DOC_TYPE.FE, DOC_TYPE.FEE, DOC_TYPE.TE].includes(t)
    const actReceptorReq = t === DOC_TYPE.FEC
    const idNumeroReq = [DOC_TYPE.FE, DOC_TYPE.FEE, DOC_TYPE.FEC, DOC_TYPE.REP].includes(t)
    this.actividadEmisorRequiredMarkTarget.classList.toggle('hidden', !actEmisorReq)
    this.actividadReceptorRequiredMarkTarget.classList.toggle('hidden', !actReceptorReq)
    this.identificacionRequiredMarkTarget.classList.toggle('hidden', !idNumeroReq)
    this.#updateUbicacionRequired()

    this.#fillSelect(this.rcprIdeTipoTarget, this.#identificationTypeList, 'Id', 'Name')
    this.rcprIdeTipoTarget.value = (t === DOC_TYPE.FE || t === DOC_TYPE.FEC) ? '01' : ''
    this.#fillSelect(this.condicionVentaTarget, this.#conditionSaleList, 'Id', 'Name')
    this.condicionVentaTarget.value = defaultCond
    // Surtido solo aplica a FE/ND/NC (no FEC ni REP)
    this.#showTarget(this.surtidoSectionTarget, t !== DOC_TYPE.FEC && t !== DOC_TYPE.REP)

    this.onCurrencyChange()
    this.onConditionSaleChange()
    this.onIdentificationTypeChange()
  }

  toggleSection(event) {
    const panel = event.currentTarget.closest('[data-section]')
    const body = panel.querySelector('[data-accordion-body]')
    const icon = panel.querySelector('[data-accordion-icon]')
    const hidden = body.classList.toggle('hidden')
    icon.style.transform = hidden ? '' : 'rotate(180deg)'
  }

  collapseAll() {
    this.accordionPanelTargets.forEach(panel => {
      panel.querySelector('[data-accordion-body]').classList.add('hidden')
      panel.querySelector('[data-accordion-icon]').style.transform = ''
    })
  }

  onConditionSaleChange() {
    const v = this.condicionVentaTarget.value
    this.condicionVentaOtrosTarget.required = (v === '99')
    const plazoReq = (v === '02' || v === '10')
    this.plazoCreditoTarget.required = plazoReq
    if (plazoReq && (!this.plazoCreditoTarget.value || Number(this.plazoCreditoTarget.value) < 1)) this.plazoCreditoTarget.value = 1
    if (this.#docType === DOC_TYPE.FE && v === '12') {
      this.#identificationTypeList = [...ForeignNonResidentIdentification]
      const cur = this.rcprIdeTipoTarget.value
      this.#fillSelect(this.rcprIdeTipoTarget, this.#identificationTypeList, 'Id', 'Name')
      this.rcprIdeTipoTarget.value = cur || '01'
    }
  }

  onCurrencyChange() {
    const cur = this.currencyTarget.value
    this.#selectedCurrencySymbol = CURRENCY_SYMBOL[cur] ?? cur
    if (cur === 'CRC') { this.exchangeRateTarget.value = '1'; this.exchangeRateTarget.disabled = true }
    else { this.exchangeRateTarget.disabled = false; if (this.exchangeRateTarget.value === '1' || !this.exchangeRateTarget.value) this.exchangeRateTarget.value = '' }
    this.#renderItems()
    this.#recalcTotals()
  }

  onActivityCodeInput() {
    clearTimeout(this.#activityTimer)
    delete this.codigoActividadInternoTarget.dataset.code
    this.#activityTimer = setTimeout(() => {
      const value = this.codigoActividadInternoTarget.value.trim().toLowerCase()
      const matches = this.#activityCodes.filter(a => {
        const code = String(a.Code ?? a.code ?? ''); const name = String(a.Name ?? a.Description ?? a.name ?? '')
        return !value || code.toLowerCase().includes(value) || name.toLowerCase().includes(value)
      }).slice(0, 30)
      this.#renderActivityAutocomplete(matches)
    }, ACTIVITY_DEBOUNCE)
  }
  onActivityCodeFocus() { this.onActivityCodeInput() }

  #renderActivityAutocomplete(matches) {
    const box = this.activityAutocompleteTarget
    box.innerHTML = ''
    if (!matches.length) { box.classList.add('hidden'); return }
    matches.forEach(a => {
      const code = a.Code ?? a.code ?? ''; const name = a.Name ?? a.Description ?? a.name ?? ''
      const div = document.createElement('div')
      div.className = 'px-3 py-2 hover:bg-blue-50 cursor-pointer text-sm'
      div.textContent = `${code} - ${name}`
      div.addEventListener('mousedown', e => { e.preventDefault(); this.codigoActividadInternoTarget.value = `${code} - ${name}`; this.codigoActividadInternoTarget.dataset.code = code; box.classList.add('hidden') })
      box.appendChild(div)
    })
    this.#positionFixedDropdown(box, this.codigoActividadInternoTarget)
    box.classList.remove('hidden')
  }

  // Posiciona un dropdown como position:fixed bajo el input, para escapar del overflow de la sección.
  #positionFixedDropdown(box, input) {
    const rect = input.getBoundingClientRect()
    box.style.position = 'fixed'
    box.style.left = `${rect.left}px`
    box.style.top = `${rect.bottom + 2}px`
    box.style.width = `${rect.width}px`
    box.style.zIndex = '60'
  }

  clearActiveCode() { this.codigoActividadInternoTarget.value = ''; delete this.codigoActividadInternoTarget.dataset.code; this.activityAutocompleteTarget.classList.add('hidden') }
  onlyDigits(event) { event.target.value = event.target.value.replace(/\D/g, '') }

  // ── Cliente ───────────────────────────────────────────────
  onCustomerSearchKeydown(event) { if (event.key === 'Tab') this.openCustomerModal() }
  openCustomerModal() {
    this.#openPanel(this.customerPanelTarget, this.customerBackdropTarget)
    if (!this.#customerTabulator) {
      this.#initCustomerTabulator()
    } else {
      this.#customerTabulator.setData()
    }
  }
  closeCustomerModal() { this.#closePanel(this.customerPanelTarget, this.customerBackdropTarget) }
  onCustomerSearchInput() {
    clearTimeout(this.#custTimer)
    this.#custTimer = setTimeout(() => {
      this.#customerTotalRecords = 0
      this.#customerTabulator?.replaceData()
    }, 300)
  }

  #initCustomerTabulator() {
    const showFEC = this.#docType === DOC_TYPE.FEC
    const columns = [
      { title: 'Nombre',              field: 'Name',                widthGrow: 2, formatter: (cell) => this.#customerName(cell.getRow().getData()) },
      { title: 'Identificación',      field: 'RcprIdeNumero',       widthGrow: 1 },
      { title: 'Código de Actividad', field: 'CodigoActividad',     widthGrow: 1 },
      ...(showFEC ? [{ title: 'Reg. 8707', field: 'EmsrRegistrofiscal8707', widthGrow: 1 }] : []),
    ]
    this.#customerTotalRecords = 0
    this.#customerTabulator = new Tabulator(this.customerTableTarget, {
      height: '100%',
      layout: 'fitColumns',
      columnDefaults: { headerSort: false },
      placeholder: 'Sin resultados',
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 20, 50],
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#customerTotalRecords
        if (!total) return ''
        const to = Math.min(currentRow + _pageSize - 1, total)
        return `Mostrando ${currentRow}-${to} de ${total} filas`
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      ajaxURL: '/api/Customer',
      ajaxRequestFunc: (_url, _cfg, params) => this.#fetchCustomerPage(params),
      ajaxResponse: (_url, _params, response) => response,
      rowFormatter: (row) => { row.getElement().style.cursor = 'pointer' },
      columns,
    })
    // Event delegation: un solo listener en el contenedor estable evita duplicados por re-render
    this.customerTableTarget.addEventListener('click', (e) => {
      const rowEl = e.target.closest('.tabulator-row')
      if (!rowEl) return
      const rows = this.#customerTabulator?.getRows() ?? []
      const row  = rows.find(r => r.getElement() === rowEl)
      if (row && !row.getData()._cl_placeholder) this.#selectCustomer(row.getData())
    })
  }

  async #fetchCustomerPage(params) {
    const size   = params.size || 10
    const apiPage = (params.page || 1) - 1
    const filter = this.customerSearchInputTarget.value.trim()
    const qp = new URLSearchParams({
      companyId:      String(this.#companyId),
      docTypeFE:      this.#docType,
      filterCustomer: filter,
    })
    try {
      const { json, headers } = await this.#apiFetchRaw(`/api/Customer?${qp}`, {
        headers: {
          'cl-sl-pagination-page':      String(apiPage),
          'cl-sl-pagination-page-size': String(size),
        },
      })
      if (!json.Data) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'error',
          title: json.Message || 'Error al obtener clientes',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
        return { data: [], last_page: 1 }
      }
      const total    = parseInt(headers.get('cl-sl-pagination-records-count') ?? '0') || json.Data.length
      this.#customerTotalRecords = total
      const lastPage = Math.max(1, Math.ceil(total / size))
      return { data: json.Data, last_page: lastPage }
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: `Error al buscar clientes: ${err.message}`,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return { data: [], last_page: 1 }
    }
  }
  #customerName(c) {
    if (c.Name) return c.Name
    if (c.RcprNombre) return c.RcprNombre
    const info = c.RcprInfo ?? ''
    const parts = info.split(' - ')
    return parts.length > 1 ? parts.slice(1).join(' - ') : info
  }

  #selectCustomer(c) {
    if (!this.#validateCustomerType(c)) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'El tipo de identificación del cliente no es válido para este documento',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }
    this.rcprNombreTarget.value = this.#customerName(c)
    this.rcprIdeTipoTarget.value = c.RcprIdeTipo ?? c.IdType ?? '01'
    this.rcprIdeNumeroTarget.value = c.RcprIdeNumero ?? c.IdNumber ?? ''
    this.codigoActividadExternoTarget.value = c.CodigoActividad ?? c.RcprCodigoActividad ?? ''
    if (c.RcprCorreoElectronico ?? c.Email) this.emailTarget.value = c.RcprCorreoElectronico ?? c.Email
    this.onIdentificationTypeChange()
    this.closeCustomerModal()
  }
  #validateCustomerType(c) {
    const idType = c.RcprIdeTipo ?? c.IdType ?? ''; const t = this.#docType
    if (t === DOC_TYPE.FE && idType === '05' && this.condicionVentaTarget.value !== '12') return false
    if (t === DOC_TYPE.REP && idType === '05') return false
    if ([DOC_TYPE.FE, DOC_TYPE.ND, DOC_TYPE.NC, DOC_TYPE.REP].includes(t) && idType === '06') return false
    return true
  }
  onIdentificationTypeChange() {
    const idType = this.rcprIdeTipoTarget.value; const cfg = ID_LENGTH[idType]
    if (cfg) { this.rcprIdeNumeroTarget.maxLength = cfg.max; this.rcprIdeNumeroTarget.minLength = cfg.min; this.rcprIdeNumeroTarget.disabled = false }
    else { if (this.#docType === DOC_TYPE.FE || this.#docType === DOC_TYPE.FEC) this.rcprIdeNumeroTarget.value = ''; else this.rcprIdeNumeroTarget.disabled = true }
    const isForeign = idType === '05'
    this.otrasSenasExtranjeroTarget.disabled = !isForeign
    this.otrasSenasExtranjeroTarget.classList.toggle('bg-gray-50', !isForeign)
    if (!isForeign) this.otrasSenasExtranjeroTarget.value = ''
    this.#updateUbicacionRequired()
  }

  // ── Ubicación ─────────────────────────────────────────────
  #updateUbicacionRequired() {
    // FEC: requerido para id 01-04 (emisor domiciliado). Exento para 05; opcional para 06.
    // Otros tipos: opcional (condición 2 — aplica si el receptor tiene domicilio en el país)
    const isFEC  = this.#docType === DOC_TYPE.FEC
    const idTipo = this.rcprIdeTipoTarget.value
    const req    = isFEC && idTipo !== '05' && idTipo !== '06'
    this.ubicacionRequiredMarkTargets.forEach(el => el.classList.toggle('hidden', !req))
  }

  onTelefonoInput() {
    const len = this.telefonoTarget.value.trim().length
    this.telefonoCharCountTarget.textContent = len
  }

  onProvinciaChange() {
    const pid = this.provinciaTarget.value
    const cantones = this.#uniqueBy(this.#country.filter(c => c.ProvinceId === pid), 'CantonId').map(c => ({ Id: c.CantonId, Name: c.CantonName }))
    this.#fillSelect(this.cantonTarget, cantones, 'Id', 'Name', '-- Seleccione --')
    this.#fillSelect(this.distritoTarget, [], 'Id', 'Name', '-- Seleccione --')
    this.#fillSelect(this.barrioTarget, [], 'Id', 'Name', '-- Seleccione --')
  }
  onCantonChange() {
    const pid = this.provinciaTarget.value, cid = this.cantonTarget.value
    const distritos = this.#uniqueBy(this.#country.filter(c => c.ProvinceId === pid && c.CantonId === cid), 'DistrictId').map(c => ({ Id: c.DistrictId, Name: c.DistrictName }))
    this.#fillSelect(this.distritoTarget, distritos, 'Id', 'Name', '-- Seleccione --')
    this.#fillSelect(this.barrioTarget, [], 'Id', 'Name', '-- Seleccione --')
  }
  onDistritoChange() {
    const pid = this.provinciaTarget.value, cid = this.cantonTarget.value, did = this.distritoTarget.value
    const barrios = this.#country.filter(c => c.ProvinceId === pid && c.CantonId === cid && c.DistrictId === did).map(c => ({ Id: c.NeighborhoodId, Name: c.NeighborhoodName }))
    this.#fillSelect(this.barrioTarget, barrios, 'Id', 'Name', '-- Seleccione --')
  }

  // ── Emails (FEC) ──────────────────────────────────────────
  addEmail() { if (this.#emails.length < MAX_EMAILS) { this.#emails.push(''); this.#renderEmails() } }
  removeEmail(event) { const i = Number(event.currentTarget.dataset.idx); if (this.#emails.length <= 1) return; this.#emails.splice(i, 1); this.#renderEmails() }
  onEmailInput(event) { this.#emails[Number(event.target.dataset.idx)] = event.target.value }
  #renderEmails() {
    const list = this.emailListTarget; list.innerHTML = ''
    this.#emails.forEach((val, idx) => {
      const row = document.createElement('div')
      row.className = 'flex items-center border border-gray-300 rounded-lg overflow-hidden focus-within:ring-2 focus-within:ring-blue-500 bg-white'
      row.innerHTML = `
        <input type="email" maxlength="450" value="${val}" data-idx="${idx}" data-action="input->documents-create#onEmailInput" data-testid="email-${idx}"
               class="flex-1 px-3 py-2 text-sm bg-transparent outline-none">
        <button type="button" data-idx="${idx}" data-action="click->documents-create#removeEmail" ${this.#emails.length <= 1 ? 'disabled' : ''}
                class="self-stretch flex items-center px-2 border-l border-gray-200 text-red-500 hover:bg-red-50 transition-colors flex-shrink-0 disabled:opacity-30 disabled:cursor-not-allowed" title="Eliminar">
          <span class="material-icons text-base leading-none">delete</span>
        </button>`
      list.appendChild(row)
    })
    this.btnAddEmailTarget.disabled = this.#emails.length >= MAX_EMAILS
  }

  // ── Referencias ───────────────────────────────────────────
  #newReference() { return { id: ++this.#idItemSeq, tipoDoc: '', tipoDocOtro: '', numero: '', codigo: '', fechaEmision: this.#today(), codigoOtro: '', razon: '' } }
  addReference() { if (this.#references.length < MAX_REFERENCES) { this.#references.push(this.#newReference()); this.#renderReferences() } }
  async removeReference(event) {
    const id = Number(event.currentTarget.dataset.id)
    if (this.#references.length <= 1) return
    const ref = this.#references.find(r => r.id === id)
    if (ref && ref.tipoDoc) {
      const { isConfirmed } = await Swal.fire({
        title: 'Eliminar referencia',
        text: '¿Está seguro de eliminar esta referencia?',
        icon: 'warning',
        showCancelButton: true,
        confirmButtonText: 'Confirmar',
        cancelButtonText: 'Cancelar'
      })
      if (isConfirmed) { this.#references = this.#references.filter(r => r.id !== id); this.#renderReferences() }
    } else { this.#references = this.#references.filter(r => r.id !== id); this.#renderReferences() }
  }
  setReferenceToday(event) { const ref = this.#references.find(r => r.id === Number(event.currentTarget.dataset.id)); if (ref) { ref.fechaEmision = this.#today(); this.#renderReferences() } }
  onReferenceField(event) {
    const ref = this.#references.find(r => r.id === Number(event.target.dataset.id))
    if (!ref) return
    ref[event.target.dataset.field] = event.target.value
    // Re-renderizar cuando cambia tipoDoc o codigo para mostrar/ocultar campos condicionales
    if (event.target.dataset.field === 'tipoDoc' || event.target.dataset.field === 'codigo') {
      this.#renderReferences()
    }
  }
  #renderReferences() {
    const list = this.referenceListTarget; list.innerHTML = ''
    const required = [DOC_TYPE.ND, DOC_TYPE.NC, DOC_TYPE.FEC, DOC_TYPE.REP].includes(this.#docType)
    this.#references.forEach(ref => {
      const reqMark  = required ? ' <span class="text-red-500">*</span>' : ''
      // Campos internos requeridos solo cuando tipoDoc está seleccionado y ≠ '13'
      const skipCond  = ref.tipoDoc === '13'
      const innerReq  = !!ref.tipoDoc && !skipCond
      const numReq    = innerReq ? ' <span class="text-red-500">*</span>' : ''
      const fechaReq  = innerReq ? ' <span class="text-red-500">*</span>' : ''
      const innerReqM = innerReq ? ' <span class="text-red-500">*</span>' : ''
      const showTipoOtro  = ref.tipoDoc === '99'
      const showCodigoOtro = ref.codigo === '99'
      const card = document.createElement('div')
      card.className = 'border border-gray-200 rounded-lg p-4'; card.dataset.refId = ref.id
      card.innerHTML = `
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
          <div><label class="block text-xs font-medium text-gray-600 mb-1">Tipo de Documento${reqMark}</label>
            <select data-id="${ref.id}" data-field="tipoDoc" data-action="change->documents-create#onReferenceField" class="w-full border border-gray-300 rounded-lg px-2 py-2 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-blue-500">${this.#optionsHtml(this.#docTypeRefList, 'Id', 'Value', ref.tipoDoc, '-- Seleccione --')}</select></div>
          ${showTipoOtro ? `<div><label class="block text-xs font-medium text-gray-600 mb-1">Tipo de Documento OTRO${reqMark}</label>
            <input type="text" maxlength="100" value="${ref.tipoDocOtro || ''}" data-id="${ref.id}" data-field="tipoDocOtro" data-action="input->documents-create#onReferenceField" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"></div>` : ''}
          <div><label class="block text-xs font-medium text-gray-600 mb-1">Número${numReq}</label>
            <input type="text" value="${ref.numero}" data-id="${ref.id}" data-field="numero" data-action="input->documents-create#onReferenceField" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"></div>
          <div><label class="block text-xs font-medium text-gray-600 mb-1">Fecha de Emisión${fechaReq}</label>
            <div class="flex items-center border border-gray-300 rounded-lg overflow-hidden focus-within:ring-2 focus-within:ring-blue-500 bg-white">
              <input type="date" value="${(ref.fechaEmision || '').split('T')[0]}" data-id="${ref.id}" data-field="fechaEmision" data-action="change->documents-create#onReferenceField" class="flex-1 px-3 py-2 text-sm bg-transparent outline-none">
              <button type="button" data-id="${ref.id}" data-action="click->documents-create#setReferenceToday" class="self-stretch flex items-center px-2 border-l border-gray-200 text-gray-500 hover:bg-gray-100 transition-colors flex-shrink-0" title="Hoy"><span class="material-icons text-base leading-none">today</span></button>
            </div></div>
          <div><label class="block text-xs font-medium text-gray-600 mb-1">Código${innerReqM}</label>
            <select data-id="${ref.id}" data-field="codigo" data-action="change->documents-create#onReferenceField" class="w-full border border-gray-300 rounded-lg px-2 py-2 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-blue-500">${this.#optionsHtml(this.#codeRefList, 'Id', 'Value', ref.codigo, '-- Seleccione --')}</select></div>
          ${showCodigoOtro ? `<div><label class="block text-xs font-medium text-gray-600 mb-1">Código OTRO${innerReqM}</label>
            <input type="text" maxlength="100" value="${ref.codigoOtro || ''}" data-id="${ref.id}" data-field="codigoOtro" data-action="input->documents-create#onReferenceField" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"></div>` : ''}
          <div class="${showTipoOtro || showCodigoOtro ? '' : 'lg:col-span-2'}"><label class="block text-xs font-medium text-gray-600 mb-1">Razón${innerReqM}</label>
            <input type="text" maxlength="180" value="${ref.razon}" data-id="${ref.id}" data-field="razon" data-action="input->documents-create#onReferenceField" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"></div>
        </div>
        <div class="flex justify-end mt-2">
          <button type="button" data-id="${ref.id}" data-action="click->documents-create#removeReference" ${this.#references.length <= 1 ? 'disabled' : ''} class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors disabled:opacity-30 disabled:cursor-not-allowed" title="Eliminar referencia"><span class="material-icons text-base">delete</span></button>
        </div>`
      list.appendChild(card)
    })
    this.btnAddReferenceTarget.disabled = this.#references.length >= MAX_REFERENCES
  }

  // ── Medios de pago ────────────────────────────────────────
  #newMedioPago() { return { id: ++this.#idItemSeq, tipo: '01', otros: '', monto: 0 } }
  addMedioPago() { if (this.#mediosPago.length < MAX_MEDIO_PAGO) { this.#mediosPago.push(this.#newMedioPago()); this.#renderMediosPago() } }
  removeMedioPago(event) { const id = Number(event.currentTarget.dataset.id); if (this.#mediosPago.length <= 1) return; this.#mediosPago = this.#mediosPago.filter(m => m.id !== id); this.#renderMediosPago() }
  onMedioPagoField(event) { const m = this.#mediosPago.find(x => x.id === Number(event.target.dataset.id)); if (m) { const f = event.target.dataset.field; m[f] = f === 'monto' ? Number(event.target.value) : event.target.value } }
  // Difiere una operación hasta que la tabla termine de construirse (evita
  // 'Cannot read properties of null (reading verticalFillMode)' en Tabulator).
  #whenBuilt(table, key, fn) {
    if (this.#tableBuilt[key]) { fn(); return }
    table.on('tableBuilt', () => { this.#tableBuilt[key] = true; fn() })
  }

  #renderMediosPago() {
    if (!this.#medioPagoTabulator) { this.#initMedioPagoTabulator() }
    else if (this.medioPagoTableTarget.isConnected) {
      this.#whenBuilt(this.#medioPagoTabulator, 'medioPago', () => this.#medioPagoTabulator.replaceData(this.#mediosPago))
    }
    this.btnAddMedioPagoTarget.disabled = this.#mediosPago.length >= MAX_MEDIO_PAGO
  }

  #initMedioPagoTabulator() {
    const paymentLabels = Object.fromEntries(PaymentMethod.map(p => [p.Id, p.Value]))
    this.#medioPagoTabulator = new Tabulator(this.medioPagoTableTarget, {
      data: this.#mediosPago,
      layout: 'fitColumns',
      renderVertical: 'basic',
      columnDefaults: { headerSort: false },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      columns: [
        { title: 'Medio de Pago', field: 'tipo', widthGrow: 2,
          editor: 'list', editorParams: { values: PaymentMethod.map(p => ({ label: p.Value, value: p.Id })) },
          formatter: 'lookup', formatterParams: paymentLabels },
        { title: 'Detalle', field: 'otros', widthGrow: 2, editor: 'input', editorParams: { elementAttributes: { maxlength: '100' } } },
        { title: 'Monto', field: 'monto', widthGrow: 1, hozAlign: 'left',
          editor: 'number', editorParams: { min: 0, step: 0.01 },
          formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: '', field: 'id', width: 50, hozAlign: 'center',
          formatter: () => `<button type="button" data-action-type="delete" data-tooltip="Eliminar" class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors cursor-pointer"><span class="material-icons text-base">delete</span></button>` },
      ],
      cellEdited: (cell) => {
        const d = cell.getRow().getData()
        const m = this.#mediosPago.find(x => x.id === d.id)
        if (!m) return
        const field = cell.getField()
        m[field] = field === 'monto' ? Number(cell.getValue()) : cell.getValue()
      },
    })
    this.#medioPagoTabulator.on('tableBuilt', () => { this.#tableBuilt.medioPago = true })
    this.medioPagoTableTarget.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-action-type="delete"]')
      if (!btn || this.#mediosPago.length <= 1) return
      const rowEl = btn.closest('.tabulator-row')
      if (!rowEl) return
      const tRow = (this.#medioPagoTabulator?.getRows() ?? []).find(r => r.getElement() === rowEl)
      if (!tRow) return
      const id = tRow.getData().id
      this.removeMedioPago({ currentTarget: { dataset: { id } } })
    })
  }

  // ── Búsqueda de producto ──────────────────────────────────
  openProductSearch() {
    this.#openPanel(this.productPanelTarget, this.productBackdropTarget)
    this.productSearchInputTarget.value = ''
    if (!this.#productTabulator) {
      this.#initProductTabulator()
    } else {
      this.#productTabulator.setData()
    }
  }
  closeProductSearch() { this.#closePanel(this.productPanelTarget, this.productBackdropTarget) }
  onProductSearchInput() {
    clearTimeout(this.#prodTimer)
    this.#prodTimer = setTimeout(() => {
      this.#productTotalRecords = 0
      this.#productTabulator?.replaceData()
    }, 300)
  }

  #initProductTabulator() {
    this.#productTotalRecords = 0
    this.#productTabulator = new Tabulator(this.productTableTarget, {
      height: '100%',
      layout: 'fitColumns',
      columnDefaults: { headerSort: false },
      placeholder: 'Sin resultados',
      pagination: true,
      paginationMode: 'remote',
      paginationSize: 10,
      paginationSizeSelector: [10, 20, 50],
      paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
        const total = this.#productTotalRecords
        if (!total) return ''
        const to = Math.min(currentRow + _pageSize - 1, total)
        return `Mostrando ${currentRow}-${to} de ${total} filas`
      },
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      dataLoaderLoading: TABULATOR_LOADING_HTML,
      ajaxURL: '/api/Item',
      ajaxRequestFunc: (_url, _cfg, params) => this.#fetchProductPage(params),
      ajaxResponse: (_url, _params, response) => response,
      rowFormatter: (row) => { row.getElement().style.cursor = 'pointer' },
      columns: [
        { title: 'Código',      field: 'CodTipo',     widthGrow: 1, formatter: (cell) => { const d = cell.getRow().getData(); return d.CodTipo ?? d.ItemCode ?? d.Code ?? '' } },
        { title: 'Descripción', field: 'Descripcion', widthGrow: 3, formatter: (cell) => { const d = cell.getRow().getData(); return d.Descripcion ?? d.ItemName ?? d.Description ?? '' } },
        { title: 'Precio',      field: 'Precio',      widthGrow: 1, hozAlign: 'left', formatter: (cell) => { const d = cell.getRow().getData(); return this.#fmt(d.Precio ?? d.Price ?? 0) } },
      ],
    })
    // Event delegation: un solo listener en el contenedor estable evita duplicados por re-render
    this.productTableTarget.addEventListener('click', (e) => {
      const rowEl = e.target.closest('.tabulator-row')
      if (!rowEl) return
      const rows = this.#productTabulator?.getRows() ?? []
      const row  = rows.find(r => r.getElement() === rowEl)
      if (row) this.#selectProduct(row.getData())
    })
  }

  async #fetchProductPage(params) {
    const size    = params.size || 10
    const apiPage = (params.page || 1) - 1
    const filter  = this.productSearchInputTarget.value.trim()
    const qp = new URLSearchParams({
      companyId: String(this.#companyId),
      docType:   this.#docType,
      filter,
    })
    try {
      const { json, headers } = await this.#apiFetchRaw(`/api/Item?${qp}`, {
        headers: {
          'cl-sl-pagination-page':      String(apiPage),
          'cl-sl-pagination-page-size': String(size),
        },
      })
      if (!json.Data) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'error',
          title: json.Message || 'Error al obtener productos',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
        return { data: [], last_page: 1 }
      }
      const total    = parseInt(headers.get('cl-sl-pagination-records-count') ?? '0') || json.Data.length
      this.#productTotalRecords = total
      const lastPage = Math.max(1, Math.ceil(total / size))
      return { data: json.Data, last_page: lastPage }
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: `Error al buscar productos: ${err.message}`,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return { data: [], last_page: 1 }
    }
  }
  #selectProduct(p) {
    this.itemCodeTarget.value = p.CodTipo ?? p.ItemCode ?? p.Code ?? ''
    this.itemDescriptionTarget.value = p.Descripcion ?? p.ItemName ?? p.Description ?? ''
    if (p.Cabys ?? p.Codigo ?? p.CabysCode) this.itemCabysTarget.value = p.Cabys ?? p.Codigo ?? p.CabysCode
    if (p.Precio ?? p.Price) this.itemPriceTarget.value = p.Precio ?? p.Price
    if (p.UnidadMedida ?? p.Unit) { const c = p.UnidadMedida ?? p.Unit; this.itemUnitTarget.value = this.#unitLabel(c); this.itemUnitTarget.dataset.code = c }
    this.recalcItem()
    this.closeProductSearch()
  }

  // ── Unidad de medida (autocomplete) ───────────────────────
  onUnitInput() {
    clearTimeout(this.#unitTimer)
    delete this.itemUnitTarget.dataset.code
    this.#unitTimer = setTimeout(() => {
      const val = this.itemUnitTarget.value.trim().toLowerCase()
      const matches = this.#unitOptions.filter(u =>
        !val || String(u.value).toLowerCase().includes(val) || String(u.annotation).toLowerCase().includes(val)).slice(0, 40)
      this.#renderUnitAutocomplete(matches)
    }, 150)
  }
  onUnitFocus() { this.onUnitInput() }
  #renderUnitAutocomplete(matches) {
    const box = this.unitAutocompleteTarget; box.innerHTML = ''
    if (!matches.length) { box.classList.add('hidden'); return }
    matches.forEach(u => {
      const div = document.createElement('div')
      div.className = 'px-3 py-2 hover:bg-blue-50 cursor-pointer text-sm'
      div.textContent = `${u.value} — ${u.annotation}`
      div.addEventListener('mousedown', e => { e.preventDefault(); this.itemUnitTarget.value = `${u.value} - ${u.annotation}`; this.itemUnitTarget.dataset.code = u.value; box.classList.add('hidden') })
      box.appendChild(div)
    })
    box.classList.remove('hidden')
  }

  // ── Ítems (panel) ─────────────────────────────────────────
  openAddItem() {
    if (this.#docType === DOC_TYPE.REP) { this.openRepPayment(); return }
    this.#editingItemId = null
    this.itemPanelTitleTarget.textContent = 'Agregar Ítem'
    this.#resetItemForm()
    this.#openPanel(this.itemPanelTarget, this.itemBackdropTarget)
  }
  closeAddItem() { this.#closePanel(this.itemPanelTarget, this.itemBackdropTarget); this.cabysAutocompleteTarget.classList.add('hidden'); this.unitAutocompleteTarget.classList.add('hidden'); this.#hideCabysTooltip() }

  #resetItemForm() {
    this.itemCabysTarget.value = ''
    this.itemCodeTarget.value = ''
    this.itemDescriptionTarget.value = ''
    this.itemTipoTransaccionTarget.value = '01'
    this.itemQuantityTarget.value = ''
    this.itemQuantityTarget.disabled = false
    this.itemPriceTarget.value = ''
    this.itemPriceTarget.disabled = false
    this.itemPriceLabelTarget.innerHTML = 'Precio <span class="text-red-500">*</span>'
    this.itemDiscountTarget.value = '0'
    this.itemDiscountCodeTarget.value = ''
    this.itemDiscountCodeOtroTarget.value = ''
    this.itemDiscountCodeOtroWrapTarget.classList.add('hidden')
    this.itemUnitTarget.value = ''
    delete this.itemUnitTarget.dataset.code
    this.itemCommercialUnitTarget.value = ''
    this.itemRegistroMedicamentoTarget.value = ''
    this.itemFormaFarmaceuticaTarget.value = ''
    this.itemVinTarget.value = ''
    this.itemTaxRateTarget.value = '0'
    this.itemTaxTypeTarget.value = ''
    this.itemTaxOtroTarget.value = ''
    this.itemCodigoTarifaTarget.value = ''
    this.itemBebidaJabonTarget.value = ''
    this.itemIvaFabricaTarget.value = ''
    this.itemImpAsumidoTarget.value = ''
    this.itemProductTypeTarget.value = '01'
    this.itemRegaliaTarget.checked = false
    this.itemBaseImponibleTarget.value = ''
    this.itemCantidadUnidadTarget.value = ''
    this.itemVolumenUnidadTarget.value = ''
    this.exoTipoDocTarget.value = '00'
    this.exoTipoDocOtroTarget.value = ''
    this.exoNumeroDocTarget.value = ''
    this.exoFechaTarget.value = this.#today()
    this.exoArticuloTarget.value = ''
    this.exoIncisoTarget.value = ''
    this.exoInstitucionTarget.value = ''
    this.exoInstitucionOtroTarget.value = ''
    this.exoTarifaTarget.value = '0'
    this.exoMontoTarget.value = ''
    this.exoTipoDocOtroWrapTarget.classList.add('hidden')
    this.exoInstitucionOtroWrapTarget.classList.add('hidden')
    this.exoneracionBodyTarget.classList.add('hidden')
    this.exoneracionIconTarget.style.transform = ''
    this.#surtidos = []
    this.surtidoBodyTarget.classList.add('hidden')
    this.surtidoIconTarget.style.transform = ''
    this.#resetSurtidoForm()
    this.#renderSurtidos()
    this.onProductTypeChange()
    this.onTaxTypeChange()
    this.recalcItem()
  }

  onProductTypeChange() {
    const isService = this.itemProductTypeTarget.value === '02'
    this.#unitOptions = isService ? this.#unitServicio : this.#unitProducto
    this.#showTarget(this.itemProductExtraWrapTarget, !isService)
  }

  onDiscountCodeChange() {
    this.#showTarget(this.itemDiscountCodeOtroWrapTarget, this.itemDiscountCodeTarget.value === '99')
    this.recalcItem()
  }

  onTaxTypeChange() {
    const code = this.itemTaxTypeTarget.value
    const isIVA = code === '01'
    const visFEC = this.#docType !== DOC_TYPE.FEC && this.#docType !== DOC_TYPE.REP
    this.#showTarget(this.itemCodigoTarifaWrapTarget, isIVA)
    if (isIVA) {
      if (!this.itemCodigoTarifaTarget.value) { this.itemCodigoTarifaTarget.value = '08'; this.onCodigoTarifaChange() }
      this.itemTaxRateTarget.disabled = true
    } else if (code === '') { this.itemTaxRateTarget.value = '0'; this.itemTaxRateTarget.disabled = true }
    else { this.itemTaxRateTarget.disabled = false }
    this.#showTarget(this.itemTaxOtroWrapTarget, code === '99')
    this.#showTarget(this.itemBebidaJabonWrapTarget, code === '05')
    this.#showTarget(this.itemIvaFabricaWrapTarget, visFEC)
    this.#showTarget(this.itemImpAsumidoWrapTarget, visFEC)
    this.#showTarget(this.itemCantidadUnidadWrapTarget, visFEC)
    this.#showTarget(this.itemVolumenUnidadWrapTarget, visFEC)
    const baseImpVisible = code === '07' || this.itemIvaFabricaTarget.value === '01'
    this.#showTarget(this.itemBaseImponibleWrapTarget, baseImpVisible)
    this.recalcItem()
  }
  onCodigoTarifaChange() { const sel = CodigoTarifaList.find(c => c.Id === this.itemCodigoTarifaTarget.value); if (sel) this.itemTaxRateTarget.value = String(sel.Rate); this.recalcItem() }
  toggleExoneracion() { const h = this.exoneracionBodyTarget.classList.toggle('hidden'); this.exoneracionIconTarget.style.transform = h ? '' : 'rotate(180deg)' }
  onExoTipoDocChange() { this.#showTarget(this.exoTipoDocOtroWrapTarget, this.exoTipoDocTarget.value === '99'); this.recalcItem() }
  onExoInstitucionChange() { this.#showTarget(this.exoInstitucionOtroWrapTarget, this.exoInstitucionTarget.value === '99') }
  onRegaliaChange() {
    if (this.itemRegaliaTarget.checked && (!this.itemPriceTarget.value || Number(this.itemPriceTarget.value) <= 0)) {
      Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'Digite el precio antes de marcar como regalía', showConfirmButton: false, timer: 3000, timerProgressBar: true }); this.itemRegaliaTarget.checked = false; return
    }
    this.recalcItem()
  }

  // ── Surtidos ──────────────────────────────────────────────
  toggleSurtido() { const h = this.surtidoBodyTarget.classList.toggle('hidden'); this.surtidoIconTarget.style.transform = h ? '' : 'rotate(180deg)' }
  #resetSurtidoForm() {
    this.surtidoCabysTarget.value = ''
    this.surtidoTipoTarget.value = '01'
    this.surtidoCodigoTarget.value = ''
    this.surtidoUnidadTarget.value = ''
    this.surtidoDescripcionTarget.value = ''
    this.surtidoCantidadTarget.value = '1'
    this.surtidoPrecioTarget.value = ''
    this.surtidoTarifaTarget.value = '13'
  }
  addSurtido() {
    if (this.#surtidos.length >= MAX_SURTIDOS) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: `Máximo ${MAX_SURTIDOS} surtidos`, showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    const cant = Number(this.surtidoCantidadTarget.value) || 0
    const precio = Number(this.surtidoPrecioTarget.value) || 0
    if (!this.surtidoCabysTarget.value.trim() || !this.surtidoDescripcionTarget.value.trim()) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'CABYS y descripción del surtido son requeridos', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    if (cant <= 0 || precio < 0) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'Cantidad/precio del surtido inválidos', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    this.#surtidos.push({
      id: ++this.#surtidoSeq,
      Cabys: this.surtidoCabysTarget.value.trim(),
      Tipo: this.surtidoTipoTarget.value,
      Codigo: this.surtidoCodigoTarget.value.trim(),
      Unidad: this.surtidoUnidadTarget.value.trim(),
      Descripcion: this.surtidoDescripcionTarget.value.trim(),
      Cantidad: cant,
      Precio: precio,
      Tarifa: Number(this.surtidoTarifaTarget.value) || 0,
    })
    this.#resetSurtidoForm()
    this.#renderSurtidos()
    this.#applySurtidoToItem()
    this.recalcItem()
  }
  removeSurtido(event) {
    const id = Number(event.currentTarget.dataset.id)
    this.#surtidos = this.#surtidos.filter(s => s.id !== id)
    this.#renderSurtidos()
    this.#applySurtidoToItem()
    this.recalcItem()
  }
  #applySurtidoToItem() {
    // Cuando hay surtidos, el precio del ítem se deriva de ellos y el campo se bloquea.
    if (this.#surtidos.length) {
      const subtotal = this.#surtidos.reduce((s, x) => s + x.Precio * x.Cantidad, 0)
      this.itemPriceTarget.value = (subtotal / (Number(this.itemQuantityTarget.value) || 1)).toFixed(5)
      this.itemPriceTarget.disabled = true
    } else {
      this.itemPriceTarget.disabled = (this.#docType === DOC_TYPE.REP) ? false : false
    }
  }
  #renderSurtidos() {
    const tbody = this.surtidoBodyTableTarget; tbody.innerHTML = ''
    if (!this.#surtidos.length) { tbody.innerHTML = '<tr><td colspan="6" class="px-3 py-3 text-center text-xs text-gray-400">Sin surtidos</td></tr>'; return }
    this.#surtidos.forEach(s => {
      const tr = document.createElement('tr')
      tr.className = 'border-b border-gray-100'
      tr.innerHTML = `
        <td class="px-3 py-2 text-xs text-gray-700">${s.Cabys}</td>
        <td class="px-3 py-2 text-xs text-gray-700">${s.Descripcion}</td>
        <td class="px-3 py-2 text-xs text-right text-gray-700">${s.Cantidad}</td>
        <td class="px-3 py-2 text-xs text-right text-gray-700">${this.#fmt(s.Precio)}</td>
        <td class="px-3 py-2 text-xs text-right text-gray-700">${s.Tarifa}%</td>
        <td class="px-3 py-2 text-center">
          <button type="button" data-id="${s.id}" data-action="click->documents-create#removeSurtido" class="p-1 text-red-600 rounded hover:bg-red-50 transition-colors" title="Eliminar"><span class="material-icons text-base">delete</span></button>
        </td>`
      tbody.appendChild(tr)
    })
  }

  #computeItem() {
    const qty = Number(this.itemQuantityTarget.value) || 0
    const discPct = Number(this.itemDiscountTarget.value) || 0
    const taxRate = Number(this.itemTaxRateTarget.value) || 0
    const isRegalia = this.itemRegaliaTarget.checked
    const exoTarifa = Number(this.exoTarifaTarget.value) || 0
    const hasSurtidos = this.#surtidos.length > 0

    let montoTotal, impMonto
    if (hasSurtidos) {
      montoTotal = this.#surtidos.reduce((s, x) => s + x.Precio * x.Cantidad, 0)
      impMonto = this.#surtidos.reduce((s, x) => s + x.Precio * x.Cantidad * (x.Tarifa / 100), 0)
    } else {
      const price = Number(this.itemPriceTarget.value) || 0
      montoTotal = qty * price
    }
    const montoDescuento = montoTotal * (discPct / 100)
    const subTotal = montoTotal - montoDescuento
    if (!hasSurtidos) {
      const useBase = (this.itemTaxTypeTarget.value === '07' || this.itemIvaFabricaTarget.value === '01') && Number(this.itemBaseImponibleTarget.value) > 0
      const base = useBase ? Number(this.itemBaseImponibleTarget.value) : subTotal
      impMonto = base * (taxRate / 100)
    }
    const exoMonto = Math.min(impMonto, subTotal * (exoTarifa / 100))
    const impuestoNeto = Math.max(0, impMonto - exoMonto)
    const lineSubTotal = isRegalia ? 0 : subTotal
    const lineTotal = isRegalia ? impuestoNeto : subTotal + impuestoNeto
    return { qty, montoTotal, montoDescuento, subTotal: lineSubTotal, impMonto, exoMonto, impuestoNeto, lineTotal, isRegalia, taxRate, discPct }
  }

  recalcItem() {
    const r = this.#computeItem()
    this.itemSubTotalTarget.textContent = this.#fmt(r.subTotal)
    this.itemTaxAmountTarget.textContent = this.#fmt(r.impMonto)
    this.itemTaxNetoTarget.textContent = this.#fmt(r.impuestoNeto)
    this.itemLineTotalTarget.textContent = this.#fmt(r.lineTotal)
    this.exoMontoTarget.value = this.#fmt(r.exoMonto)
    this.#updateBaseImponible(r.subTotal, r.impMonto)
    this.#updateImpAsumido(r.impuestoNeto)
  }

  // Réplica de CalculateAndSetBaseImponible() del legacy.
  // Editable solo cuando aplica (IVA especial 07 o IVA cobrado a fábrica); en el resto es calculada.
  #updateBaseImponible(subTotal, impMonto) {
    const tax = this.itemTaxTypeTarget.value
    const validateBase = tax === '07' || this.itemIvaFabricaTarget.value === '01'
    const editable = validateBase && !BASE_IMP_TAXES.has(tax)
    this.itemBaseImponibleTarget.readOnly = !editable
    this.itemBaseImponibleTarget.classList.toggle('bg-gray-50', !editable)
    if (BASE_IMP_TAXES.has(tax)) {
      this.itemBaseImponibleTarget.value = (subTotal + impMonto).toFixed(2)
    } else if (!validateBase) {
      this.itemBaseImponibleTarget.value = subTotal.toFixed(2)
    } else if (!this.itemBaseImponibleTarget.value) {
      // editable y vacío → valor por defecto = subtotal (para que "ya tenga valor" al mostrarse)
      this.itemBaseImponibleTarget.value = subTotal.toFixed(2)
    }
  }

  // Réplica de IVACobredoFabricaChange() del legacy: campo calculado y siempre deshabilitado.
  #updateImpAsumido(impuestoNeto) {
    const ivaFab = this.itemIvaFabricaTarget.value
    let monto = 0
    if (ivaFab !== '' && ivaFab != null) {
      const tax = this.itemTaxTypeTarget.value
      const disc = this.itemDiscountCodeTarget.value
      const exemptByRule = !FACTORY_LEVEL_TAXES.has(tax) && !ROYALTY_BONUS_DISCOUNTS.has(disc)
      monto = exemptByRule ? 0 : impuestoNeto
    }
    this.itemImpAsumidoTarget.value = Number(monto).toFixed(2)
  }

  saveItem() {
    if (!this.itemCabysTarget.value.trim()) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El código CABYS es requerido', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    if (!this.itemCodeTarget.value.trim()) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El código del ítem es requerido', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    if (!this.itemDescriptionTarget.value.trim()) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'La descripción es requerida', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    const r = this.#computeItem()
    if (r.qty <= 0) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'La cantidad debe ser mayor a 0', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    if (!this.#unitCode()) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'La unidad de medida es requerida', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    const price = Number(this.itemPriceTarget.value) || 0

    const item = {
      id: this.#editingItemId ?? ++this.#idItemSeq,
      Cabys: this.itemCabysTarget.value.trim(), CodTipo: this.itemCodeTarget.value.trim(), Descripcion: this.itemDescriptionTarget.value.trim(),
      ProductType: this.itemProductTypeTarget.value, TipoTransaccion: this.itemTipoTransaccionTarget.value,
      Cantidad: r.qty, PrecioUnitario: r.isRegalia ? 0 : price, PrecioDigitado: price,
      DescuentoPct: r.discPct, CodigoDescuento: this.itemDiscountCodeTarget.value, CodigoDescuentoOtro: this.itemDiscountCodeOtroTarget.value,
      UnidadMedida: this.#unitCode(), UnidadMedidaComercial: this.itemCommercialUnitTarget.value,
      RegistroMedicamento: this.itemRegistroMedicamentoTarget.value, FormaFarmaceutica: this.itemFormaFarmaceuticaTarget.value, NumeroVINoSerie: this.itemVinTarget.value,
      ImpCodigo: this.itemTaxTypeTarget.value, ImpTipoOtro: this.itemTaxOtroTarget.value, BebidaJabon: this.itemBebidaJabonTarget.value,
      CodigoTarifa: this.itemCodigoTarifaTarget.value, ImpTarifa: r.taxRate,
      IVACobradoFabrica: this.itemIvaFabricaTarget.value, ImpuestoAsumidoEmisorFabrica: Number(this.itemImpAsumidoTarget.value) || 0,
      BaseImponible: Number(this.itemBaseImponibleTarget.value) || 0,
      ImpCantidadUnidadMedida: Number(this.itemCantidadUnidadTarget.value) || 0, ImpVolumenUnidadConsumo: Number(this.itemVolumenUnidadTarget.value) || 0,
      MontoTotal: r.isRegalia ? 0 : r.montoTotal, MontoDescuento: r.montoDescuento, SubTotal: r.subTotal,
      ImpMonto: r.impMonto, ImpuestoNeto: r.impuestoNeto, MontoTotalLinea: r.lineTotal, Regalia: r.isRegalia,
      Exoneracion: {
        ETipoDocumento: this.exoTipoDocTarget.value, ETipoDocumentoOTRO: this.exoTipoDocOtroTarget.value,
        ENumeroDocumento: this.exoNumeroDocTarget.value, EFechaEmision: this.exoFechaTarget.value,
        EArticulo: Number(this.exoArticuloTarget.value) || 0, EInciso: Number(this.exoIncisoTarget.value) || 0,
        ENombreInstitucion: this.exoInstitucionTarget.value, ENombreInstitucionOtros: this.exoInstitucionOtroTarget.value,
        ETarifaExonerada: Number(this.exoTarifaTarget.value) || 0, EMontoExoneracion: r.exoMonto,
      },
      Surtidos: this.#surtidos.map(s => ({ ...s })),
    }

    if (this.#editingItemId != null) { const idx = this.#items.findIndex(i => i.id === this.#editingItemId); if (idx !== -1) this.#items[idx] = item }
    else this.#items.push(item)
    this.#renderItems()
    this.#recalcTotals()
    this.closeAddItem()
  }

  editItem(event) {
    const id = Number(event.currentTarget.dataset.id)
    const item = this.#items.find(i => i.id === id)
    if (!item) return
    this.#editingItemId = id
    if (this.#docType === DOC_TYPE.REP) { this.#loadRepPaymentForEdit(item); return }
    this.itemPanelTitleTarget.textContent = 'Editar Ítem'
    this.#surtidos = (item.Surtidos ?? []).map(s => ({ ...s }))
    this.itemCabysTarget.value = item.Cabys
    this.itemCodeTarget.value = item.CodTipo
    this.itemDescriptionTarget.value = item.Descripcion
    this.itemProductTypeTarget.value = item.ProductType
    this.onProductTypeChange()
    this.itemTipoTransaccionTarget.value = item.TipoTransaccion ?? '01'
    this.itemUnitTarget.value = this.#unitLabel(item.UnidadMedida)
    this.itemUnitTarget.dataset.code = item.UnidadMedida
    this.itemCommercialUnitTarget.value = item.UnidadMedidaComercial ?? ''
    this.itemRegistroMedicamentoTarget.value = item.RegistroMedicamento ?? ''
    this.itemFormaFarmaceuticaTarget.value = item.FormaFarmaceutica ?? ''
    this.itemVinTarget.value = item.NumeroVINoSerie ?? ''
    this.itemQuantityTarget.value = item.Cantidad
    this.itemQuantityTarget.disabled = false
    this.itemPriceTarget.value = item.PrecioDigitado
    this.itemDiscountTarget.value = item.DescuentoPct
    this.itemDiscountCodeTarget.value = item.CodigoDescuento ?? ''
    this.itemDiscountCodeOtroTarget.value = item.CodigoDescuentoOtro ?? ''
    this.onDiscountCodeChange()
    this.itemTaxTypeTarget.value = item.ImpCodigo
    this.itemBebidaJabonTarget.value = item.BebidaJabon ?? ''
    this.itemIvaFabricaTarget.value = item.IVACobradoFabrica ?? ''
    this.itemImpAsumidoTarget.value = item.ImpuestoAsumidoEmisorFabrica || ''
    this.onTaxTypeChange()
    this.itemCodigoTarifaTarget.value = item.CodigoTarifa ?? ''
    this.itemTaxRateTarget.value = item.ImpTarifa
    this.itemTaxOtroTarget.value = item.ImpTipoOtro ?? ''
    this.#showTarget(this.itemTaxOtroWrapTarget, item.ImpCodigo === '99')
    this.itemBaseImponibleTarget.value = item.BaseImponible || ''
    this.itemCantidadUnidadTarget.value = item.ImpCantidadUnidadMedida || ''
    this.itemVolumenUnidadTarget.value = item.ImpVolumenUnidadConsumo || ''
    this.itemRegaliaTarget.checked = item.Regalia
    const exo = item.Exoneracion ?? {}
    this.exoTipoDocTarget.value = exo.ETipoDocumento ?? '00'
    this.exoTipoDocOtroTarget.value = exo.ETipoDocumentoOTRO ?? ''
    this.exoNumeroDocTarget.value = exo.ENumeroDocumento ?? ''
    this.exoFechaTarget.value = (exo.EFechaEmision ?? this.#today()).split('T')[0]
    this.exoArticuloTarget.value = exo.EArticulo || ''
    this.exoIncisoTarget.value = exo.EInciso || ''
    this.exoInstitucionTarget.value = exo.ENombreInstitucion ?? ''
    this.exoInstitucionOtroTarget.value = exo.ENombreInstitucionOtros ?? ''
    this.exoTarifaTarget.value = exo.ETarifaExonerada ?? 0
    this.onExoTipoDocChange()
    this.onExoInstitucionChange()
    this.#renderSurtidos()
    this.#applySurtidoToItem()
    this.recalcItem()
    this.#openPanel(this.itemPanelTarget, this.itemBackdropTarget)
  }

  removeItem(event) { const id = Number(event.currentTarget.dataset.id); this.#items = this.#items.filter(i => i.id !== id); this.#renderItems(); this.#recalcTotals() }

  #renderItems() {
    if (!this.#itemsTabulator) { this.#initItemsTabulator(); return }
    if (this.itemsTableTarget.isConnected) {
      this.#whenBuilt(this.#itemsTabulator, 'items', () => this.#itemsTabulator.replaceData(this.#items))
    }
  }

  #initItemsTabulator() {
    this.#itemsTabulator = new Tabulator(this.itemsTableTarget, {
      data: this.#items,
      layout: 'fitColumns',
      renderVertical: 'basic',
      autoResize: false,
      columnDefaults: { headerSort: false },
      placeholder: 'Sin ítems agregados',
      locale: TABULATOR_LOCALE,
      langs: TABULATOR_LANGS,
      columns: this.#docType === DOC_TYPE.REP ? [
        { title: 'Descripción', field: 'Descripcion',    widthGrow: 4 },
        { title: 'Monto',       field: 'PrecioUnitario', widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Impuesto',    field: 'ImpuestoNeto',   widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Total',       field: 'MontoTotalLinea',widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Acciones', field: 'id', width: 90, hozAlign: 'center',
          formatter: () =>
            `<button type="button" data-action-type="edit" data-tooltip="Actualizar" class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer"><span class="material-icons text-base">edit</span></button>` +
            `<button type="button" data-action-type="delete" data-tooltip="Eliminar" class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors cursor-pointer"><span class="material-icons text-base">delete</span></button>` },
      ] : [
        { title: 'Código', field: 'CodTipo', widthGrow: 1,
          formatter: (cell) => { const d = cell.getRow().getData(); return d.Regalia ? `${d.CodTipo || ''} <span class="text-amber-600">*</span>` : (d.CodTipo || '') } },
        { title: 'Descripción', field: 'Descripcion',   widthGrow: 3 },
        { title: 'Cantidad',    field: 'Cantidad',       widthGrow: 1, hozAlign: 'left' },
        { title: 'Precio',      field: 'PrecioUnitario', widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Descuento',   field: 'MontoDescuento', widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Impuesto',    field: 'ImpuestoNeto',   widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Total',       field: 'MontoTotalLinea',widthGrow: 1, hozAlign: 'left', formatter: (cell) => this.#fmt(cell.getValue()) },
        { title: 'Acciones', field: 'id', width: 90, hozAlign: 'center',
          formatter: () =>
            `<button type="button" data-action-type="edit" data-tooltip="Actualizar" class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer"><span class="material-icons text-base">edit</span></button>` +
            `<button type="button" data-action-type="delete" data-tooltip="Eliminar" class="p-1.5 text-red-600 rounded hover:bg-red-50 transition-colors cursor-pointer"><span class="material-icons text-base">delete</span></button>` },
      ],
    })
    this.#itemsTabulator.on('tableBuilt', () => { this.#tableBuilt.items = true })
    this.itemsTableTarget.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-action-type]')
      if (!btn) return
      const rowEl = btn.closest('.tabulator-row')
      if (!rowEl) return
      const tRow = (this.#itemsTabulator?.getRows() ?? []).find(r => r.getElement() === rowEl)
      if (!tRow) return
      const id = tRow.getData().id
      if (btn.dataset.actionType === 'edit')   this.editItem({ currentTarget: { dataset: { id } } })
      if (btn.dataset.actionType === 'delete') this.removeItem({ currentTarget: { dataset: { id } } })
    })
  }

  // ── CABYS ─────────────────────────────────────────────────
  onCabysInput() {
    clearTimeout(this.#cabysTimer)
    const term = this.itemCabysTarget.value.trim()
    if (!term) { this.cabysAutocompleteTarget.classList.add('hidden'); this.#hideCabysTooltip(); return }
    this.#cabysTimer = setTimeout(() => this.#searchCabys(term), CABYS_DEBOUNCE)
  }
  async #searchCabys(term) {
    const isCode = /^\d+$/.test(term); const param = isCode ? 'codigo' : 'q'
    this.itemCabysLoadingTarget.classList.remove('hidden')
    try {
      const data = await this.#apiFetch(`/api/Cabys?${param}=${encodeURIComponent(term)}`, { headers: { 'API': 'ApiCabysURL' } })
      const list = data?.cabys ?? data?.Data ?? (Array.isArray(data) ? data : [])
      this.#renderCabysAutocomplete(list)
    } catch (_err) { this.cabysAutocompleteTarget.classList.add('hidden') }
    finally { this.itemCabysLoadingTarget.classList.add('hidden') }
  }
  #renderCabysAutocomplete(list) {
    const box = this.cabysAutocompleteTarget; box.innerHTML = ''
    if (!list || !list.length) { box.classList.add('hidden'); this.#hideCabysTooltip(); return }
    list.slice(0, 30).forEach(c => {
      const code = c.codigo ?? c.Codigo ?? c.code ?? ''; const desc = c.descripcion ?? c.Descripcion ?? c.description ?? ''
      const div = document.createElement('div')
      div.className = 'px-3 py-2 hover:bg-blue-50 cursor-pointer text-sm'
      div.textContent = `${code} - ${desc}`
      div.addEventListener('mouseenter', e => this.#showCabysTooltip(c, e))
      div.addEventListener('mousemove', e => this.#positionCabysTooltip(e))
      div.addEventListener('mouseleave', () => this.#hideCabysTooltip())
      div.addEventListener('mousedown', e => { e.preventDefault(); this.itemCabysTarget.value = code; if (desc && !this.itemDescriptionTarget.value) this.itemDescriptionTarget.value = desc; box.classList.add('hidden'); this.#hideCabysTooltip() })
      box.appendChild(div)
    })
    box.classList.remove('hidden')
  }

  #showCabysTooltip(c, event) {
    if (!this.#cabysTooltipEl) return
    const code = c.codigo ?? c.Codigo ?? c.code ?? ''
    const desc = c.descripcion ?? c.Descripcion ?? c.description ?? ''
    const imp = c.impuesto ?? c.Impuesto ?? c.tarifa ?? ''
    const cats = Array.isArray(c.categorias) ? c.categorias : (Array.isArray(c.Categorias) ? c.Categorias : [])
    const esc = (t) => String(t ?? '').replace(/[&<>]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[m]))
    let html = `<div style="font-weight:600;margin-bottom:2px">${esc(code)}</div>`
    html += `<div style="margin-bottom:4px">${esc(desc)}</div>`
    if (imp !== '' && imp != null) html += `<div style="margin-bottom:4px">Impuesto: <b>${esc(imp)}%</b></div>`
    if (cats.length) {
      html += '<div style="color:#9ca3af;margin-bottom:2px">Categorías:</div>'
      html += '<ul style="margin:0;padding-left:14px">' + cats.map(x => `<li>${esc(x)}</li>`).join('') + '</ul>'
    }
    this.#cabysTooltipEl.innerHTML = html
    this.#cabysTooltipEl.style.display = 'block'
    this.#positionCabysTooltip(event)
  }

  #positionCabysTooltip(event) {
    if (!this.#cabysTooltipEl || this.#cabysTooltipEl.style.display === 'none') return
    const pad = 14
    const w = this.#cabysTooltipEl.offsetWidth
    const h = this.#cabysTooltipEl.offsetHeight
    let x = event.clientX + pad
    let y = event.clientY + pad
    if (x + w > window.innerWidth - 8) x = event.clientX - w - pad
    if (y + h > window.innerHeight - 8) y = window.innerHeight - h - 8
    this.#cabysTooltipEl.style.left = `${Math.max(8, x)}px`
    this.#cabysTooltipEl.style.top = `${Math.max(8, y)}px`
  }

  #hideCabysTooltip() { if (this.#cabysTooltipEl) this.#cabysTooltipEl.style.display = 'none' }

  // ── Terminal / Sucursal ───────────────────────────────────
  async #loadTerminalSucursal() {
    try {
      const data = await this.#apiFetch(`/api/Numbering/GetTerminalSucursal?companyId=${this.#companyId}&docType=${this.#docType}`)
      this.#terminalSucList = data?.Data ?? data ?? []
    } catch (err) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: `Error al cargar terminales: ${err.message}`,
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }
    if (!this.#terminalSucList.length) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'No hay terminales/sucursales configuradas. Configure la numeración.',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      setTimeout(() => { Turbo.visit('/configurations/numbering') }, 1500)
      return
    }
    this.termSucSelectTarget.innerHTML = this.#terminalSucList
      .map((t, i) => `<option value="${i}">Terminal: ${t.Terminal} - Sucursal: ${t.SucursalNum ?? t.Sucursal}</option>`).join('')
    // Selecciona la primera por defecto (igual que el legacy)
    this.termSucSelectTarget.value = '0'
    this.onTermSucChange()
  }

  onTermSucChange() {
    const idx = this.termSucSelectTarget.value
    const sel = idx === '' ? null : this.#terminalSucList[Number(idx)]
    if (sel) { this.#terminal = String(sel.Terminal); this.#sucursal = String(sel.SucursalNum ?? sel.Sucursal) }
    else { this.#terminal = '0'; this.#sucursal = '0' }
  }

  #recalcTotals() {
    this.#subTotal = 0; this.#impuestos = 0; this.#descuento = 0; this.#total = 0
    this.#items.forEach(i => { this.#subTotal += i.MontoTotal; this.#impuestos += i.ImpuestoNeto || 0; this.#descuento += i.MontoDescuento; this.#total += i.MontoTotalLinea })
    this.totalSubtotalTarget.textContent = this.#fmt(this.#subTotal)
    this.totalImpuestosTarget.textContent = this.#fmt(this.#impuestos)
    this.totalDescuentoTarget.textContent = this.#fmt(this.#descuento)
    this.totalTotalTarget.textContent = this.#fmt(this.#total)
    if (this.#mediosPago.length === 1) { this.#mediosPago[0].monto = this.#total; this.#renderMediosPago() }
  }

  async submitDocument() {
    const refCodigo = this.#references[0]?.codigo
    if (this.#docType !== DOC_TYPE.FEC || refCodigo !== CodigoRefList[0].Id) {
      const zero = this.#items.filter(i => Number(i.PrecioUnitario) === 0 && !i.Regalia && (!i.ImpCodigo || i.ImpCodigo === '' || i.ImpCodigo === '00'))
      if (zero.length) {
        Swal.fire({
          toast: true,
          position: 'top-end',
          icon: 'info',
          title: 'Existen ítems con precio 0 sin impuesto válido. Revíselos antes de continuar.',
          showConfirmButton: false,
          timer: 3000,
          timerProgressBar: true
        })
        return
      }
    }
    const errors = this.#validateDocument()
    if (errors.length) {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: errors[0],
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      return
    }
    if (this.#terminal === '0' || this.#sucursal === '0') {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'warning',
        title: 'Seleccione Terminal y Sucursal',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
      this.termSucSelectTarget.focus()
      return
    }
    this.#showLoading('Creando documento, espere por favor…')
    try {
      const resp = await this.#apiFetch('/api/Documents/CreateDocumentManual', { method: 'POST', body: JSON.stringify(this.#buildPayload()), headers: { 'API': 'ApiFEUrl' } })
      this.#hideLoading()
      this.#handleCreateResponse(resp)
    } catch (err) {
      this.#hideLoading()
      Swal.fire({
        icon: 'error',
        title: 'Error al crear el documento',
        text: err.message || 'Error al crear el documento',
        confirmButtonText: 'Aceptar'
      })
    }
  }

  #validateDocument() {
    const errors = []
    if (!this.#items.length) errors.push('Debe agregar al menos un ítem')
    const isNote = [DOC_TYPE.ND, DOC_TYPE.NC].includes(this.#docType)
    if (!isNote && this.#docType !== DOC_TYPE.REP && !this.rcprNombreTarget.value.trim()) errors.push('El nombre del cliente es requerido')
    // Tipo de identificación — requerido para todos
    if (!this.rcprIdeTipoTarget.value) errors.push('Seleccione el tipo de identificación')

    // Identificación — requerida para FE, FEE, FEC, REP
    if ([DOC_TYPE.FE, DOC_TYPE.FEE, DOC_TYPE.FEC, DOC_TYPE.REP].includes(this.#docType)) {
      const num = this.rcprIdeNumeroTarget.value; const cfg = ID_LENGTH[this.rcprIdeTipoTarget.value]
      if (!num.trim()) errors.push('La identificación es requerida')
      else if (cfg && (num.length < cfg.min || num.length > cfg.max)) errors.push(`La identificación debe tener entre ${cfg.min} y ${cfg.max} dígitos`)
    }

    // Actividad económica del emisor — requerida para FE, FEE, TE
    if ([DOC_TYPE.FE, DOC_TYPE.FEE, DOC_TYPE.TE].includes(this.#docType)) {
      const actInterno = (this.codigoActividadInternoTarget.dataset.code || this.codigoActividadInternoTarget.value || '').trim()
      if (!actInterno) errors.push('El código de actividad económica del emisor es requerido')
    }

    // Actividad económica del receptor — requerida para FEC
    if (this.#docType === DOC_TYPE.FEC && !this.codigoActividadExternoTarget.value.trim()) {
      errors.push('El código de actividad económica del receptor es requerido')
    }

    // Teléfono — opcional, pero si se digita debe ser numérico entre 8 y 20 caracteres
    const telVal = this.telefonoTarget.value.trim()
    if (telVal) {
      if (!/^\d+$/.test(telVal))          errors.push('El teléfono debe contener solo números')
      else if (telVal.length < 8)         errors.push('El teléfono debe tener al menos 8 dígitos')
      else if (telVal.length > 20)        errors.push('El teléfono no puede superar 20 dígitos')
    }

    // Ubicación — requerida para FEC con id 01-04 (emisor domiciliado)
    if (this.#docType === DOC_TYPE.FEC) {
      const idTipoFEC = this.rcprIdeTipoTarget.value
      if (idTipoFEC !== '05' && idTipoFEC !== '06') {
        if (!this.provinciaTarget.value)                  errors.push('La provincia del emisor es requerida')
        if (!this.cantonTarget.value)                     errors.push('El cantón del emisor es requerido')
        if (!this.distritoTarget.value)                   errors.push('El distrito del emisor es requerido')
        const senas = this.otrasSenasTarget.value.trim()
        if (!senas)                                       errors.push('La dirección del emisor es requerida')
        else if (senas.length < 5)                        errors.push('La dirección del emisor debe tener al menos 5 caracteres')
        else if (senas.length > 250)                      errors.push('La dirección del emisor no puede superar 250 caracteres')
      } else if (idTipoFEC === '06') {
        // No contribuyente: si ingresó dirección, validar longitud
        const senas = this.otrasSenasTarget.value.trim()
        if (senas && senas.length < 5)   errors.push('La dirección del emisor debe tener al menos 5 caracteres')
        if (senas && senas.length > 250) errors.push('La dirección del emisor no puede superar 250 caracteres')
      }
    }
    // Otros tipos: ubicación opcional (condición 2 — aplica si el receptor tiene domicilio en el país)
    if (this.condicionVentaTarget.value === '99' && !this.condicionVentaOtrosTarget.value.trim()) errors.push('Indique el detalle de la condición de venta')
    // tipoDoc es obligatorio para ND, NC, FEC, REP
    const refRequired = [DOC_TYPE.ND, DOC_TYPE.NC, DOC_TYPE.FEC, DOC_TYPE.REP].includes(this.#docType)
    this.#references.forEach((r, idx) => {
      const lbl = this.#references.length > 1 ? ` (ref. ${idx + 1})` : ''
      if (refRequired && !r.tipoDoc) { errors.push(`Seleccione el tipo de documento de referencia${lbl}`); return }
      // Campos internos: requeridos solo cuando tipoDoc está seleccionado (cualquier doc type)
      if (!r.tipoDoc) return
      if (r.tipoDoc === '99' && !r.tipoDocOtro?.trim()) errors.push(`Indique el tipo de documento OTRO de referencia${lbl}`)
      // REP: número y fechaEmision siempre requeridos (condición 1)
      if (this.#docType === DOC_TYPE.REP) {
        if (!r.numero?.trim())  errors.push(`El número de referencia es requerido${lbl}`)
        if (!r.fechaEmision)    errors.push(`La fecha de emisión de referencia es requerida${lbl}`)
      }
      // Resto requeridos cuando tipoDoc ≠ '13' (facturación mes vencido)
      if (r.tipoDoc !== '13') {
        if (this.#docType !== DOC_TYPE.REP && !r.numero?.trim()) errors.push(`El número de referencia es requerido${lbl}`)
        if (this.#docType !== DOC_TYPE.REP && !r.fechaEmision)   errors.push(`La fecha de emisión de referencia es requerida${lbl}`)
        if (!r.codigo) errors.push(`Seleccione el código de referencia${lbl}`)
        if (r.codigo === '99' && !r.codigoOtro?.trim()) errors.push(`Indique el código OTRO de referencia${lbl}`)
        if (!r.razon?.trim()) errors.push(`La razón de referencia es requerida${lbl}`)
      }
    })
    const sumMedios = this.#mediosPago.reduce((s, m) => s + (Number(m.monto) || 0), 0)
    if (Math.abs(sumMedios - this.#total) > 0.005) errors.push('La suma de los medios de pago debe ser igual al total')
    return errors
  }

  #buildPayload() {
    const isFEC = this.#docType === DOC_TYPE.FEC
    const correos = isFEC ? this.#emails.filter(e => EMAIL_RE.test(e)).join(';') : this.emailTarget.value
    const idTipo = this.rcprIdeTipoTarget.value
    const actExterno = this.codigoActividadExternoTarget.value
    const actInternoRaw = (this.codigoActividadInternoTarget.dataset.code || this.codigoActividadInternoTarget.value || '').trim()
    const actInterno = actInternoRaw.includes(' - ') ? actInternoRaw.split(' - ')[0].trim() : actInternoRaw
    const totals = this.#computeDocTotals()

    // Ubicación del emisor (solo aplica a FEC; en el resto va '0'/null)
    let emsrProv = isFEC ? this.provinciaTarget.value : '0'
    let emsrCanton = isFEC ? this.cantonTarget.value : '0'
    let emsrDist = isFEC ? this.distritoTarget.value : '0'
    let emsrBarrio = isFEC ? (this.barrioTarget.selectedOptions[0]?.text === '-- Seleccione --' ? null : this.barrioTarget.selectedOptions[0]?.text || null) : null
    let emsrSenas = isFEC ? (this.otrasSenasTarget.value || null) : null
    if (isFEC && (idTipo === '05' || idTipo === '06') && emsrProv === '0') {
      emsrProv = ''; emsrCanton = ''; emsrDist = ''; emsrBarrio = ''; emsrSenas = ''
    }

    const documento = {
      Id: this.#docId || 0,
      CodigoActividadEmisor: isFEC ? actExterno : actInterno,
      CodigoActividadReceptor: !isFEC ? actExterno : actInterno,
      CondicionVenta: this.condicionVentaTarget.value,
      CondicionVentaOtros: this.condicionVentaOtrosTarget.value?.trim() ? this.condicionVentaOtrosTarget.value : null,
      PlazoCredito: Number(this.plazoCreditoTarget.value) || 0,
      Situacion: 1,
      FechaFact: this.#nowIso(),
      ErrDetails: '',
      CompanyId: parseInt(this.#companyId),
      Sucursal: Number(this.#sucursal),
      Terminal: Number(this.#terminal),
      DocType: this.#docType,
      ConsecutivoId: '0',
      Consecutivo: '0',
      EmsrNombre: isFEC ? this.rcprNombreTarget.value : '',
      EmsrIdeTipo: isFEC ? idTipo : '',
      EmsrIdeNumero: isFEC ? this.rcprIdeNumeroTarget.value : '',
      EmsrRegistrofiscal8707: isFEC ? this.registroFiscal8707Target.value : '',
      EmsrNombreComercial: null,
      EmsrUbProvincia: emsrProv, EmsrUbCanton: emsrCanton, EmsrUbDistrito: emsrDist,
      EmsrUbBarrio: emsrBarrio, EmsrUbOtrasSenas: emsrSenas,
      EmsrTlfCodigoPais: 506,
      EmsrTlfNumTelefono: isFEC ? (this.telefonoTarget.value || null) : null,
      EmsrCorreoElectronico: isFEC ? (correos?.trim() ? correos : null) : null,
      EmsrOtrasSenasExtranjero: !isFEC && idTipo === '05' ? this.otrasSenasExtranjeroTarget.value : null,
      RcprOtrasSenasExtranjero: isFEC && idTipo === '05' ? this.otrasSenasExtranjeroTarget.value : null,
      RcprNombre: this.rcprNombreTarget.value,
      RcprIdeTipo: !isFEC ? idTipo : '',
      RcprIdeNumero: !isFEC ? this.rcprIdeNumeroTarget.value : '',
      RcprIdentificacionExtranjero: '',
      RcprNombreComercial: null,
      RcprUbProvincia: (!isFEC && this.#docType !== DOC_TYPE.FEE) ? this.provinciaTarget.value : '',
      RcprUbCanton: (!isFEC && this.#docType !== DOC_TYPE.FEE) ? this.cantonTarget.value : '',
      RcprUbDistrito: (!isFEC && this.#docType !== DOC_TYPE.FEE) ? this.distritoTarget.value : '',
      RcprUbBarrio: (!isFEC && this.#docType !== DOC_TYPE.FEE) ? (this.barrioTarget.selectedOptions[0]?.text === '-- Seleccione --' ? null : this.barrioTarget.selectedOptions[0]?.text || null) : null,
      RcprUbOtrasSenas: (!isFEC && this.#docType !== DOC_TYPE.FEE) ? (this.otrasSenasTarget.value || null) : null,
      RcprTlfCodigoPais: 506,
      RcprTlfNumTelefono: !isFEC ? (this.telefonoTarget.value || '') : '',
      RcprCorreoElectronico: !isFEC ? (correos?.trim() ? correos : null) : null,
      RcprCorreoElectronicoCC: !isFEC ? (this.emailCCTarget.value?.trim() ? this.emailCCTarget.value : null) : null,
      CodigoMoneda: this.currencyTarget.value,
      TipoCambio: String(Number(this.exchangeRateTarget.value) || 1),
      ...totals,
      OtroTexto: '', OtTipoDocumento: '', OtNumeroIdentidadTercero: '', OtNombreTercero: '',
      OtDetalle: '', OtPorcentaje: 0, OtMontoCargo: 0,
      V_LineaDetalle: this.#items.map((i, idx) => this.#mapItemForApi(i, idx)),
      V_MedioPago: this.#mediosPago.map(m => ({
        TipoMedioPago: m.tipo, MedioPagoOtros: m.otros?.trim() ? m.otros : '', TotalMedioPago: Number(m.monto) || 0,
      })),
      V_InfReferencia: this.#mapReferences(),
    }
    return { documento, UserId: this.#session.UserId ?? '' }
  }

  #mapReferences() {
    const refs = this.#references
      .filter(r => r.tipoDoc?.trim())
      .map((r, index) => ({
        Id: index + 1,
        InfRefTipoDoc: r.tipoDoc?.trim() ? r.tipoDoc : null,
        InfRefNumero: r.numero?.trim() ? r.numero : null,
        InfRefFechaEmision: r.fechaEmision ? new Date(r.fechaEmision).toISOString() : null,
        InfRefCodigo: r.codigo?.trim() ? r.codigo : null,
        InfRefRazon: r.razon?.trim() ? r.razon : null,
        InfCodigoReferenciaOTRO: r.codigoOtro?.trim() ? r.codigoOtro : null,
        InfRefTipoDocRefOTRO: r.tipoDocOtro?.trim() ? r.tipoDocOtro : null,
      }))
    return refs.length ? refs : null
  }

  // Réplica de la sumatoria de totales del servicio legacy (CreateDocument).
  #computeDocTotals() {
    const EXEMPT = '10', NOSUBJ = ['01', '11'], IVA = ['01', '07', '08', '99'], FAB_EXEMPT = '02'
    const isREP = this.#docType === DOC_TYPE.REP
    let sGrav = 0, sEx = 0, sExo = 0, sNoSuj = 0, mGrav = 0, mEx = 0, mExo = 0, mNoSuj = 0
    let descuentos = 0, impuesto = 0, impAsum = 0, ventaREP = 0
    this.#items.forEach(i => {
      const isProd = i.ProductType === '01'
      const codTar = i.CodigoTarifa || ''
      const ivaFab = i.IVACobradoFabrica || ''
      const esIVA = IVA.includes(i.ImpCodigo)
      const gravMerc = ivaFab !== FAB_EXEMPT && esIVA && codTar !== EXEMPT && !NOSUBJ.includes(codTar)
      const gravServ = esIVA && codTar !== EXEMPT && !NOSUBJ.includes(codTar)
      const exo = i.Exoneracion
      const tieneExo = exo && exo.ETipoDocumento && exo.ETipoDocumento !== '00'
      if (tieneExo) {
        const impTarifa = i.ImpTarifa || 0
        const pExo = (exo.ETarifaExonerada && impTarifa) ? (exo.ETarifaExonerada / impTarifa) * 100 : 0
        const pNoExo = 100 - pExo
        if (isProd) { mExo += (i.MontoTotal * pExo) / 100; if (gravMerc) mGrav += (i.MontoTotal * pNoExo) / 100 }
        else { sExo += (i.MontoTotal * pExo) / 100; if (gravServ) sGrav += (i.MontoTotal * pNoExo) / 100 }
      } else {
        if (isProd) { if (codTar === EXEMPT) mEx += i.MontoTotal; else if (gravMerc) mGrav += i.MontoTotal }
        else { if (codTar === EXEMPT) sEx += i.MontoTotal; else if (gravServ) sGrav += i.MontoTotal }
      }
      if (NOSUBJ.includes(codTar)) { if (isProd) mNoSuj += i.MontoTotal; else sNoSuj += i.MontoTotal }
      descuentos += i.MontoDescuento
      if (i.ImpuestoNeto != null) impuesto += i.ImpuestoNeto
      impAsum += i.ImpuestoAsumidoEmisorFabrica || 0
      if (isREP) ventaREP += i.MontoTotal
    })
    const fx = n => parseFloat((n || 0).toFixed(5))
    const TotalServGravados = fx(sGrav), TotalServExentos = fx(sEx), TotalServExonerado = fx(sExo), TotalServNoSujeto = fx(sNoSuj)
    const TotalMercanciasGravadas = fx(mGrav), TotalMercanciasExentas = fx(mEx), TotalMercExonerada = fx(mExo), TotalMercNoSujeta = fx(mNoSuj)
    const TotalGravado = fx(TotalServGravados + TotalMercanciasGravadas)
    const TotalExento = fx(TotalServExentos + TotalMercanciasExentas)
    const TotalExonerado = fx(TotalServExonerado + TotalMercExonerada)
    const TotalNoSujeto = fx(TotalServNoSujeto + TotalMercNoSujeta)
    const TotalVenta = fx(isREP ? ventaREP : (TotalGravado + TotalExento + TotalExonerado + TotalNoSujeto))
    const TotalDescuentos = fx(descuentos)
    const TotalVentaNeta = fx(TotalVenta - TotalDescuentos)
    const TotalImpuesto = fx(impuesto)
    const TotalIVADevuelto = 0, TotalOtrosCargos = 0
    const TotalImpAsumEmisorFabrica = fx(impAsum)
    const TotalComprobante = fx(isREP ? (TotalVenta + TotalImpuesto) : (TotalVentaNeta + TotalImpuesto + TotalOtrosCargos + TotalIVADevuelto))
    return {
      TotalServGravados, TotalServExentos, TotalServExonerado, TotalServNoSujeto,
      TotalMercanciasGravadas, TotalMercanciasExentas, TotalMercExonerada, TotalMercNoSujeta,
      TotalGravado, TotalExento, TotalExonerado, TotalNoSujeto, TotalVenta, TotalDescuentos,
      TotalVentaNeta, TotalImpuesto, TotalImpAsumEmisorFabrica, TotalIVADevuelto, TotalOtrosCargos, TotalComprobante,
    }
  }

  #nowIso() {
    const d = new Date(); const pad = (n, l = 2) => String(n).padStart(l, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(Math.floor(d.getMilliseconds() / 10))}`
  }

  // Construye un ILineaDetalle fiel al modelo del backend (validado contra legacy Angular).
  #mapItemForApi(i, idx) {
    const exo = i.Exoneracion || {}
    const tieneExo = exo.ETipoDocumento && exo.ETipoDocumento !== '00'
    return {
      Id: 0,
      NumeroLinea: idx + 1,
      Cantidad: i.Cantidad,
      UnidadMedida: i.UnidadMedida,
      UnidadMedidaComercial: i.UnidadMedidaComercial || '',
      Detalle: i.Descripcion,
      PrecioUnitario: i.PrecioUnitario,
      MontoTotal: i.MontoTotal,
      MontoDescuento: i.MontoDescuento,
      // Legacy siempre envía 'N/A', no string vacío
      NaturalezaDescuento: 'N/A',
      SubTotal: i.SubTotal,
      MontoTotalLinea: i.MontoTotalLinea,
      PartidaArancelaria: '',
      Codigo: i.Cabys,
      CodTipo: '04',
      CodCodigo: i.CodTipo,
      BaseImponible: i.BaseImponible || null,
      ImpCodigo: i.ImpCodigo,
      ImpTarifa: i.ImpTarifa ?? null,
      ImpMonto: i.ImpMonto ?? null,
      ImpCodigoTarifa: i.CodigoTarifa || null,
      ImpFactorIVA: null,
      // Siempre presente, fijo en 0 (no aplica en CR)
      ImpMontoExportacion: 0,
      ImpuestoNeto: i.ImpuestoNeto ?? null,
      ETipoDocumento: tieneExo ? exo.ETipoDocumento : '',
      // Legacy envía string vacío cuando no hay exoneración, no null
      ETipoDocumentoOtro: tieneExo ? (exo.ETipoDocumentoOTRO || '') : '',
      EFechaEmision: tieneExo && exo.EFechaEmision ? new Date(exo.EFechaEmision).toISOString() : '',
      ENumeroDocumento: tieneExo ? (exo.ENumeroDocumento || '') : '',
      ENombreInstitucion: tieneExo ? (exo.ENombreInstitucion || '') : '',
      // Legacy envía string vacío cuando no hay exoneración, no null
      ENombreInstitucionOtros: tieneExo ? (exo.ENombreInstitucionOtros || '') : '',
      ETarifaExonerada: tieneExo ? (exo.ETarifaExonerada ?? null) : null,
      EMontoExoneracion: tieneExo ? (exo.EMontoExoneracion ?? null) : null,
      // Legacy envía 0 cuando no hay exoneración, no null
      EArticulo: tieneExo ? (Number(exo.EArticulo) || 0) : 0,
      EInciso: tieneExo ? (Number(exo.EInciso) || 0) : 0,
      Descuento: i.DescuentoPct || 0,
      regalia: !!i.Regalia,
      // Legacy envía null cuando vacío, no string vacío
      RegistroMedicamento: i.RegistroMedicamento?.trim() ? i.RegistroMedicamento : null,
      FormaFarmaceutica: i.FormaFarmaceutica?.trim() ? i.FormaFarmaceutica : null,
      TipoTransaccion: i.TipoTransaccion || '01',
      IVACobradoFabrica: i.IVACobradoFabrica || null,
      NumeroVINoSerie: i.NumeroVINoSerie || '',
      // Legacy envía string vacío cuando no aplica, no null
      ImpCodigoImpuestoOTRO: i.ImpTipoOtro || '',
      DCodigoDescuento: i.CodigoDescuento || null,
      DCodigoDescuentoOTRO: i.CodigoDescuentoOtro || null,
      // Legacy envía null cuando es 0 (no cuando el campo es 0)
      ImpuestoAsumidoEmisorFabrica: i.ImpuestoAsumidoEmisorFabrica || null,
      ImpCantidadUnidadMedida: i.ImpCantidadUnidadMedida || null,
      ImpPorcentaje: null,
      ImpProporcion: null,
      ImpVolumenUnidadConsumo: i.ImpVolumenUnidadConsumo || null,
      ImpImpuestoUnidad: null,
      // Legacy siempre envía el array (vacío si no hay surtidos)
      DetalleSurtido: (i.Surtidos ?? []).map((s, si) => ({
        Id: si + 1,
        CodigoCABYSSurtido: s.Cabys || '',
        CodTipoSurtido: s.Tipo || '01',
        CodCodigoSurtido: s.Codigo || '',
        CantidadSurtido: s.Cantidad || 0,
        UnidadMedidaSurtido: s.Unidad || '',
        UnidadMedidaComercialSurtido: '',
        Detalle: s.Descripcion || '',
        PrecioUnitarioSurtido: s.Precio || 0,
        MontoTotalSurtido: (s.Precio || 0) * (s.Cantidad || 0),
        SubTotalSurtido: (s.Precio || 0) * (s.Cantidad || 0),
        MontoDescuentoSurtido: 0,
        CodigoDescuentoSurtido: '',
        DescuentoSurtidoOtros: '',
        BaseImponibleSurtido: null,
        IVACobradoFabricaSurtoSurtido: null,
        ImpCodigoImpuestoSurtido: null,
        ImpCodigoImpuestoOTROSurtido: null,
        ImpTarifaIVASurtido: null,
        ImpTarifaSurtido: s.Tarifa ?? null,
        ImpMontoSurtido: null,
        ImpCantidadUnidadMedidaSurtido: null,
        ImpPorcentajeSurtido: null,
        ImpProporcionSurtido: null,
        ImpVolumenUnidadConsumoSurtido: null,
        ImpImpuestoUnidadSurtido: null,
      })),
    }
  }

  #handleCreateResponse(resp) {
    if (resp?.result === true && resp?.HaciendaInfo != null) {
      this.successTitleTarget.textContent = 'Documento creado correctamente'
      this.successSubtitleTarget.textContent = `Estado: ${resp.HaciendaInfo.Estado ?? ''} | Clave: ${resp.HaciendaInfo.Clave ?? ''}`
      this.successModalTarget.classList.remove('hidden'); this.#docId = 0; this.btnSubmitLabelTarget.textContent = 'Crear'
    } else if (resp?.result === true && resp?.HaciendaInfo == null) {
      this.#docId = resp.DocId ?? 0
      this.btnSubmitLabelTarget.textContent = 'Reenviar'
      Swal.fire({
        icon: 'warning',
        title: 'Documento creado con errores',
        text: resp?.errorInfo?.Message ?? resp?.Message ?? '',
        confirmButtonText: 'Aceptar'
      })
    } else {
      Swal.fire({
        toast: true,
        position: 'top-end',
        icon: 'error',
        title: resp?.errorInfo?.Message ?? resp?.Message ?? 'Error al crear el documento',
        showConfirmButton: false,
        timer: 3000,
        timerProgressBar: true
      })
    }
  }

  closeSuccessModal() { this.successModalTarget.classList.add('hidden'); window.location.reload() }


  // ── REP: panel de pago ───────────────────────────────────────────────────
  openRepPayment() {
    this.#editingItemId = null
    this.repPaymentPanelTitleTarget.textContent = 'Agregar pago'
    this.#resetRepPaymentForm()
    this.#openPanel(this.repPaymentPanelTarget, this.repPaymentBackdropTarget)
  }

  closeRepPayment() {
    this.#closePanel(this.repPaymentPanelTarget, this.repPaymentBackdropTarget)
  }

  #loadRepPaymentForEdit(item) {
    this.repPaymentPanelTitleTarget.textContent = 'Editar pago'
    this.repPaymentDescTarget.value = item.Descripcion ?? ''
    this.repPaymentMontoTarget.value = item.PrecioDigitado ?? item.PrecioUnitario ?? ''
    this.repPaymentTaxTypeTarget.value = item.ImpCodigo ?? ''
    this.repPaymentTaxOtroTarget.value = item.ImpTipoOtro ?? ''
    this.repPaymentCodigoTarifaTarget.value = item.CodigoTarifa ?? ''
    this.repPaymentTaxRateTarget.value = item.ImpTarifa ?? 0
    this.onRepPaymentTaxTypeChange()
    this.recalcRepPayment()
    this.#openPanel(this.repPaymentPanelTarget, this.repPaymentBackdropTarget)
  }

  #resetRepPaymentForm() {
    this.repPaymentDescTarget.value = ''
    this.repPaymentMontoTarget.value = ''
    this.repPaymentTaxTypeTarget.value = ''
    this.repPaymentTaxOtroTarget.value = ''
    this.repPaymentCodigoTarifaTarget.value = ''
    this.repPaymentTaxRateTarget.value = '0'
    this.repPaymentTaxOtroWrapTarget.classList.add('hidden')
    this.repPaymentCodigoTarifaWrapTarget.classList.add('hidden')
    this.repPaymentTaxRateTarget.readOnly = true
    this.repPaymentTaxRateTarget.classList.add('bg-gray-50', 'cursor-default')
    this.repPaymentSubTotalTarget.textContent = this.#fmt(0)
    this.repPaymentTaxAmountTarget.textContent = this.#fmt(0)
    this.repPaymentTotalTarget.textContent = this.#fmt(0)
  }

  onRepPaymentTaxTypeChange() {
    const code = this.repPaymentTaxTypeTarget.value
    const isIVA = code === '01'
    this.#showTarget(this.repPaymentTaxOtroWrapTarget, code === '99')
    this.repPaymentTaxOtroRequiredTarget.classList.toggle('hidden', code !== '99')
    if (code !== '99') { this.repPaymentTaxOtroTarget.value = ''; this.repPaymentTaxOtroCountTarget.textContent = '0' }
    this.#showTarget(this.repPaymentCodigoTarifaWrapTarget, isIVA)
    const rateEditable = code === '99'
    this.repPaymentTaxRateTarget.readOnly = !rateEditable
    this.repPaymentTaxRateTarget.classList.toggle('bg-gray-50', !rateEditable)
    this.repPaymentTaxRateTarget.classList.toggle('cursor-default', !rateEditable)
    if (isIVA && !this.repPaymentCodigoTarifaTarget.value) {
      this.repPaymentCodigoTarifaTarget.value = '08'
      this.onRepPaymentCodigoTarifaChange()
      return
    }
    this.recalcRepPayment()
  }

  recalcRepPayment() {
    const monto = Number(this.repPaymentMontoTarget.value) || 0
    const taxRate = Number(this.repPaymentTaxRateTarget.value) || 0
    const impMonto = monto * (taxRate / 100)
    const total = monto + impMonto
    this.repPaymentSubTotalTarget.textContent = this.#fmt(monto)
    this.repPaymentTaxAmountTarget.textContent = this.#fmt(impMonto)
    this.repPaymentTotalTarget.textContent = this.#fmt(total)
  }

  onRepPaymentCodigoTarifaChange() {
    const sel = CodigoTarifaList.find(c => c.Id === this.repPaymentCodigoTarifaTarget.value)
    if (sel) this.repPaymentTaxRateTarget.value = String(sel.Rate)
    this.recalcRepPayment()
  }

  onRepPaymentTaxOtroInput() {
    const len = this.repPaymentTaxOtroTarget.value.length
    this.repPaymentTaxOtroCountTarget.textContent = String(len)
  }

  saveRepPayment() {
    const desc = this.repPaymentDescTarget.value.trim()
    if (!desc) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'La descripción es requerida', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    const monto = Number(this.repPaymentMontoTarget.value) || 0
    if (monto <= 0) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El monto de pago debe ser mayor a 0', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    if (!this.repPaymentTaxTypeTarget.value) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El tipo de impuesto es requerido', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    if (this.repPaymentTaxTypeTarget.value === '99') {
      const otros = this.repPaymentTaxOtroTarget.value.trim()
      if (!otros) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El detalle del impuesto es requerido cuando el tipo es Otros', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
      if (otros.length < 5) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El detalle del impuesto debe tener al menos 5 caracteres', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    }
    const taxRate = Number(this.repPaymentTaxRateTarget.value) || 0
    if (this.repPaymentTaxTypeTarget.value === '99' && taxRate < 0) { Swal.fire({ toast: true, position: 'top-end', icon: 'warning', title: 'El % de impuesto debe ser 0 o mayor', showConfirmButton: false, timer: 3000, timerProgressBar: true }); return }
    const impMonto = parseFloat((monto * (taxRate / 100)).toFixed(5))
    const lineTotal = parseFloat((monto + impMonto).toFixed(5))
    const item = {
      id: this.#editingItemId ?? ++this.#idItemSeq,
      Cabys: '',
      CodTipo: '',
      Descripcion: desc,
      ProductType: '02',
      TipoTransaccion: '01',
      Cantidad: 1,
      PrecioUnitario: monto,
      PrecioDigitado: monto,
      DescuentoPct: 0,
      CodigoDescuento: '',
      CodigoDescuentoOtro: '',
      UnidadMedida: 'Sp',
      UnidadMedidaComercial: '',
      RegistroMedicamento: '',
      FormaFarmaceutica: '',
      NumeroVINoSerie: '',
      ImpCodigo: this.repPaymentTaxTypeTarget.value,
      ImpTipoOtro: this.repPaymentTaxOtroTarget.value,
      BebidaJabon: '',
      CodigoTarifa: this.repPaymentCodigoTarifaTarget.value,
      ImpTarifa: taxRate,
      IVACobradoFabrica: '',
      ImpuestoAsumidoEmisorFabrica: 0,
      BaseImponible: monto,
      ImpCantidadUnidadMedida: 0,
      ImpVolumenUnidadConsumo: 0,
      MontoTotal: monto,
      MontoDescuento: 0,
      SubTotal: monto,
      ImpMonto: impMonto,
      ImpuestoNeto: impMonto,
      MontoTotalLinea: lineTotal,
      Regalia: false,
      Exoneracion: { ETipoDocumento: '00', ETipoDocumentoOTRO: '', ENumeroDocumento: '', EFechaEmision: this.#today(), EArticulo: 0, EInciso: 0, ENombreInstitucion: '', ENombreInstitucionOtros: '', ETarifaExonerada: 0, EMontoExoneracion: 0 },
      Surtidos: [],
    }
    if (this.#editingItemId != null) { const idx = this.#items.findIndex(i => i.id === this.#editingItemId); if (idx !== -1) this.#items[idx] = item }
    else this.#items.push(item)
    this.#renderItems()
    this.#recalcTotals()
    this.closeRepPayment()
  }

  #openPanel(panel, backdrop) { backdrop.classList.remove('hidden'); panel.classList.remove('translate-x-full'); document.body.style.overflow = 'hidden' }
  #closePanel(panel, backdrop) { panel.classList.add('translate-x-full'); backdrop.classList.add('hidden'); document.body.style.overflow = '' }
  #showLoading(msg = 'Cargando…') { this.loadingMessageTarget.textContent = msg; this.loadingOverlayTarget.classList.remove('hidden') }
  #hideLoading() { this.loadingOverlayTarget.classList.add('hidden') }
  #showTarget(el, visible) { el.classList.toggle('hidden', !visible) }

  #fillSelect(select, items, idKey, labelKey, placeholder = null) {
    select.innerHTML = ''
    if (placeholder) { const opt = document.createElement('option'); opt.value = ''; opt.textContent = placeholder; select.appendChild(opt) }
    items.forEach(it => { const opt = document.createElement('option'); opt.value = it[idKey]; opt.textContent = it[labelKey]; select.appendChild(opt) })
  }
  #optionsHtml(items, idKey, labelKey, selected, placeholder = null) {
    let html = placeholder ? `<option value="">${placeholder}</option>` : ''
    items.forEach(it => { const sel = String(it[idKey]) === String(selected) ? ' selected' : ''; html += `<option value="${it[idKey]}"${sel}>${it[labelKey]}</option>` })
    return html
  }
  #unitCode() {
    const raw = (this.itemUnitTarget.dataset.code || this.itemUnitTarget.value || '').trim()
    return raw.includes(' - ') ? raw.split(' - ')[0].trim() : raw
  }
  #unitLabel(code) {
    const u = [...this.#unitProducto, ...this.#unitServicio].find(x => String(x.value) === String(code))
    return u ? `${u.value} - ${u.annotation}` : (code || '')
  }
  #uniqueBy(arr, key) { const seen = new Set(); return arr.filter(o => (seen.has(o[key]) ? false : seen.add(o[key]))) }
  #today() { const d = new Date(); const pad = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` }
  #fmt(value) { const num = parseFloat(value); if (isNaN(num)) return `${this.#selectedCurrencySymbol} 0,00`; return `${this.#selectedCurrencySymbol} ${num.toLocaleString('es-CR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}` }
  async #fetchJson(path) { const res = await fetch(path); if (!res.ok) throw new Error(`No se pudo cargar ${path}`); return res.json() }

  // Variante de #apiFetch que devuelve también los headers de respuesta (para paginación).
  async #apiFetchRaw(url, options = {}) {
    const apiTarget = options.headers?.['API'] ?? 'ApiAppUrl'
    const token = (Storage.get('Session') || {}).access_token
    const company = SStore.get('CurrentCompany')
    const companyId = company?.companyId ?? this.#companyId
    const headers = {
      'Content-Type': 'application/json', 'API': apiTarget, 'X-Skip-Error-Interceptor': 'true',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(companyId ? { 'Cl-Company-Id': String(companyId) } : {}),
      ...(options.headers || {}),
    }
    const response = await fetch(url, { ...options, headers })
    const clMessage = response.headers.get('cl-message')
    const decoded = clMessage ? (() => { try { return decodeURIComponent(clMessage) } catch { return clMessage } })() : null
    if (!response.ok) { const text = await response.text().catch(() => response.statusText); throw new Error(decoded || text || `HTTP ${response.status}`) }
    const hasBody = response.status !== 204 && response.headers.get('content-length') !== '0' && response.headers.get('content-type')?.includes('application/json')
    if (!hasBody) return { json: { Data: [], Message: decoded || null }, headers: response.headers }
    const json = await response.json()
    if (decoded && !json.Message) json.Message = decoded
    return { json, headers: response.headers }
  }

  async #apiFetch(url, options = {}) {
    const apiTarget = options.headers?.['API'] ?? 'ApiAppUrl'
    const isFESync = apiTarget === 'ApiFEUrl'; const isCabys = apiTarget === 'ApiCabysURL'
    const token = isCabys ? null : (isFESync
      ? (JSON.parse(sessionStorage.getItem('currentFEUser') || '{}')?.access_token ?? null)
      : (Storage.get('Session') || {}).access_token)
    const company = SStore.get('CurrentCompany'); const companyId = isCabys ? null : (company?.companyId ?? this.#companyId)
    const headers = {
      'Content-Type': 'application/json', 'API': apiTarget, 'X-Skip-Error-Interceptor': 'true',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(companyId ? { 'Cl-Company-Id': String(companyId) } : {}),
      ...(options.headers || {}),
    }
    const response = await fetch(url, { ...options, headers })
    const clMessage = response.headers.get('cl-message')
    const decoded = clMessage ? (() => { try { return decodeURIComponent(clMessage) } catch { return clMessage } })() : null
    if (!response.ok) { const text = await response.text().catch(() => response.statusText); throw new Error(decoded || text || `HTTP ${response.status}`) }
    const hasBody = response.status !== 204 && response.headers.get('content-length') !== '0' && response.headers.get('content-type')?.includes('application/json')
    if (!hasBody) return { Message: decoded || null }
    const json = await response.json()
    if (decoded && !json.Message) json.Message = decoded
    return json
  }
}

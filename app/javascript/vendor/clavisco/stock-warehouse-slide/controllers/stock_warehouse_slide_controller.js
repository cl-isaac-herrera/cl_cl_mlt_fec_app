import BaseSlideController from "vendor/clavisco/base/controllers/base_slide_controller"
import { getAPIHeaders } from "lib/api_helpers"
import { TabulatorFull as Tabulator } from 'tabulator-tables'
import Swal from 'sweetalert2'

/**
 * Stock & Warehouse Selection Slide Panel Controller
 *
 * Two modes (set via allowChange in the open event):
 *
 *   allowChange: false → "Visualizar Stock"
 *     - Llama /api/Items/WarehouseAvailabilityByFilter?&ItemCode=X&FilterWarehouse=Y
 *     - Muestra stock del almacén actual de la línea (read-only)
 *
 *   allowChange: true → "Cambiar Almacén"
 *     - No llama API — usa lista de almacenes ya cargada en el documento
 *     - Muestra tabla de selección de almacén (WhsCode, WhsName, BinActivat)
 *     - Al seleccionar llama onConfirm(warehouse)
 *
 * @extends BaseSlideController
 */
export default class extends BaseSlideController {
  static targets = [
    ...BaseSlideController.targets,
    "itemName", "title",
    "tableContainer", "stockTable",
    "emptyState", "loading"
  ]

  static values = {
    ...BaseSlideController.values,
    apiUrl: { type: String, default: "/api/Items" }
  }

  connect() {
    super.connect()

    this.currentItemCode = null
    this.currentWarehouse = null
    this.allowChange = false
    this.warehouses = []
    this.onConfirmCallback = null
    this.tableInstance = null

    this.boundOpen = this.handleOpenEvent.bind(this)
    window.addEventListener("stock-warehouse-slide:open", this.boundOpen)
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("stock-warehouse-slide:open", this.boundOpen)
    if (this.tableInstance) {
      this.tableInstance.destroy()
      this.tableInstance = null
    }
  }

  /**
   * Handle open event
   * detail: { itemCode, itemName, currentWarehouse, allowChange, warehouses, onConfirm }
   */
  async handleOpenEvent(event) {
    if (!event?.detail) return

    const { itemCode, itemName, currentWarehouse, allowChange, warehouses, onConfirm } = event.detail

    this.currentItemCode = itemCode
    this.currentWarehouse = currentWarehouse
    this.allowChange = allowChange === true
    this.warehouses = warehouses || []
    this.onConfirmCallback = onConfirm

    this.itemNameTarget.textContent = itemName || itemCode
    this.titleTarget.textContent = this.allowChange ? 'Cambiar Almacén' : 'Visualizar Stock'

    this.open()

    if (this.allowChange) {
      this.renderWarehouseList()
    } else {
      await this.loadStock(itemCode, currentWarehouse)
    }
  }

  // ============================================
  // MODE: Visualizar Stock
  // Endpoint: GET /api/Items/WarehouseAvailabilityByFilter?&ItemCode=X&FilterWarehouse=Y
  // Angular: ItemsService.GetbyFilter() - items.service.ts línea 119
  // ============================================

  async loadStock(itemCode, warehouseCode) {
    this.showLoading()

    try {
      const url = `${this.apiUrlValue}/WarehouseAvailabilityByFilter?&ItemCode=${encodeURIComponent(itemCode)}&FilterWarehouse=${encodeURIComponent(warehouseCode || '')}`
      const response = await fetch(url, {
        headers: getAPIHeaders({
          successDescription: "Stock de item obtenido",
          errorDescription: "No se pudo obtener el stock del item",
          page: 0,
          pageSize: 10
        })
      })

      if (response.ok) {
        const data = await response.json()
        const stockData = data.Data || []
        this.renderStockTable(stockData)
      } else {
        this.showToast("Error al cargar stock del almacén", "error")
        this.renderEmptyState()
      }
    } catch (error) {
      console.error("Error loading stock:", error)
      this.showToast("Error de conexión al cargar stock", "error")
      this.renderEmptyState()
    } finally {
      this.hideLoading()
    }
  }

  renderStockTable(stockData) {
    if (!stockData || stockData.length === 0) {
      this.renderEmptyState()
      return
    }

    this.hideEmptyState()
    this.tableContainerTarget.classList.remove("hidden")

    if (this.tableInstance) this.tableInstance.destroy()

    this.tableInstance = new Tabulator(this.stockTableTarget, {
      data: stockData,
      layout: "fitColumns",
      height: "420px",
      placeholder: "Sin datos de stock",
      columns: [
        { title: "Código",        field: "WhsCode",    headerSort: false, width: 90 },
        { title: "Almacén",       field: "WhsName",    headerSort: false, minWidth: 150 },
        { title: "Orden",         field: "OnOrder",    headerSort: false, width: 90,  hozAlign: "right", formatter: (c) => parseFloat(c.getValue() || 0).toFixed(2) },
        { title: "Comprometido",  field: "IsCommited", headerSort: false, width: 120, hozAlign: "right", formatter: (c) => parseFloat(c.getValue() || 0).toFixed(2) },
        {
          title: "Stock",
          field: "OnHand",
          headerSort: false,
          width: 90,
          hozAlign: "right",
          formatter: (cell) => {
            const v = parseFloat(cell.getValue() || 0)
            const cls = v > 0 ? 'text-green-700 font-semibold' : 'text-red-600'
            return `<span class="${cls}">${v.toFixed(2)}</span>`
          }
        }
      ]
    })
  }

  // ============================================
  // MODE: Cambiar Almacén
  // No llama API — usa lista de almacenes del documento (this.warehouses)
  // Angular: OpenDialogStock → afterClosed (sales-document.component.ts ~3960)
  // ============================================

  renderWarehouseList() {
    this.hideLoading()

    if (!this.warehouses || this.warehouses.length === 0) {
      this.renderEmptyState()
      return
    }

    this.hideEmptyState()
    this.tableContainerTarget.classList.remove("hidden")

    if (this.tableInstance) this.tableInstance.destroy()

    this.tableInstance = new Tabulator(this.stockTableTarget, {
      data: this.warehouses,
      layout: "fitColumns",
      height: "420px",
      placeholder: "No hay almacenes disponibles",
      rowFormatter: (row) => {
        if (row.getData().WhsCode === this.currentWarehouse) {
          row.getElement().classList.add("bg-blue-50")
        }
      },
      columns: [
        { title: "Código",    field: "WhsCode", headerSort: false, width: 100 },
        { title: "Almacén",   field: "WhsName", headerSort: false, minWidth: 200 },
        {
          title: "",
          field: "_select",
          headerSort: false,
          width: 120,
          hozAlign: "center",
          formatter: (cell) => {
            const isCurrent = cell.getRow().getData().WhsCode === this.currentWarehouse
            if (isCurrent) {
              return `<span class="text-xs text-blue-600 font-medium">Actual</span>`
            }
            return `<button class="px-3 py-1 text-xs font-medium text-white bg-blue-600 hover:bg-blue-700 rounded transition-colors">Seleccionar</button>`
          },
          cellClick: (e, cell) => {
            const warehouse = cell.getRow().getData()
            if (warehouse.WhsCode === this.currentWarehouse) return
            this.onWarehouseSelected(warehouse)
          }
        }
      ]
    })
  }

  onWarehouseSelected(warehouse) {
    if (this.onConfirmCallback) {
      this.onConfirmCallback(warehouse)
    }
    this.close()
  }

  cancel(event) {
    event?.preventDefault()
    this.close()
  }

  onSlideClosed() {
    super.onSlideClosed()
    this.currentItemCode = null
    this.currentWarehouse = null
    this.allowChange = false
    this.warehouses = []
    if (this.tableInstance) {
      this.tableInstance.destroy()
      this.tableInstance = null
    }
  }

  // ============================================
  // UI Helpers
  // ============================================

  showLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.classList.remove("hidden")
    this.tableContainerTarget.classList.add("hidden")
    this.emptyStateTarget.classList.add("hidden")
  }

  hideLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.classList.add("hidden")
  }

  renderEmptyState() {
    this.tableContainerTarget.classList.add("hidden")
    this.emptyStateTarget.classList.remove("hidden")
  }

  hideEmptyState() {
    this.emptyStateTarget.classList.add("hidden")
  }

  showToast(message, type = "info") {
    Swal.fire({
      toast: true,
      position: "top-end",
      icon: type,
      title: message,
      showConfirmButton: false,
      timer: 3000,
      timerProgressBar: true
    })
  }
}

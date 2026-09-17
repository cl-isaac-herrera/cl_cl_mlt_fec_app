import BaseSlideController from "vendor/clavisco/base/controllers/base_slide_controller"
import { getAPIHeaders } from "lib/api_helpers"
import { TabulatorFull as Tabulator } from 'tabulator-tables'
import Swal from 'sweetalert2'

/**
 * Batch Selection Slide Panel Controller
 * Manages batch/lot number selection for items with batch management (ManBtchNum === 'Y')
 * Replicates Angular LotComponent functionality
 *
 * @extends BaseSlideController
 */
export default class extends BaseSlideController {
  static targets = [
    ...BaseSlideController.targets,
    "itemName", "quantityNeeded", "quantityApplied",
    "batchesTableContainer", "batchesTable",
    "locationsTableContainer", "locationsTable", "currentBatchNumber",
    "emptyState", "loading",
    "validationError", "validationMessage",
    "acceptButton", "cancelButton"
  ]

  static values = {
    ...BaseSlideController.values,
    apiUrl: { type: String, default: "/api/Batches" }
  }

  connect() {
    super.connect()

    // State
    this.availableBatches = []
    this.selectedBatches = []
    this.currentBatch = null
    this.currentItem = null
    this.quantityRequired = 0
    this.batchesTabulator = null
    this.locationsTabulator = null
    this.view = 'batches' // 'batches' or 'locations'

    // Listen for open events
    this.boundOpen = this.handleOpenEvent.bind(this)
    window.addEventListener("batch-slide:open", this.boundOpen)
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("batch-slide:open", this.boundOpen)

    // Cleanup Tabulator instances
    if (this.batchesTabulator) {
      this.batchesTabulator.destroy()
      this.batchesTabulator = null
    }
    if (this.locationsTabulator) {
      this.locationsTabulator.destroy()
      this.locationsTabulator = null
    }
  }

  /**
   * Handle open event from sales_lines_table_controller
   */
  async handleOpenEvent(event) {
    if (event?.detail) {
      const { item, warehouse, quantity, existingBatches, existingLocations, onConfirm } = event.detail

      this.currentItem = item
      this.quantityRequired = quantity || 1
      this.onConfirmCallback = onConfirm
      this.existingBatches = existingBatches || []
      this.existingLocations = existingLocations || []

      // Update UI
      this.itemNameTarget.textContent = item.ItemName || item.ItemCode
      this.quantityNeededTarget.textContent = this.quantityRequired
      this.quantityAppliedTarget.textContent = '0'

      // Open slide (inherited from BaseSlideController)
      this.open()

      // Load batches from API
      await this.loadBatches(item.ItemCode, warehouse)
    }
  }

  /**
   * Load available batches for item from warehouse
   */
  async loadBatches(itemCode, warehouseCode) {
    this.showLoading()

    try {
      // Backend: api/Batches?itemCode={ItemCode}&WhsCode={WhsCode}
      // Angular: BatchesService.Get() (lot.component.ts línea 154)
      const url = `${this.apiUrlValue}?itemCode=${encodeURIComponent(itemCode)}&WhsCode=${encodeURIComponent(warehouseCode)}`
      const response = await fetch(url, {
        headers: getAPIHeaders({
          successDescription: "Lotes obtenidos",
          errorDescription: "No se pudo obtener lotes disponibles"
        })
      })

      if (response.ok) {
        const data = await response.json()
        this.availableBatches = data.Data || []

        // Pre-populate with existing batches if editing
        if (this.existingBatches && this.existingBatches.length > 0) {
          this.selectedBatches = this.existingBatches.map(batch => ({
            ...batch,
            _selected: true
          }))
        }

        this.renderBatchesTable()
      } else {
        this.showError("Error al cargar lotes disponibles")
        this.availableBatches = []
        this.renderEmptyState()
      }
    } catch (error) {
      console.error("Error loading batches:", error)
      this.showError("Error de conexión al cargar lotes")
      this.availableBatches = []
      this.renderEmptyState()
    } finally {
      this.hideLoading()
    }
  }

  /**
   * Render batches table with Tabulator
   */
  renderBatchesTable() {
    if (!this.availableBatches || this.availableBatches.length === 0) {
      this.renderEmptyState()
      return
    }

    this.hideEmptyState()
    this.hideValidationError()
    this.batchesTableContainerTarget.classList.remove("hidden")
    this.locationsTableContainerTarget.classList.add("hidden")
    this.view = 'batches'

    // Destroy existing table
    if (this.batchesTabulator) {
      this.batchesTabulator.destroy()
    }

    // Create Tabulator table for batches
    this.batchesTabulator = new Tabulator(this.batchesTableTarget, {
      data: this.availableBatches,
      layout: "fitColumns",
      responsiveLayout: "collapse",
      height: "400px",
      placeholder: "No hay lotes disponibles",
      columns: [
        {
          title: "Lote",
          field: "DistNumber",
          headerSort: false,
          minWidth: 150
        },
        {
          title: "Stock Disponible",
          field: "Disponible",
          headerSort: false,
          width: 140,
          hozAlign: "right",
          formatter: (cell) => {
            const value = cell.getValue()
            return value ? parseFloat(value).toFixed(2) : '0.00'
          }
        },
        {
          title: "Cantidad Asignada",
          field: "SelectedQuantity",
          headerSort: false,
          width: 150,
          hozAlign: "right",
          editor: "number",
          editorParams: {
            min: 0,
            step: 0.01,
            selectContents: true
          },
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const value = row.SelectedQuantity || 0
            return parseFloat(value).toFixed(2)
          },
          cellEdited: (cell) => {
            this.onBatchQuantityChanged(cell)
          }
        },
        {
          title: "Ubicaciones",
          field: "locations",
          headerSort: false,
          width: 130,
          hozAlign: "center",
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const hasLocations = row.Locations && row.Locations.length > 0
            if (hasLocations) {
              return `<button class="px-2 py-1 text-xs text-blue-600 hover:text-blue-800 hover:bg-blue-50 rounded transition-colors flex items-center gap-1">
                <span class="material-symbols-outlined text-sm">location_on</span>
                <span>Ver ubicaciones</span>
              </button>`
            }
            return '<span class="text-gray-400 text-xs">Sin ubicaciones</span>'
          },
          cellClick: (e, cell) => {
            const row = cell.getRow().getData()
            if (row.Locations && row.Locations.length > 0) {
              this.showLocationsForBatch(row)
            }
          }
        }
      ]
    })

    // Pre-fill selected quantities if editing
    if (this.selectedBatches && this.selectedBatches.length > 0) {
      this.selectedBatches.forEach(selected => {
        const batchRow = this.batchesTabulator.getRows().find(row =>
          row.getData().DistNumber === selected.BatchNumber
        )
        if (batchRow) {
          batchRow.update({ SelectedQuantity: selected.Quantity || 0 })
        }
      })
    }

    this.updateQuantityApplied()
  }

  /**
   * Handle batch quantity change
   */
  onBatchQuantityChanged(cell) {
    const row = cell.getRow().getData()
    const quantity = parseFloat(row.SelectedQuantity) || 0
    const available = parseFloat(row.Disponible) || 0

    // Validate quantity doesn't exceed available
    if (quantity > available) {
      this.showToast(`Cantidad excede el stock disponible (${available})`, "warning")
      cell.getRow().update({ SelectedQuantity: available })
      return
    }

    this.updateQuantityApplied()
    this.hideValidationError()
  }

  /**
   * Show locations table for a batch
   */
  showLocationsForBatch(batch) {
    this.currentBatch = batch
    this.currentBatchNumberTarget.textContent = batch.BatchNumber

    // Switch view
    this.batchesTableContainerTarget.classList.add("hidden")
    this.locationsTableContainerTarget.classList.remove("hidden")
    this.view = 'locations'

    // Render locations table
    this.renderLocationsTable(batch.Locations || [])
  }

  /**
   * Render locations table with Tabulator
   */
  renderLocationsTable(locations) {
    // Destroy existing table
    if (this.locationsTabulator) {
      this.locationsTabulator.destroy()
    }

    // Create Tabulator table for locations
    this.locationsTabulator = new Tabulator(this.locationsTableTarget, {
      data: locations,
      layout: "fitColumns",
      responsiveLayout: "collapse",
      height: "350px",
      placeholder: "No hay ubicaciones disponibles",
      columns: [
        {
          title: "Ubicación",
          field: "BinCode",
          headerSort: false,
          minWidth: 150
        },
        {
          title: "Stock Disponible",
          field: "Stock",
          headerSort: false,
          width: 140,
          hozAlign: "right",
          formatter: (cell) => {
            const value = cell.getValue()
            return value ? parseFloat(value).toFixed(2) : '0.00'
          }
        },
        {
          title: "Cantidad Asignada",
          field: "SelectedQuantity",
          headerSort: false,
          width: 150,
          hozAlign: "right",
          editor: "number",
          editorParams: {
            min: 0,
            step: 0.01,
            selectContents: true
          },
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const value = row.SelectedQuantity || 0
            return parseFloat(value).toFixed(2)
          },
          cellEdited: (cell) => {
            this.onLocationQuantityChanged(cell)
          }
        }
      ]
    })
  }

  /**
   * Handle location quantity change
   */
  onLocationQuantityChanged(cell) {
    const row = cell.getRow().getData()
    const quantity = parseFloat(row.SelectedQuantity) || 0
    const available = parseFloat(row.Quantity) || 0

    // Validate quantity doesn't exceed available
    if (quantity > available) {
      this.showToast(`Cantidad excede el stock disponible (${available})`, "warning")
      cell.getRow().update({ SelectedQuantity: available })
    }
  }

  /**
   * Go back to batches table
   */
  backToBatches() {
    this.locationsTableContainerTarget.classList.add("hidden")
    this.batchesTableContainerTarget.classList.remove("hidden")
    this.currentBatch = null
    this.view = 'batches'
  }

  /**
   * Update quantity applied display
   */
  updateQuantityApplied() {
    if (!this.batchesTabulator) return

    const total = this.batchesTabulator.getData().reduce((sum, row) => {
      return sum + (parseFloat(row.SelectedQuantity) || 0)
    }, 0)

    this.quantityAppliedTarget.textContent = total.toFixed(2)

    // Enable/disable accept button
    const isValid = total === this.quantityRequired
    this.acceptButtonTarget.disabled = !isValid
  }

  /**
   * Accept selection
   */
  accept(event) {
    event?.preventDefault()

    if (!this.batchesTabulator) return

    // Collect selected batches
    const selectedBatches = this.batchesTabulator.getData()
      .filter(row => (parseFloat(row.SelectedQuantity) || 0) > 0)
      .map(row => ({
        BatchNumber: row.DistNumber,
        Quantity: parseFloat(row.SelectedQuantity) || 0,
        SystemSerialNumber: row.SysNumber || 0
      }))

    // Validate total quantity
    const totalQuantity = selectedBatches.reduce((sum, batch) => sum + batch.Quantity, 0)
    if (totalQuantity !== this.quantityRequired) {
      this.showValidationError(`La cantidad total (${totalQuantity.toFixed(2)}) debe ser exactamente ${this.quantityRequired}`)
      return
    }

    // Collect locations if any
    const locations = []
    this.batchesTabulator.getData().forEach(batch => {
      if ((parseFloat(batch.SelectedQuantity) || 0) > 0 && batch.Locations) {
        batch.Locations.forEach(loc => {
          if ((parseFloat(loc.SelectedQuantity) || 0) > 0) {
            locations.push({
              BinCode: loc.BinCode,
              Quantity: parseFloat(loc.SelectedQuantity) || 0,
              BatchNumber: batch.BatchNumber,
              BinAbsEntry: loc.BinAbsEntry || 0
            })
          }
        })
      }
    })

    // Call callback with result
    if (this.onConfirmCallback) {
      this.onConfirmCallback({
        Lotes: selectedBatches,
        Locations: locations.length > 0 ? locations : null
      })
    }

    this.close()
  }

  /**
   * Cancel and close
   */
  cancel(event) {
    event?.preventDefault()
    this.close()
  }

  /**
   * Hook: Reset state after slide closes
   * @override
   */
  onSlideClosed() {
    super.onSlideClosed()

    // Reset state
    this.availableBatches = []
    this.selectedBatches = []
    this.currentBatch = null
    this.currentItem = null
    this.view = 'batches'

    // Destroy Tabulator instances
    if (this.batchesTabulator) {
      this.batchesTabulator.destroy()
      this.batchesTabulator = null
    }
    if (this.locationsTabulator) {
      this.locationsTabulator.destroy()
      this.locationsTabulator = null
    }
  }

  // ============================================
  // UI Helper Methods
  // ============================================

  showLoading() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove("hidden")
    }
    this.batchesTableContainerTarget.classList.add("hidden")
    this.locationsTableContainerTarget.classList.add("hidden")
    this.emptyStateTarget.classList.add("hidden")
  }

  hideLoading() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.add("hidden")
    }
  }

  renderEmptyState() {
    this.batchesTableContainerTarget.classList.add("hidden")
    this.locationsTableContainerTarget.classList.add("hidden")
    this.emptyStateTarget.classList.remove("hidden")
    this.acceptButtonTarget.disabled = true
  }

  hideEmptyState() {
    this.emptyStateTarget.classList.add("hidden")
  }

  showValidationError(message) {
    if (this.hasValidationErrorTarget) {
      this.validationMessageTarget.textContent = message
      this.validationErrorTarget.classList.remove("hidden")
    }
  }

  hideValidationError() {
    if (this.hasValidationErrorTarget) {
      this.validationErrorTarget.classList.add("hidden")
    }
  }

  showError(message) {
    this.showToast(message, "error")
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

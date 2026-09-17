import BaseSlideController from "vendor/clavisco/base/controllers/base_slide_controller"
import { getAPIHeaders } from "lib/api_helpers"
import { TabulatorFull as Tabulator } from 'tabulator-tables'
import Swal from 'sweetalert2'

/**
 * Bin Location Selection Slide Panel Controller
 * Manages bin location selection for items with bin location management (ManBinLocation === 'Y')
 * Replicates Angular LocationComponent functionality
 *
 * @extends BaseSlideController
 */
export default class extends BaseSlideController {
  static targets = [
    ...BaseSlideController.targets,
    "itemName", "quantityRequested", "quantityApplied",
    "locationsTableContainer", "locationsTable",
    "emptyState", "loading",
    "validationError", "validationMessage",
    "acceptButton", "cancelButton"
  ]

  static values = {
    ...BaseSlideController.values,
    apiUrl: { type: String, default: "/api/BinLocations" }
  }

  connect() {
    super.connect()

    // State
    this.availableLocations = []
    this.selectedLocation = null
    this.currentItem = null
    this.quantityRequired = 0
    this.locationsTabulator = null
    this.documentType = null
    this.validateStock = false
    this.hasEditPermission = true

    // Listen for open events
    this.boundOpen = this.handleOpenEvent.bind(this)
    window.addEventListener("bin-location-slide:open", this.boundOpen)
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("bin-location-slide:open", this.boundOpen)

    // Cleanup Tabulator instance
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
      const {
        item,
        warehouse,
        quantity,
        existingLocation,
        documentType,
        validateStock,
        hasEditPermission,
        onConfirm
      } = event.detail

      this.currentItem = item
      this.quantityRequired = quantity || 1
      this.documentType = documentType
      this.validateStock = validateStock !== false // Default to true
      this.hasEditPermission = hasEditPermission !== false // Default to true
      this.onConfirmCallback = onConfirm
      this.existingLocation = existingLocation

      // Update UI
      this.itemNameTarget.textContent = item.ItemName || item.ItemCode
      this.quantityRequestedTarget.textContent = this.quantityRequired
      this.quantityAppliedTarget.textContent = '0'

      // Open slide (inherited from BaseSlideController)
      this.open()

      // Load locations from API
      await this.loadLocations(item.ItemCode, warehouse)
    }
  }

  /**
   * Load available bin locations for item from warehouse
   */
  async loadLocations(itemCode, warehouseCode) {
    this.showLoading()

    try {
      // Backend: api/BinLocations?itemCode={ItemCode}&WhsCode={WhsCode}
      const url = `${this.apiUrlValue}?itemCode=${encodeURIComponent(itemCode)}&WhsCode=${encodeURIComponent(warehouseCode)}`
      const response = await fetch(url, {
        headers: getAPIHeaders({
          successDescription: "Ubicaciones obtenidas",
          errorDescription: "No se pudo obtener ubicaciones disponibles"
        })
      })

      if (response.ok) {
        const data = await response.json()
        this.availableLocations = data.Data || []

        this.renderLocationsTable()
      } else {
        this.showError("Error al cargar ubicaciones disponibles")
        this.availableLocations = []
        this.renderEmptyState()
      }
    } catch (error) {
      console.error("Error loading bin locations:", error)
      this.showError("Error de conexión al cargar ubicaciones")
      this.availableLocations = []
      this.renderEmptyState()
    } finally {
      this.hideLoading()
    }
  }

  /**
   * Render locations table with Tabulator
   */
  renderLocationsTable() {
    if (!this.availableLocations || this.availableLocations.length === 0) {
      this.renderEmptyState()
      return
    }

    this.hideEmptyState()
    this.hideValidationError()
    this.locationsTableContainerTarget.classList.remove("hidden")

    // Destroy existing table
    if (this.locationsTabulator) {
      this.locationsTabulator.destroy()
    }

    // Create Tabulator table with single selection (radio button behavior)
    this.locationsTabulator = new Tabulator(this.locationsTableTarget, {
      data: this.availableLocations,
      layout: "fitColumns",
      responsiveLayout: "collapse",
      height: "400px",
      placeholder: "No hay ubicaciones disponibles",
      columns: [
        {
          title: "Seleccionar",
          field: "Selected",
          headerSort: false,
          width: 100,
          hozAlign: "center",
          formatter: (cell) => {
            const row = cell.getRow().getData()
            const checked = row.Selected ? 'checked' : ''
            return `<input type="radio" name="location-select" ${checked} class="cursor-pointer" />`
          },
          cellClick: (e, cell) => {
            // Radio button behavior: only one can be selected
            this.onLocationSelected(cell)
          }
        },
        {
          title: "Ubicación",
          field: "BinCode",
          headerSort: false,
          minWidth: 150
        },
        {
          title: "Disponible",
          field: "Stock",
          headerSort: false,
          width: 140,
          hozAlign: "right",
          formatter: (cell) => {
            const value = cell.getValue()
            return value ? parseFloat(value).toFixed(2) : '0.00'
          }
        }
      ]
    })

    // Pre-select existing location if editing
    if (this.existingLocation) {
      const locationRow = this.locationsTabulator.getRows().find(row =>
        row.getData().BinCode === this.existingLocation.BinCode
      )
      if (locationRow) {
        locationRow.update({ Selected: true })
        this.selectedLocation = locationRow.getData()
        this.updateQuantityApplied()
      }
    }
  }

  /**
   * Handle location selection (radio button behavior)
   */
  onLocationSelected(cell) {
    const selectedRow = cell.getRow()

    // Update internal data (needed for pre-population on re-open)
    this.locationsTabulator.getData().forEach(row => {
      row.Selected = false
    })
    selectedRow.getData().Selected = true
    this.selectedLocation = selectedRow.getData()

    // Manipulate DOM directly — Tabulator does not reliably re-render radio inputs via row.update()
    const allRadios = this.locationsTableTarget.querySelectorAll('input[name="location-select"]')
    allRadios.forEach(radio => { radio.checked = false })

    const clickedRadio = cell.getElement().querySelector('input[type="radio"]')
    if (clickedRadio) clickedRadio.checked = true

    // Update quantity applied
    this.updateQuantityApplied()
    this.hideValidationError()
  }

  /**
   * Update quantity applied display
   */
  updateQuantityApplied() {
    if (this.selectedLocation) {
      this.quantityAppliedTarget.textContent = this.quantityRequired
      this.acceptButtonTarget.disabled = false
    } else {
      this.quantityAppliedTarget.textContent = '0'
      this.acceptButtonTarget.disabled = true
    }
  }

  /**
   * Accept selection and validate
   */
  accept(event) {
    event?.preventDefault()

    if (!this.selectedLocation) {
      this.showValidationError("Seleccione una ubicación")
      return
    }

    // Validate edit permission
    if (!this.hasEditPermission) {
      this.showToast("No tiene permiso para cambiar la ubicación", "info")
      return
    }

    // Validate stock (except for invoices)
    if (this.documentType !== 'Invoices' && this.validateStock) {
      const availableStock = parseFloat(this.selectedLocation.Stock) || 0
      if (availableStock < this.quantityRequired) {
        this.showValidationError(
          `Stock insuficiente. Solicitado: ${this.quantityRequired}, disponible: ${availableStock.toFixed(2)}`
        )
        return
      }
    }

    // Build result matching Angular structure
    const result = {
      Location: [{
        SerialAndBatchNumbersBaseLine: 0,
        BinAbsEntry: this.selectedLocation.AbsEntry || 0,
        Quantity: this.quantityRequired,
        Stock: this.selectedLocation.Stock
      }],
      BinCode: this.selectedLocation.BinCode
    }

    // Call callback with result
    if (this.onConfirmCallback) {
      this.onConfirmCallback(result)
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
    this.availableLocations = []
    this.selectedLocation = null
    this.currentItem = null
    this.documentType = null
    this.validateStock = false
    this.hasEditPermission = true

    // Destroy Tabulator instance
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
    this.locationsTableContainerTarget.classList.add("hidden")
    this.emptyStateTarget.classList.add("hidden")
  }

  hideLoading() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.add("hidden")
    }
  }

  renderEmptyState() {
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

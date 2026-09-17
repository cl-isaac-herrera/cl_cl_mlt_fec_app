import BaseSlideController from "vendor/clavisco/base/controllers/base_slide_controller"
import { getAPIHeaders } from "lib/api_helpers"
import Swal from 'sweetalert2'

/**
 * Series Selection Slide Panel Controller
 * Manages serial number selection for serialized items (ManSerNum === 'Y')
 * Replicates Angular SeriesItemsComponent functionality
 *
 * @extends BaseSlideController
 */
export default class extends BaseSlideController {
  static targets = [
    ...BaseSlideController.targets,
    "itemName", "quantityNeeded",
    "tbody", "emptyState",
    "acceptButton", "cancelButton",
    "loading"
  ]

  static values = {
    ...BaseSlideController.values,
    apiUrl: { type: String, default: "/api/Items" }
  }

  connect() {
    super.connect()

    this.availableSeries = []
    this.selectedSeries = []
    this.currentItem = null
    this.quantityRequired = 0

    // Listen for open events
    this.boundOpen = this.handleOpenEvent.bind(this)
    window.addEventListener("series-slide:open", this.boundOpen)
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("series-slide:open", this.boundOpen)
  }

  /**
   * Handle open event from sales_lines_table_controller
   */
  async handleOpenEvent(event) {
    if (event?.detail) {
      const { item, warehouse, quantity, existingSeries, onConfirm } = event.detail

      this.currentItem = item
      this.quantityRequired = quantity || 1
      this.onConfirmCallback = onConfirm
      this.existingSeries = existingSeries || []

      // Update UI
      this.itemNameTarget.textContent = item.ItemName || item.ItemCode
      this.quantityNeededTarget.textContent = this.quantityRequired

      // Open slide (inherited from BaseSlideController)
      this.open()

      // Load series from API
      await this.loadSeries(item.ItemCode, warehouse)
    }
  }

  /**
   * Load available series for item from warehouse
   */
  async loadSeries(itemCode, warehouseCode) {
    this.showLoading()

    try {
      // Backend: api/Items/{ItemCode}/Warehouse/{WhsCode}/Series (ItemsController.cs línea 373)
      // Angular: GetItemSeriesByWarehouse (sales-document.component.ts línea 5253)
      const response = await fetch(
        `${this.apiUrlValue}/${encodeURIComponent(itemCode)}/Warehouse/${encodeURIComponent(warehouseCode)}/Series`,
        {
          headers: getAPIHeaders({
            successDescription: "Series obtenidas",
            errorDescription: "No se pudo obtener series disponibles"
          })
        }
      )

      if (response.ok) {
        const data = await response.json()
        this.availableSeries = data.Data || []

        // Pre-select existing series if editing
        if (this.existingSeries && this.existingSeries.length > 0) {
          this.availableSeries.forEach(series => {
            const existing = this.existingSeries.find(
              s => s.SystemSerialNumber === series.SystemSerialNumber
            )
            if (existing) {
              series._selected = true
              this.selectedSeries.push(series)
            }
          })
        }

        this.renderTable()
      } else {
        this.showError("Error al cargar series disponibles")
        this.availableSeries = []
        this.renderTable()
      }
    } catch (error) {
      console.error("Error loading series:", error)
      this.showError("Error de conexión al cargar series")
      this.availableSeries = []
      this.renderTable()
    } finally {
      this.hideLoading()
    }
  }

  /**
   * Render series table
   */
  renderTable() {
    if (!this.availableSeries || this.availableSeries.length === 0) {
      this.tbodyTarget.classList.add("hidden")
      this.emptyStateTarget.classList.remove("hidden")
      this.updateAcceptButton()
      return
    }

    this.tbodyTarget.classList.remove("hidden")
    this.emptyStateTarget.classList.add("hidden")

    // Angular: columns SystemSerialNumber, DistNumber, Quantity
    this.tbodyTarget.innerHTML = this.availableSeries.map((series, index) => {
      const isSelected = series._selected || false

      return `
        <tr class="hover:bg-gray-50">
          <td class="px-4 py-3 text-center">
            <input type="checkbox"
                   class="w-4 h-4 text-blue-600 rounded border-gray-300 focus:ring-blue-500"
                   data-index="${index}"
                   ${isSelected ? 'checked' : ''}
                   data-action="change->series-slide#toggleSeries">
          </td>
          <td class="px-4 py-3 text-sm text-gray-900">
            ${this.escapeHtml(series.SystemSerialNumber || series.SerialNumber || '-')}
          </td>
          <td class="px-4 py-3 text-sm text-gray-700">
            ${this.escapeHtml(series.DistNumber || '-')}
          </td>
          <td class="px-4 py-3 text-sm text-right text-gray-700">
            ${series.Quantity || 1}
          </td>
        </tr>
      `
    }).join('')

    this.updateAcceptButton()
  }

  /**
   * Toggle series selection
   */
  toggleSeries(event) {
    const checkbox = event.target
    const index = parseInt(checkbox.dataset.index)
    const series = this.availableSeries[index]

    if (checkbox.checked) {
      // Add to selected
      series._selected = true
      if (!this.selectedSeries.find(s => s.SystemSerialNumber === series.SystemSerialNumber)) {
        this.selectedSeries.push(series)
      }
    } else {
      // Remove from selected
      series._selected = false
      this.selectedSeries = this.selectedSeries.filter(
        s => s.SystemSerialNumber !== series.SystemSerialNumber
      )
    }

    this.updateAcceptButton()
  }

  /**
   * Update accept button state
   */
  updateAcceptButton() {
    const selectedCount = this.selectedSeries.length
    const isValid = selectedCount === this.quantityRequired

    if (this.hasAcceptButtonTarget) {
      this.acceptButtonTarget.disabled = !isValid

      if (selectedCount === 0) {
        this.acceptButtonTarget.textContent = "Seleccionar series"
      } else if (selectedCount < this.quantityRequired) {
        this.acceptButtonTarget.textContent = `Seleccionadas ${selectedCount}/${this.quantityRequired}`
      } else if (selectedCount === this.quantityRequired) {
        this.acceptButtonTarget.textContent = "Aceptar"
      } else {
        this.acceptButtonTarget.textContent = `Excede cantidad (${selectedCount}/${this.quantityRequired})`
      }
    }
  }

  /**
   * Accept selection
   */
  accept(event) {
    event?.preventDefault()

    if (this.selectedSeries.length !== this.quantityRequired) {
      this.showToast(
        `Debe seleccionar exactamente ${this.quantityRequired} serie(s)`,
        "warning"
      )
      return
    }

    // Angular: returns IBatchNumbers format (similar structure)
    const result = this.selectedSeries.map(series => ({
      SystemSerialNumber: series.SystemSerialNumber || series.SerialNumber,
      DistNumber: series.DistNumber,
      Quantity: series.Quantity || 1
    }))

    // Call callback with selected series
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
    this.selectedSeries = []
    this.availableSeries = []
    this.currentItem = null
  }

  // ============================================
  // Utility Methods
  // ============================================

  showLoading() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove("hidden")
    }
    if (this.hasTbodyTarget) {
      this.tbodyTarget.classList.add("hidden")
    }
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.add("hidden")
    }
  }

  hideLoading() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.add("hidden")
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

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

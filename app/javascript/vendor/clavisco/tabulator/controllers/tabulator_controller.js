import { Controller } from "@hotwired/stimulus"
import { TabulatorFull as Tabulator } from "tabulator-tables"
import Swal from "sweetalert2"

/**
 * Base Tabulator Controller
 *
 * Generic, reusable Tabulator implementation for Clavisco projects.
 *
 * @example
 * import TabulatorController from "vendor/clavisco/tabulator/controllers/tabulator_controller"
 *
 * export default class extends TabulatorController {
 *   connect() {
 *     super.connect()
 *   }
 *
 *   getColumns() {
 *     return [
 *       { title: "Name", field: "name", editor: "input" },
 *       { title: "Age", field: "age", editor: "number" }
 *     ]
 *   }
 * }
 *
 * @see https://tabulator.info/docs/
 */
export default class extends Controller {
  static targets = ["table", "search"]

  static values = {
    // Data
    data: { type: Array, default: [] },

    // Configuration
    height: { type: String, default: "auto" },
    maxHeight: { type: String, default: "500px" },
    layout: { type: String, default: "fitColumns" },

    // Pagination
    pagination: { type: Boolean, default: true },
    paginationSize: { type: Number, default: 10 },

    // Features
    movableRows: { type: Boolean, default: true },
    resizableColumns: { type: Boolean, default: true },
    clipboard: { type: Boolean, default: true },

    // Responsive
    responsiveLayout: { type: String, default: "collapse" }
  }

  connect() {
    console.log("[tabulator] Base controller connected")

    // Initialize table if target exists
    if (this.hasTableTarget) {
      this.initializeTable()
    }
  }

  disconnect() {
    if (this.table) {
      this.table.destroy()
      console.log("[tabulator] Table destroyed")
    }
  }

  /**
   * Initialize Tabulator instance
   * Override this method to customize initialization
   */
  initializeTable() {
    const config = this.getTableConfig()

    this.table = new Tabulator(this.tableTarget, config)

    this.setupEventListeners()
    this.setupTooltip()

    console.log("[tabulator] Table initialized with config:", config)
  }

  /**
   * Get Tabulator configuration
   * Override to customize table config
   *
   * @returns {Object} Tabulator configuration
   */
  getTableConfig() {
    return {
      data: this.dataValue,
      layout: this.layoutValue,
      layoutColumnsOnNewData: true,
      responsiveLayout: this.responsiveLayoutValue,
      placeholder: this.getPlaceholder(),

      // Height
      height: this.heightValue,
      maxHeight: this.maxHeightValue,

      // Pagination
      pagination: this.paginationValue,
      paginationSize: this.paginationSizeValue,
      paginationSizeSelector: [5, 10, 20, 50, 100],

      // Features
      movableRows: this.movableRowsValue,
      resizableColumnFit: this.resizableColumnsValue,

      // Clipboard
      clipboard: this.clipboardValue,
      clipboardCopySelector: "table",
      clipboardCopyHeader: true,

      // Columns
      columns: this.getColumns()
    }
  }

  /**
   * Define table columns
   * MUST be overridden by child controller
   *
   * @returns {Array} Array of column definitions
   */
  getColumns() {
    throw new Error("getColumns() must be implemented by child controller")
  }

  /**
   * Setup fixed-position tooltip for action buttons.
   * Uses event delegation on the table container to avoid being clipped
   * by Tabulator's overflow:hidden on cells.
   * Buttons must carry a data-tooltip="..." attribute to activate.
   *
   * Posicionamiento: el tooltip SIEMPRE queda completamente visible dentro del
   * viewport (flip + clamp + límite de ancho). Ver CLAUDE.md §25.
   */
  setupTooltip() {
    if (!document.getElementById('cl-tabulator-tooltip')) {
      const tip = document.createElement('div')
      tip.id = 'cl-tabulator-tooltip'
      // max-width + wrapping: el tooltip NUNCA excede el ancho del viewport, así
      // que su contenido siempre queda completo (los textos largos envuelven).
      tip.style.cssText = [
        'position:fixed',
        'z-index:9999',
        'pointer-events:none',
        'background:#1f2937',
        'color:#fff',
        'padding:4px 8px',
        'border-radius:4px',
        'font-size:12px',
        'line-height:1.35',
        'max-width:min(320px, calc(100vw - 16px))',
        'white-space:normal',
        'word-break:break-word',
        'text-align:left',
        'opacity:0',
        'transition:opacity 0.15s',
      ].join(';')
      document.body.appendChild(tip)
    }
    const tip = document.getElementById('cl-tabulator-tooltip')
    let activeBtn = null

    // Reposiciona el tooltip dentro del viewport: por defecto arriba del cursor;
    // hace flip horizontal/vertical y clamp contra los bordes para que nunca
    // quede cortado. (Ver CLAUDE.md §25 — estándar de tooltips flotantes.)
    const place = (e) => {
      const margin = 8
      const { width: w, height: h } = tip.getBoundingClientRect()
      let left = e.clientX + 12
      let top  = e.clientY - h - 10                                       // arriba del cursor
      if (left + w + margin > window.innerWidth) left = e.clientX - w - 12   // flip a la izquierda
      if (left < margin) left = margin
      if (left + w + margin > window.innerWidth) left = window.innerWidth - w - margin
      if (top < margin) top = e.clientY + 18                             // sin espacio arriba → abajo
      if (top + h + margin > window.innerHeight) top = window.innerHeight - h - margin
      tip.style.left = left + 'px'
      tip.style.top  = top + 'px'
    }

    this.tableTarget.addEventListener('mouseover', (e) => {
      const btn = e.target.closest('[data-tooltip]')
      if (btn && btn !== activeBtn) {
        activeBtn = btn
        tip.textContent = btn.dataset.tooltip
        place(e)
        tip.style.opacity = '1'
      } else if (!btn) {
        activeBtn = null
        tip.style.opacity = '0'
      }
    })

    this.tableTarget.addEventListener('mousemove', (e) => {
      if (!activeBtn) return
      place(e)
    })

    this.tableTarget.addEventListener('mouseleave', () => {
      activeBtn = null
      tip.style.opacity = '0'
    })
  }

  /**
   * Get placeholder text when table is empty
   * Override to customize
   *
   * @returns {string}
   */
  getPlaceholder() {
    return "No hay datos disponibles"
  }

  /**
   * Setup event listeners
   * Override to add custom events
   */
  setupEventListeners() {
    // Cell edited
    this.table.on("cellEdited", (cell) => {
      this.onCellEdited(cell)
    })

    // Row moved (drag & drop)
    this.table.on("rowMoved", (row) => {
      this.onRowMoved(row)
    })

    // Data changed
    this.table.on("dataChanged", (data) => {
      this.onDataChanged(data)
    })
  }

  /**
   * Handle cell edited event
   * Override to add custom logic
   *
   * @param {Object} cell Tabulator cell object
   */
  onCellEdited(cell) {
    const field = cell.getColumn().getField()
    const row = cell.getRow().getData()
    const value = cell.getValue()

    console.log("[tabulator] Cell edited:", { field, value, row })

    // Dispatch custom event
    this.dispatch("cell-changed", {
      detail: {
        field,
        value,
        row,
        rowIndex: cell.getRow().getPosition()
      }
    })
  }

  /**
   * Handle row moved event
   * Override to add custom logic
   *
   * @param {Object} row Tabulator row object
   */
  onRowMoved(row) {
    console.log("[tabulator] Row moved:", row.getData())

    // Dispatch custom event
    this.dispatch("row-moved", {
      detail: {
        row: row.getData(),
        newPosition: row.getPosition()
      }
    })
  }

  /**
   * Handle data changed event
   * Override to add custom logic
   *
   * @param {Array} data Current table data
   */
  onDataChanged(data) {
    console.log("[tabulator] Data changed, rows:", data.length)
  }

  // ========================================
  // PUBLIC API
  // ========================================

  /**
   * Set table data
   * @param {Array} data Array of row objects
   */
  setData(data) {
    if (!this.table) return

    this.table.setData(data)
    console.log("[tabulator] Data set:", data.length, "rows")
  }

  /**
   * Get table data
   * @returns {Array}
   */
  getData() {
    if (!this.table) return []

    return this.table.getData()
  }

  /**
   * Add row to table
   * @param {Object} row Row data object
   * @param {Boolean} top Add to top of table
   */
  addRow(row, top = false) {
    if (!this.table) return

    this.table.addRow(row, top)
  }

  /**
   * Update row
   * @param {Number|String} id Row ID
   * @param {Object} updates Update object
   */
  updateRow(id, updates) {
    if (!this.table) return

    const row = this.table.getRow(id)
    if (row) {
      row.update(updates)
    }
  }

  /**
   * Delete row
   * @param {Number|String} id Row ID
   */
  deleteRow(id) {
    if (!this.table) return

    const row = this.table.getRow(id)
    if (row) {
      row.delete()
    }
  }

  /**
   * Clear all filters
   */
  clearFilters() {
    if (!this.table) return

    this.table.clearFilter()
  }

  /**
   * Redraw table
   */
  redraw() {
    if (!this.table) return

    this.table.redraw()
  }

  // ========================================
  // TOOLBAR ACTIONS
  // ========================================

  /**
   * Search/filter table
   * @param {Event} event Input event
   */
  search(event) {
    const query = event.target.value

    if (!query) {
      this.table.clearFilter()
      return
    }

    // Override this method to customize search fields
    const searchFields = this.getSearchFields()

    const filters = searchFields.map(field => ({
      field,
      type: "like",
      value: query
    }))

    this.table.setFilter([filters])

    console.log("[tabulator] Search:", query)
  }

  /**
   * Get fields to search
   * Override to customize search fields
   *
   * @returns {Array} Array of field names
   */
  getSearchFields() {
    // Default: search all visible columns
    return this.table.getColumns()
      .map(col => col.getField())
      .filter(field => field && field !== "actions")
  }

  /**
   * Export table to Excel
   * Requires SheetJS (xlsx) library
   *
   * @param {Event} event Click event
   */
  exportExcel(event) {
    if (!this.table) {
      console.error("[tabulator] Table not initialized")
      return
    }

    // Check if XLSX library is loaded
    if (typeof window.XLSX === 'undefined') {
      console.error("[tabulator] XLSX library not loaded")
      alert("La librería de Excel no está cargada. Por favor recargue la página.")
      return
    }

    try {
      const timestamp = new Date().toISOString().slice(0, 10)
      const fileName = this.getExportFileName(timestamp)

      console.log("[tabulator] Starting Excel export...")

      this.table.download("xlsx", fileName, {
        sheetName: this.getExportSheetName()
      })

      console.log("[tabulator] Excel exported:", fileName)

      this.showToast("success", "Excel exportado correctamente")
    } catch (error) {
      console.error("[tabulator] Excel export error:", error)
      this.showToast("error", error.message || "Error al exportar Excel")
    }
  }

  /**
   * Get export file name
   * Override to customize
   *
   * @param {string} timestamp ISO date string
   * @returns {string}
   */
  getExportFileName(timestamp) {
    return `tabla_${timestamp}.xlsx`
  }

  /**
   * Get export sheet name
   * Override to customize
   *
   * @returns {string}
   */
  getExportSheetName() {
    return "Datos"
  }

  /**
   * Toggle columns visibility
   * @param {Event} event Click event
   */
  toggleColumns(event) {
    console.log("[tabulator] Toggle columns clicked")

    alert(
      "Personalización de columnas\n\n" +
      "Puede redimensionar las columnas arrastrando el borde de los encabezados.\n\n" +
      "La funcionalidad de mostrar/ocultar columnas estará disponible próximamente."
    )
  }

  /**
   * Show toast notification
   * Override to use custom toast system
   *
   * @param {string} type success, error, warning, info
   * @param {string} message Message text
   */
  showToast(type, message) {
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

  /**
   * Copy entire table to clipboard
   * Formats as TSV (tab-separated values) for Excel/SAP compatibility
   */
  copyToClipboard(event) {
    if (!this.table) {
      console.error("[tabulator] Table not initialized")
      return
    }

    try {
      const data = this.table.getData()

      if (data.length === 0) {
        this.showToast("warning", "No hay datos para copiar")
        return
      }

      // Get visible columns
      const columns = this.table.getColumns()
        .filter(col => col.getField() && col.getField() !== "actions")
        .map(col => ({
          field: col.getField(),
          title: col.getDefinition().title
        }))

      // Build header row
      const header = columns.map(col => col.title).join("\t")

      // Build data rows
      const rows = data.map(row => {
        return columns.map(col => {
          let value = row[col.field]

          // Format values
          if (value === null || value === undefined) {
            return ""
          }

          // Remove currency symbols and formatting for better paste
          if (typeof value === 'string') {
            value = value.replace(/₡/g, '').replace(/%/g, '')
          }

          // Convert to string and escape tabs/newlines
          return String(value).replace(/\t/g, ' ').replace(/\n/g, ' ')
        }).join("\t")
      }).join("\n")

      // Combine header and rows
      const tsv = header + "\n" + rows

      // Copy to clipboard using fallback method (more reliable)
      this.copyTextToClipboard(tsv)

      console.log("[tabulator] Copied to clipboard:", data.length, "rows")
      this.showToast("success", `${data.length} líneas copiadas al portapapeles`)

    } catch (error) {
      console.error("[tabulator] Copy error:", error)
      this.showToast("error", error.message || "Error al copiar al portapapeles")
    }
  }

  /**
   * Copy text to clipboard using fallback method
   * Works even when document is not focused
   * @param {string} text Text to copy
   */
  copyTextToClipboard(text) {
    // Create temporary textarea
    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.style.position = 'fixed'
    textarea.style.left = '-999999px'
    textarea.style.top = '-999999px'
    document.body.appendChild(textarea)

    // Select and copy
    textarea.focus()
    textarea.select()

    try {
      const successful = document.execCommand('copy')
      if (!successful) {
        throw new Error('execCommand returned false')
      }
    } catch (err) {
      console.error("[tabulator] Fallback copy failed:", err)

      // Try modern clipboard API as last resort
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(e => {
          throw new Error("Clipboard API failed: " + e.message)
        })
      } else {
        throw new Error("Clipboard not supported")
      }
    } finally {
      document.body.removeChild(textarea)
    }
  }

  /**
   * Copy selected rows to clipboard (legacy method)
   * @deprecated Use copyToClipboard instead
   */
  copySelection() {
    if (!this.table) return

    const selectedRows = this.table.getSelectedRows()
    if (selectedRows.length === 0) {
      this.showToast("warning", "No hay filas seleccionadas")
      return
    }

    this.table.copyToClipboard("selected")
    this.showToast("success", `${selectedRows.length} filas copiadas al portapapeles`)
  }
}

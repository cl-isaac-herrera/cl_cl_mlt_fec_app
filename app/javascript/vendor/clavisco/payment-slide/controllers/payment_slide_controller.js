import BaseSlideController from "vendor/clavisco/base/controllers/base_slide_controller"
import { getAPIHeaders } from "lib/api_helpers"
import { CurrentSession } from "mixins/use_current_session"
import Swal from 'sweetalert2'

/**
 * Payment Slide Controller
 *
 * Reemplaza @clavisco/payment-modal (NuGet) con un slide lateral.
 * Maneja: efectivo, tarjeta (+ PinPad), transferencia.
 *
 * Eventos de entrada:  payment-slide:open    { docTotal, currency, allowPartial, allowCredit, whsCode }
 *                      payment-slide:close   {} → cierra el slide (despachado por el controlador en éxito)
 * Eventos de salida:   payment-slide:confirm { docTotal, totalPaid, change, payments, balance }
 *
 * @extends BaseSlideController
 */
export default class extends BaseSlideController {
  static targets = [
    ...BaseSlideController.targets,
    "docTotal", "balance", "change",
    "tabCash", "tabCard", "tabTransfer",
    "panelCash", "panelCard", "panelTransfer",
    "cashAmount",
    "cardAmount", "cardType", "cardNumber", "cardExpiry", "cardAuth", "cardTerminal",
    "transferAmount", "transferRef", "transferBank",
    "paymentsList"
  ]

  static values = {
    ...BaseSlideController.values,
    docTotal: { type: Number, default: 0 },
    payments: { type: Array, default: [] },
    terminals: { type: Array, default: [] },
    transferAccounts: { type: Array, default: [] },
    cardAccounts: { type: Array, default: [] },
    whsCode: { type: String, default: "" },
    currency: { type: String, default: "USD" },
    allowPartial: { type: Boolean, default: false },
    allowCredit: { type: Boolean, default: true }
  }

  connect() {
    super.connect()
    this.loadConfiguration()
    this.loadAccountsFromSession()
    this.boundOpen = this.handleOpenEvent.bind(this)
    this.boundExternalClose = () => this.close()
    window.addEventListener("payment-slide:open", this.boundOpen)
    window.addEventListener("payment-slide:close", this.boundExternalClose)
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("payment-slide:open", this.boundOpen)
    window.removeEventListener("payment-slide:close", this.boundExternalClose)
  }

  handleOpenEvent(event) {
    if (!event?.detail) return
    const { docTotal, currency, allowPartial, allowCredit, whsCode } = event.detail

    if (allowPartial !== undefined) this.allowPartialValue = allowPartial
    if (allowCredit !== undefined) this.allowCreditValue = allowCredit
    this.docTotalValue = docTotal || 0
    this.currencyValue = currency || "USD"
    this.paymentsValue = []

    // Resolver whsCode: del evento → valor cacheado → sesión actual
    let sessionWhsCode = CurrentSession.getWhsCode()
    if (!sessionWhsCode) {
      try {
        sessionWhsCode = JSON.parse(localStorage.getItem('CurrentSession') || '{}').WhsCode || ''
      } catch { /* ignore */ }
    }
    const resolvedWhsCode = whsCode || this.whsCodeValue || sessionWhsCode

    // Cargar cuentas si aún no se han cargado o cambia el almacén
    if (resolvedWhsCode && (this.cardAccountsValue.length === 0 || resolvedWhsCode !== this.whsCodeValue)) {
      this.whsCodeValue = resolvedWhsCode
      this.loadCardAccounts(resolvedWhsCode)
    } else if (this.cardAccountsValue.length > 0) {
      // Re-poblar dropdowns con datos en cache (el DOM puede haberse reiniciado)
      this.populateCardAccounts()
      this.populateTransferAccounts()
    }

    this.updateDisplay()
    this.switchTab("cash")
    this.open()
  }

  // ============================================
  // Configuración inicial
  // ============================================

  /**
   * Precarga cuentas de tarjeta/transferencia al montar el controller.
   * Angular: LoadAccounts() usa CurrentSession.WhsCode para cargar al inicio.
   * Esto asegura que los dropdowns estén listos cuando se abra el slide,
   * incluso si el caller no pasa whsCode en el evento.
   */
  /**
   * Precarga cuentas de tarjeta/transferencia al montar el controller.
   * Angular: LoadAccounts() usa CurrentSession.WhsCode para cargar al inicio.
   * Esto asegura que los dropdowns estén listos cuando se abra el slide,
   * incluso si el caller no pasa whsCode en el evento.
   *
   * NOTA: Las cuentas dependen del almacén seleccionado en la sesión.
   * Ej: almacén "01" (Bodega Escazu) devuelve cuentas de tarjeta; otros almacenes pueden no tener.
   * Si CurrentSession no está disponible aún (módulo cargado antes del login), lee de localStorage.
   */
  loadAccountsFromSession() {
    let whsCode = CurrentSession.getWhsCode()
    if (!whsCode) {
      try {
        const session = JSON.parse(localStorage.getItem('CurrentSession') || '{}')
        whsCode = session.WhsCode || ''
      } catch { /* ignore */ }
    }
    if (whsCode && this.cardAccountsValue.length === 0) {
      this.whsCodeValue = whsCode
      this.loadCardAccounts(whsCode)
    }
  }

  async loadConfiguration() {
    try {
      const response = await fetch("/api/terminals", {
        headers: getAPIHeaders({ successDescription: "Terminales obtenidos", errorDescription: "Error cargando terminales" })
      })
      if (response.ok) {
        const data = await response.json()
        this.terminalsValue = data.Data || []
        this.populateTerminals()
      } else {
        // Background config load — no toast, only log (fires on page load, not user action)
        console.warn("Terminales no disponibles:", response.status)
      }
    } catch (error) {
      console.error("Error loading payment config:", error)
    }
  }

  async loadCardAccounts(whsCode) {
    try {
      const response = await fetch(`/api/Accounts?Store=${encodeURIComponent(whsCode)}`, {
        headers: getAPIHeaders({ successDescription: "Cuentas obtenidas", errorDescription: "Error cargando cuentas" })
      })
      if (response.ok) {
        const data = await response.json()
        const accounts = data.Data || []
        // Type 2 = CARD, Type 3 = TRANSFER (legacy: MapAccountType case 2/3 → ACCOUNT_TYPE)
        this.cardAccountsValue = accounts.filter(a => a.Type === 2)
        this.transferAccountsValue = accounts.filter(a => a.Type === 3)
        this.populateCardAccounts()
        this.populateTransferAccounts()
      } else {
        this.showToast("Error al cargar cuentas", "error")
      }
    } catch (error) {
      console.error("[payment-slide] Error loading accounts:", error)
      this.showToast("Error al cargar cuentas", "error")
    }
  }

  populateTerminals() {
    if (!this.hasCardTerminalTarget) return
    const options = this.terminalsValue.map(t => `<option value="${t.Id}">${t.Description}</option>`).join("")
    this.cardTerminalTarget.innerHTML = `<option value="">Seleccionar terminal</option>${options}`
  }

  populateTransferAccounts() {
    if (!this.hasTransferBankTarget) return
    // API retorna: Id, AcctCode, AcctName, ActCurr, Type (legacy: accounts.service.ts MapAccountType case 3 → TRANSFER)
    const options = this.transferAccountsValue.map(a =>
      `<option value="${a.AcctCode}">${a.AcctName}</option>`
    ).join("")
    this.transferBankTarget.innerHTML = `<option value="">Seleccionar cuenta</option>${options}`
  }

  populateCardAccounts() {
    if (!this.hasCardTypeTarget) return
    // API retorna: Id, AcctCode, AcctName, ActCurr, Type (legacy: accounts.service.ts)
    const options = this.cardAccountsValue.map(a =>
      `<option value="${a.Id}" data-acct="${a.AcctCode}">${a.AcctName}</option>`
    ).join("")
    this.cardTypeTarget.innerHTML = `<option value="">Seleccionar tipo</option>${options}`
  }

  // ============================================
  // Tabs
  // ============================================

  onTabClick(event) {
    this.switchTab(event.currentTarget.dataset.tab)
  }

  switchTab(tabName) {
    const tabs = {
      cash: this.hasTabCashTarget ? this.tabCashTarget : null,
      card: this.hasTabCardTarget ? this.tabCardTarget : null,
      transfer: this.hasTabTransferTarget ? this.tabTransferTarget : null
    }
    const panels = {
      cash: this.hasPanelCashTarget ? this.panelCashTarget : null,
      card: this.hasPanelCardTarget ? this.panelCardTarget : null,
      transfer: this.hasPanelTransferTarget ? this.panelTransferTarget : null
    }

    Object.entries(tabs).forEach(([name, tab]) => {
      if (!tab) return
      const active = name === tabName
      tab.classList.toggle("border-blue-500", active)
      tab.classList.toggle("text-blue-600", active)
      tab.classList.toggle("border-transparent", !active)
      tab.classList.toggle("text-gray-500", !active)
    })

    Object.entries(panels).forEach(([name, panel]) => {
      if (!panel) return
      panel.classList.toggle("hidden", name !== tabName)
    })
  }

  // ============================================
  // Display
  // ============================================

  updateDisplay() {
    const totalPaid = this.calculateTotalPaid()
    const balance = this.docTotalValue - totalPaid
    const change = Math.max(0, totalPaid - this.docTotalValue)

    if (this.hasDocTotalTarget) this.docTotalTarget.textContent = this.formatCurrency(this.docTotalValue)

    if (this.hasBalanceTarget) {
      this.balanceTarget.textContent = this.formatCurrency(Math.max(0, balance))
      this.balanceTarget.classList.toggle("text-red-600", balance > 0)
      this.balanceTarget.classList.toggle("text-green-600", balance <= 0)
    }

    if (this.hasChangeTarget) {
      this.changeTarget.textContent = this.formatCurrency(change)
      const changeRow = this.changeTarget.closest("[data-change-row]")
      changeRow?.classList.toggle("hidden", change === 0)
    }

    this.renderPaymentsList()
  }

  calculateTotalPaid() {
    return this.paymentsValue.reduce((sum, p) => sum + (p.amount || 0), 0)
  }

  formatCurrency(amount) {
    const currency = this.currencyValue === "COL" ? "CRC" : (this.currencyValue || "USD")
    try {
      return new Intl.NumberFormat("es-CR", { style: "currency", currency }).format(amount)
    } catch {
      return amount.toFixed(2)
    }
  }

  renderPaymentsList() {
    if (!this.hasPaymentsListTarget) return

    if (this.paymentsValue.length === 0) {
      this.paymentsListTarget.innerHTML = '<p class="text-gray-400 text-sm text-center py-8">Sin pagos agregados</p>'
      return
    }

    const typeLabels = { cash: "Efectivo", card: "Tarjeta", transfer: "Transferencia" }
    this.paymentsListTarget.innerHTML = this.paymentsValue.map((p, idx) => `
      <div class="flex items-center justify-between py-2 border-b border-gray-100 last:border-0">
        <div>
          <span class="text-sm font-medium text-gray-800">${typeLabels[p.type] || p.type}</span>
          ${p.reference ? `<span class="text-xs text-gray-500 ml-2">(${p.reference})</span>` : ""}
        </div>
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold">${this.formatCurrency(p.amount)}</span>
          <button type="button"
                  class="p-1 text-red-400 hover:text-red-600 transition-colors"
                  data-action="click->payment-slide#removePayment"
                  data-idx="${idx}"
                  title="Eliminar">
            <span class="material-symbols-outlined text-base leading-none">delete</span>
          </button>
        </div>
      </div>
    `).join("")
  }

  // ============================================
  // Agregar pagos
  // ============================================

  addCashPayment() {
    const amount = parseFloat(this.cashAmountTarget?.value || 0)
    if (amount <= 0) { this.showToast("Ingrese un monto válido", "warning"); return }
    this.paymentsValue = [...this.paymentsValue, { type: "cash", amount }]
    if (this.hasCashAmountTarget) this.cashAmountTarget.value = ""
    this.updateDisplay()
  }

  fillWithCash() {
    const balance = this.docTotalValue - this.calculateTotalPaid()
    if (balance > 0 && this.hasCashAmountTarget) {
      this.cashAmountTarget.value = balance.toFixed(2)
    }
  }

  addCardPayment() {
    const amount = parseFloat(this.cardAmountTarget?.value || 0)
    if (amount <= 0) { this.showToast("Ingrese un monto válido", "warning"); return }

    // Cuenta SAP — requerido como en legacy (CardFormGuard)
    const selectedOption = this.cardTypeTarget?.selectedOptions?.[0]
    const creditCardId = parseInt(this.cardTypeTarget?.value || 0)
    if (!creditCardId) { this.showToast("Por favor seleccione una cuenta", "warning"); return }
    const creditAcct = selectedOption?.dataset?.acct || ""

    const cardNumber = this.cardNumberTarget?.value || ""
    if (!cardNumber) { this.showToast("Por favor ingrese un número de tarjeta", "warning"); return }

    const expiryRaw = this.cardExpiryTarget?.value || "" // YYYY-MM from input[type=month]
    if (!expiryRaw) { this.showToast("Por favor seleccione una fecha de vencimiento", "warning"); return }
    // Convertir YYYY-MM → M/YYYY (formato legacy)
    const [year, month] = expiryRaw.split("-")
    const cardExpiry = `${parseInt(month)}/${year}`

    const authCode = this.cardAuthTarget?.value || ""
    if (!authCode) { this.showToast("Por favor ingrese un número de voucher", "warning"); return }

    const terminal = this.cardTerminalTarget?.value || ""

    this.paymentsValue = [...this.paymentsValue, {
      type: "card", amount,
      creditCardId, creditAcct,
      cardNumber: cardNumber.slice(-4), cardExpiry, authCode, terminal,
      reference: authCode || cardNumber.slice(-4)
    }]
    if (this.hasCardAmountTarget) this.cardAmountTarget.value = ""
    if (this.hasCardExpiryTarget) this.cardExpiryTarget.value = ""
    if (this.hasCardNumberTarget) this.cardNumberTarget.value = ""
    if (this.hasCardAuthTarget) this.cardAuthTarget.value = ""
    this.updateDisplay()
  }

  addTransferPayment() {
    const amount = parseFloat(this.transferAmountTarget?.value || 0)
    if (amount <= 0) { this.showToast("Ingrese un monto válido", "warning"); return }
    const bank = this.transferBankTarget?.value || ""
    if (!bank) { this.showToast("Por favor seleccione la cuenta", "warning"); return }
    const reference = this.transferRefTarget?.value || ""
    this.paymentsValue = [...this.paymentsValue, { type: "transfer", amount, reference, bank }]
    if (this.hasTransferAmountTarget) this.transferAmountTarget.value = ""
    if (this.hasTransferRefTarget) this.transferRefTarget.value = ""
    this.updateDisplay()
  }

  removePayment(event) {
    const idx = parseInt(event.currentTarget.dataset.idx)
    this.paymentsValue = this.paymentsValue.filter((_, i) => i !== idx)
    this.updateDisplay()
  }

  // ============================================
  // Confirmar / Cancelar
  // ============================================

  confirm() {
    const totalPaid = this.calculateTotalPaid()
    const balance = this.docTotalValue - totalPaid

    if (balance > 0 && !this.allowPartialValue) {
      this.showToast("El pago debe cubrir el total del documento", "warning")
      return
    }

    const change = Math.max(0, totalPaid - this.docTotalValue)
    window.dispatchEvent(new CustomEvent("payment-slide:confirm", {
      detail: {
        docTotal: this.docTotalValue,
        totalPaid,
        change,
        payments: this.paymentsValue,
        balance: Math.max(0, balance)
      }
    }))
    // El slide NO se cierra aquí. El controlador lo cierra via payment-slide:close
    // solo cuando la API responde con éxito. Si hay error, el slide permanece abierto
    // con los datos del pago intactos para que el usuario pueda reintentar.
  }

  cancel(event) {
    event?.preventDefault()
    this.close()
  }

  onSlideClosed() {
    super.onSlideClosed()
    this.paymentsValue = []
  }

  // ============================================
  // PinPad
  // ============================================

  async processPinPad() {
    const amount = parseFloat(this.cardAmountTarget?.value || 0)
    const terminal = this.cardTerminalTarget?.value
    if (amount <= 0 || !terminal) {
      this.showToast("Ingrese monto y seleccione terminal", "warning")
      return
    }

    document.dispatchEvent(new CustomEvent("overlay:show", {
      detail: { message: "Procesando pago con tarjeta..." },
      bubbles: true
    }))

    try {
      const response = await fetch("/api/pinpad/process", {
        method: "POST",
        headers: {
          ...getAPIHeaders({ successDescription: "Pago procesado", errorDescription: "Error al procesar pago" }),
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ amount, terminalId: terminal, transactionType: "Sale" })
      })

      if (response.ok) {
        const result = await response.json()
        this.paymentsValue = [...this.paymentsValue, {
          type: "card", amount,
          authCode: result.Data?.AuthorizationCode,
          reference: result.Data?.AuthorizationCode,
          terminal,
          pinpadResponse: result.Data
        }]
        if (this.hasCardAmountTarget) this.cardAmountTarget.value = ""
        this.updateDisplay()
        this.showToast("Pago procesado correctamente", "success")
      } else {
        const error = await response.json()
        this.showToast(error.Message || error.message || "Error al procesar pago", "error")
      }
    } catch (error) {
      console.error("PinPad error:", error)
      this.showToast("Error de comunicación con el PinPad", "error")
    } finally {
      document.dispatchEvent(new CustomEvent("overlay:hide", { bubbles: true }))
    }
  }

  // ============================================
  // UI helpers
  // ============================================

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

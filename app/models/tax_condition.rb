# frozen_string_literal: true

# Catálogo `CondicionImpuesto` del mensaje receptor (`"01".."05"`) y el
# cálculo de impuesto acreditable / gasto aplicable que depende de él.
#
# Migra el switch de `InvoiceHandler.cs:540-562` (mail parser legacy) más el
# truncamiento a 5 decimales de `Truncate` (`InvoiceHandler.cs:1242-1247`).
# Antes de esto el catálogo solo vivía en vistas/JS de la pantalla de
# recepción (`app/views/documents/receptions/index.html.erb:546-550`,
# `documents_reception_controller.js` → `TAX_FACTOR_CONDITIONS`), sin ningún
# backend Ruby que aplicara la fórmula.
module TaxCondition
  GENERATES_TAX_CREDIT         = '01' # Genera Crédito IVA
  GENERATES_PARTIAL_TAX_CREDIT = '02' # Genera Crédito parcial del IVA
  CAPITAL_GOODS                = '03' # Bienes de Capital
  CURRENT_EXPENSE              = '04' # Gasto corriente no genera crédito
  PROPORTIONALITY               = '05' # Proporcionalidad

  LABELS = {
    GENERATES_TAX_CREDIT         => 'Genera Crédito IVA',
    GENERATES_PARTIAL_TAX_CREDIT => 'Genera Crédito parcial del IVA',
    CAPITAL_GOODS                => 'Bienes de Capital',
    CURRENT_EXPENSE               => 'Gasto corriente no genera crédito',
    PROPORTIONALITY               => 'Proporcionalidad'
  }.freeze

  ALL = LABELS.keys.freeze

  # `03`/`05` son las únicas condiciones cuya fórmula depende de `TaxFactor`
  # (`documents_reception_controller.js` → `TAX_FACTOR_CONDITIONS`).
  REQUIRES_TAX_FACTOR = [ CAPITAL_GOODS, PROPORTIONALITY ].freeze

  DECIMALS = 5

  # `tax_credit` → `MontoTotalImpuestoAcreditar`; `applicable_expense` →
  # `MontoTotalDeGastoAplicable`. `nil` en el campo que la condición no
  # calcula — no `0`: cero sería "se calculó y dio cero", que es distinto de
  # "esta condición no calcula esto".
  Result = Struct.new(:tax_credit, :applicable_expense, keyword_init: true)

  module_function

  def valid?(value)
    ALL.include?(value)
  end

  def label(value)
    LABELS.fetch(value, value.to_s)
  end

  def requires_tax_factor?(value)
    REQUIRES_TAX_FACTOR.include?(value)
  end

  # @param condition [String, nil] `"01".."05"`.
  # @param tax_amount [Numeric] `MontoTotalImpuesto` del documento.
  # @param tax_factor [Numeric, nil] `TaxFactor`, solo lo usan `03`/`05`.
  # @return [Result]
  #
  # ⚠️ `02` deliberadamente no calcula nada (los dos campos quedan `nil`) — es
  # una laguna real del legacy (`InvoiceHandler.cs:546-547`, un `break`
  # vacío), no un caso sin contemplar: el catálogo la valida como condición
  # aceptable, pero ningún `case` del switch original le asigna una fórmula.
  # Se replica tal cual, no se "completa".
  def apply(condition:, tax_amount:, tax_factor: nil)
    amount = tax_amount.to_d
    factor = tax_factor.to_d

    case condition
    when GENERATES_TAX_CREDIT
      Result.new(tax_credit: truncate(amount), applicable_expense: nil)
    when CAPITAL_GOODS
      Result.new(tax_credit: truncate(applied(amount, factor)), applicable_expense: nil)
    when CURRENT_EXPENSE
      Result.new(tax_credit: nil, applicable_expense: truncate(amount))
    when PROPORTIONALITY
      credited = applied(amount, factor)
      Result.new(tax_credit: truncate(credited), applicable_expense: truncate(amount - credited))
    else
      Result.new(tax_credit: nil, applicable_expense: nil)
    end
  end

  def applied(amount, factor)
    amount * (factor / 100)
  end
  private_class_method :applied

  # Trunca (NO redondea) a `DECIMALS` decimales — mismo comportamiento que
  # `Truncate` del legacy: multiplica por 10^n, descarta la parte
  # fraccionaria y divide de vuelta.
  def truncate(value)
    factor = 10**DECIMALS
    (value * factor).truncate / factor.to_d
  end
end

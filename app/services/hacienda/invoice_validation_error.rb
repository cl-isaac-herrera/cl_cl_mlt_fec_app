# frozen_string_literal: true

module Hacienda
  # Un incumplimiento de una regla de negocio de Hacienda, sobre el objeto
  # unificado que arma `Documents::UnifiedBuilder`.
  #
  # No es una excepción: `Hacienda::InvoiceValidator` acumula estas en vez de
  # levantar en la primera que encuentra (a diferencia del legacy .NET,
  # `Validations.OwnValidations`, que corta en el primer `throw`). Devolver
  # TODAS las que aplican de una sola pasada es mejor para quien tiene que
  # corregir el documento en SAP: enterarse de los diez problemas de una vez y
  # no de a uno por intento.
  #
  # @!attribute [r] message
  #   Texto en español, listo para mostrar u guardar (p. ej. en
  #   `Documents::PendingQueue.mark_error`).
  # @!attribute [r] field
  #   Nombre del campo del objeto unificado que falló, en la misma notación
  #   PascalCase del payload (`'CondicionVenta'`, `'ResumenFactura.TotalVenta'`).
  #   Puede ser `nil` cuando el error no es de un campo puntual sino de una
  #   relación entre varios (p. ej. un cuadre de totales).
  # @!attribute [r] line_number
  #   Número de línea de `DetalleServicio` cuando el error es de una línea en
  #   particular, o `nil` si no aplica.
  InvoiceValidationError = Data.define(:message, :field, :line_number) do
    def initialize(message:, field: nil, line_number: nil)
      super
    end

    def to_s = message
  end
end

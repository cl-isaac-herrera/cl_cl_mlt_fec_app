# frozen_string_literal: true

# ¿La compañía usa el bloque `Otros` del XML de Hacienda?
#
# `Otros` es una sección opcional del comprobante electrónico: pares
# código/valor con información adicional que cada cliente decide si necesita.
# La consulta que la alimenta (`qsGetDocumentOthersInfo`) es una vuelta más al
# Service Layer por documento, así que no se paga cuando nadie la va a leer.
#
# `false` por defecto a propósito: es el comportamiento de hoy —ninguna compañía
# manda el bloque— y una migración no debe cambiar en silencio lo que se le envía
# a Hacienda. Quien lo necesite lo enciende.
#
# `null: false` porque el consumidor lo evalúa como condición
# (`if company.use_additional_fields?`) y un `nil` ahí sería un tercer estado que
# no significa nada.
class AddUseAdditionalFieldsToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :use_additional_fields, :boolean, default: false, null: false
  end
end

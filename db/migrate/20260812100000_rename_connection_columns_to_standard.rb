# frozen_string_literal: true

# Alinea `connections` con CLAVISCO-PLATFORM-STANDARDS §8, que nombra la columna
# de la URL del Service Layer como `sl_url`:
#
#   ★ connections — perfil de conexión SAP por servidor (sl_url)
#
# `service_layer_type` no aparece en el estándar (es una columna propia de este
# producto para distinguir el motor sobre el que corre SAP), pero se renombra a
# `sl_type` por consistencia con su tabla: el prefijo `sl_` ya es el del estándar.
class RenameConnectionColumnsToStandard < ActiveRecord::Migration[8.1]
  def change
    rename_column :connections, :service_layer_url,  :sl_url
    rename_column :connections, :service_layer_type, :sl_type
  end
end

# frozen_string_literal: true

# Consulta al Service Layer definida como dato, no como código.
#
# Cada fila describe UNA lectura a SAP: a qué recurso/vista se le pega
# (`resource`), con qué query string OData (`query_params`) y de cuántas filas es
# la página (`page_size`). El objetivo es poder ajustar filtros, campos y tamaño
# de página desde la interfaz, sin redeploy.
#
# ⚠️ La fila NO dice CÓMO se habla con SAP. El transporte sigue siendo
# `Clavisco::ServiceLayer::Client` (CLAUDE.md §29): `base_url` sale de
# `connections.sl_url` y la base destino de `companies.sap_db_code`. Acá vive
# únicamente el path relativo y su query.
#
# `is_standard` distingue las consultas que trae el producto de las que el
# cliente agregó o modificó: las estándar son las que un `db:seed` puede
# reescribir sin consultarle a nadie.
class CreateSlResources < ActiveRecord::Migration[8.1]
  def change
    create_table :sl_resources do |t|
      # Identificador funcional con el que la app pide la consulta por nombre
      # (ej. 'ACCOUNTS'), en vez de tener el path escrito en el código.
      t.string :code, null: false, limit: 100
      t.string :description

      # `text` y no `string`: el recurso de una vista semántica ya ronda los 60
      # caracteres y la query OData ($select + $filter + $orderby) pasa los 250
      # sin esfuerzo.
      t.text :resource, null: false
      t.text :query_params

      t.integer :page_size
      t.boolean :is_standard, default: false, null: false

      t.boolean :is_active, default: true, null: false
      t.string  :created_by
      t.string  :updated_by

      t.timestamps
    end

    # El `code` es la llave con la que la app pide la consulta, así que no puede
    # repetirse. El índice NO excluye a las filas inactivas a propósito: dar de
    # baja una consulta no libera su código, y volver a habilitarla tiene que
    # reactivar esa misma fila en vez de insertar otra al lado (mismo criterio
    # que `user_permissions`).
    add_index :sl_resources, :code, unique: true
  end
end

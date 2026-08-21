# frozen_string_literal: true

# Ajustes de la instalación, con el valor cifrado.
#
# Es la contraparte de la tabla `Setting` del API .NET, que el módulo
# Configuraciones → Generales ya consume por proxy (`GET|PATCH /api/settings`).
# El origen guarda tres filas —`CedulaProveedorSistemas`, `CrystalUser` y
# `CrystalPassword`— con la forma `{ Code, Json, UpdateDate, UpdatedBy }`.
#
# Dos cosas cambian respecto al origen:
#
#   1. La columna del valor se llama `value`, no `Json`. En el .NET nunca guardó
#      JSON: son strings planos. El nombre venía de un tipo que se abandonó.
#
#   2. El valor va CIFRADO y puede no devolverse. El .NET manda
#      `CrystalPassword` en claro al browser y la UI la enmascara con un
#      `type="password"` que tiene botón para revelarla
#      (`general_configs_controller.js:137`). `is_visible` corta eso en el
#      servidor: cuando es `false`, el valor no sale de la base.
#
# ---------------------------------------------------------------------------
# Por qué el valor es `text` y NO lleva `limit:`
#
# `encrypts` guarda un sobre JSON (`{"p":…,"h":{"iv":…,"at":…}}`): ~70 caracteres
# fijos más 4/3 del texto original. Dimensionar la columna contra el dato en
# claro es el error que advierte CLAUDE.md §29 — una contraseña de 50 chars ocupa
# 138. SQLite ignora el largo de un `varchar`, así que hoy no se notaría, pero si
# la base se muda a una que sí lo respeta la fila se trunca y el valor queda
# indescifrable. El largo del texto en claro se valida en el modelo, que es donde
# corresponde.
#
# ---------------------------------------------------------------------------
# Por qué `group_code` es una columna y no se deriva del `code`
#
# La convención agrupa por prefijo (`DOCS_DB_ODBC_USER` → `DOCS_DB_ODBC`), pero
# derivarla partiendo por el último `_` se rompe con el primer campo de dos
# palabras: `DOCS_DB_ODBC_QUERY_TIMEOUT` daría el grupo `DOCS_DB_ODBC_QUERY`. El
# grupo igual se declara en `db/seeds.rb`, así que la columna solo materializa
# esa declaración y la pantalla agrupa por un `WHERE`, no parseando strings.
#
# ---------------------------------------------------------------------------
# Índices
#
# `code` es la llave natural: es por donde entra toda lectura
# (`Setting.value_for`) y es lo que identifica la fila en la URL del endpoint
# (`PATCH /api/settings/:code`, §28). El índice único NO excluye a las filas
# inactivas, así que la validación de unicidad del modelo tiene que pedir
# `unscope(where: :is_active)` o el choque sale como un 500 de la base.
#
# El valor no se indexa ni se busca: el cifrado es no determinista (el mismo
# texto produce un criptograma distinto cada vez), así que un índice no serviría
# de nada y un `where(value: …)` nunca encuentra nada.
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :code,        null: false
      t.string :group_code,  null: false
      t.string :description, null: false

      # Nullable a propósito: `db/seeds.rb` declara el ajuste SIN valor. La fila
      # existe para que la pantalla la muestre y el operador la complete; hasta
      # entonces `value` es NULL y el consumidor levanta con un mensaje que dice
      # qué falta configurar, en vez de intentar conectarse con credenciales
      # vacías y fallar con un error del driver.
      t.text :value

      # ¿El valor se le devuelve a la UI? `false` = campo de solo escritura
      # (contraseñas). Solo lo setea el seed; el endpoint de actualización jamás
      # lo toca.
      t.boolean :is_visible, null: false, default: true

      # Columnas de auditoría y baja lógica, como el resto de las tablas del
      # proyecto (`Auditable` + `SoftDeletable`).
      t.boolean :is_active, null: false, default: true
      t.string  :created_by
      t.string  :updated_by
      t.timestamps
    end

    add_index :settings, :code, unique: true
    add_index :settings, :group_code
  end
end

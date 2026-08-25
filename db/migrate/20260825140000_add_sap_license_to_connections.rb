# frozen_string_literal: true

# Credenciales de licencia de SAP para el servidor de Service Layer.
#
# ── Por qué hacen falta ──────────────────────────────────────────────────────
# `Clavisco::ServiceLayer::Client` exige `username`/`password` para el `/Login`
# (`CLAUDE.md` §29). Hasta ahora las únicas credenciales de SAP del producto
# vivían en `users.sap_user` / `users.sap_password`, atadas a la persona que está
# usando la pantalla: el request sabe quién es por `Current.user`.
#
# `SyncIssuedDocumentsJob` corre **sin usuario en sesión** — lo despierta el
# scheduler de Solid Queue, no una persona— así que no hay de dónde sacarlas. Un
# trabajo de fondo que dependiera de la cuenta personal de alguien dejaría de
# emitir el día que esa persona cambia su contraseña o se va de la empresa.
#
# ── Por qué en `connections` y no en `companies` ─────────────────────────────
# La licencia es del **servidor** de Service Layer, no de la compañía: varias
# compañías del mismo servidor se distinguen por su `sap_db` y comparten el
# `/Login`. Ponerla en `companies` obligaría a repetir el mismo par de valores en
# cada fila y a mantenerlos sincronizados a mano — el mismo argumento por el que
# `user_permissions` no lleva `company_id` (`CLAUDE.md` §28).
#
# Es también lo más cercano a la tabla `sap_licenses` que pide el estándar §8 y
# que este producto todavía no tiene (ver `TODOS.md` → SAP).
#
# ── Tipos ────────────────────────────────────────────────────────────────────
# `sap_license_password` va como `t.text` y **sin `limit:`**, que es la regla 4 de
# `CLAUDE.md` §29: lo que se guarda no es la contraseña sino el sobre del cifrado
# (`{"p":…,"h":{"iv":…,"at":…}}`), ~70 caracteres fijos más 4/3 del texto
# original. Dimensionar la columna contra el largo del dato deja el valor
# truncado en cuanto la base sea una que respete el `limit:`.
#
# El largo del texto en claro se valida en el modelo, que es donde se puede mirar
# el dato antes de cifrarlo.
class AddSapLicenseToConnections < ActiveRecord::Migration[8.1]
  def change
    change_table :connections, bulk: true do |t|
      # Usuario de SAP con licencia para el Service Layer de este servidor.
      t.string :sap_license, limit: 100

      # Cifrada con ActiveRecord Encryption (`encrypts` en el modelo). Reversible
      # y no un digest: el `/Login` necesita la contraseña en claro.
      t.text   :sap_license_password
    end
  end
end

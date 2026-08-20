# frozen_string_literal: true

# Corrige el default de `companies.email_sender_type`: era 0, y 0 no es un valor
# válido.
#
# La columna dice con qué nombre se envían los correos, y solo hay dos opciones —
# las mismas que el `<select>` del formulario y que el `NameToEmail` del legado:
#
#   1 → Nombre legal
#   2 → Nombre comercial
#
# El 0 se inventó al crear la columna porque el origen la traía `not null` sin
# default documentado. Se notó cuando el formulario empezó a leerla: al asignarle
# `"0"` a un `<select>` que solo tiene las opciones `1` y `2`, el navegador no
# encuentra la opción y deja el campo **sin nada seleccionado** — un campo
# obligatorio que se ve vacío y que el usuario tiene que rellenar a mano sin saber
# por qué.
#
# El backfill va ANTES de cambiar el default: si se hiciera al revés, las filas
# que ya tienen 0 se quedarían inválidas frente a la validación de inclusión que
# se agrega en el modelo, y cualquier `update!` sobre ellas fallaría.
class FixEmailSenderTypeDefault < ActiveRecord::Migration[8.1]
  LEGAL_NAME = 1
  INVALID    = 0

  def up
    execute "UPDATE companies SET email_sender_type = #{LEGAL_NAME} " \
            "WHERE email_sender_type = #{INVALID}"

    change_column_default :companies, :email_sender_type, from: INVALID, to: LEGAL_NAME
  end

  def down
    change_column_default :companies, :email_sender_type, from: LEGAL_NAME, to: INVALID
    # Los valores NO se revierten: no se puede distinguir un 1 que puso este
    # backfill de un 1 que eligió alguien en la pantalla.
  end
end

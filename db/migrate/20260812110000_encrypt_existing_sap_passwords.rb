# frozen_string_literal: true

# Cifra las contraseñas de SAP que quedaron en texto plano.
#
# `encrypts :sap_password` solo actúa cuando el atributo se escribe. Las filas
# guardadas antes de que existiera —y las que la pantalla de perfil nunca reescribe,
# porque manda la contraseña vacía cuando el usuario no la retoca— se quedaron en
# claro, y `support_unencrypted_data` las dejaba leer sin protestar.
#
# Se hace acá y no en una rake task para que corra sí o sí en cada ambiente al
# desplegar: mientras quede una fila en claro, el cifrado de la columna es decorativo.
class EncryptExistingSapPasswords < ActiveRecord::Migration[8.1]
  # Modelo propio y mínimo: la migración no puede depender de que `User` siga
  # teniendo estas columnas o este `encrypts` dentro de un año. Solo se usa para
  # obtener el tipo cifrado del atributo.
  class MigrationUser < ActiveRecord::Base
    self.table_name = 'users'
    encrypts :sap_password
  end

  def up
    MigrationUser.reset_column_information
    cipher = MigrationUser.type_for_attribute('sap_password')

    plaintext_rows.each do |id, plain|
      # Se escribe el texto cifrado con SQL directo, sin pasar por el atributo del
      # modelo: su getter levantaría con support_unencrypted_data = false, y su
      # dirty tracking no vería cambio porque el valor lógico es el mismo.
      connection.update(
        MigrationUser.sanitize_sql(
          ['UPDATE users SET sap_password = ? WHERE id = ?', cipher.serialize(plain), id]
        )
      )
      say "sap_password cifrada para el usuario ##{id}"
    end
  end

  # Irreversible a propósito: revertirla significaría volver a escribir las
  # contraseñas en claro, que es exactamente lo que esta migración vino a arreglar.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Filas con contraseña guardada que todavía NO están cifradas. Se leen con SQL
  # crudo porque el atributo del modelo está tipado como cifrado: consultarlo o
  # leerlo daría error, no el texto que hay que rescatar.
  def plaintext_rows
    connection
      .select_rows("SELECT id, sap_password FROM users WHERE sap_password IS NOT NULL AND sap_password != ''")
      .reject { |(_id, raw)| encrypted?(raw) }
  end

  # ActiveRecord Encryption guarda un JSON con el payload y su cabecera:
  # {"p":"<cifrado>","h":{"iv":"...","at":"..."}}
  def encrypted?(raw)
    raw.to_s.start_with?('{') && raw.to_s.include?('"p"')
  end
end

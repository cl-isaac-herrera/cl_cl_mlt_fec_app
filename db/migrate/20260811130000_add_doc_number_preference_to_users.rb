# frozen_string_literal: true

# Preferencia de "Tipo de OC" del perfil (Con/Sin número de OC).
#
# Viene de `Users.DocNumberPreference` del API .NET, donde es un `varchar(2)` que
# guarda el valor del select ("1"/"2"), no un booleano. Se conserva como texto para
# no reinterpretar el dato al importar.
class AddDocNumberPreferenceToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :doc_number_preference, :string
  end
end

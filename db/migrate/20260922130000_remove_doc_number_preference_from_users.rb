# frozen_string_literal: true

# "Tipo de OC" (Con/Sin número de OC) no tiene consumidor: ningún proceso de este
# producto lo lee, y en el formulario solo aparecía para dos ids de compañía del
# .NET hardcodeados en el frontend. Se elimina junto con el campo de la vista.
class RemoveDocNumberPreferenceFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :doc_number_preference, :string
  end
end

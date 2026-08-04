class CreateRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :roles do |t|
      t.string :name, null: false
      t.boolean :is_active, default: true, null: false
      t.string :created_by
      t.string :updated_by

      t.timestamps
    end
  end
end

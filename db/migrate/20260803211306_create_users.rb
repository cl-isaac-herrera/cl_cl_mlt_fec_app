class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :name
      t.boolean :is_active, default: true, null: false
      t.string :created_by
      t.string :updated_by

      t.timestamps
    end
    add_index :users, :email, unique: true
  end
end

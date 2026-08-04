class CreateUserRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :user_roles do |t|
      t.references :user, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.boolean :is_active, default: true, null: false
      t.string :created_by
      t.string :updated_by

      t.timestamps
    end
  end
end

# frozen_string_literal: true

class AddReceptMailsToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :recept_mails, :boolean, default: false, null: false
  end
end

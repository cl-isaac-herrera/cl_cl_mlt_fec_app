# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_19_140000) do
  create_table "companies", force: :cascade do |t|
    t.boolean "auto_send_ap_inv", default: false, null: false
    t.datetime "cert_expires_at"
    t.string "cert_path"
    t.string "cert_pin"
    t.string "client_id"
    t.integer "connection_id"
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "default_warehouse", limit: 8
    t.string "default_xml_tax_code", limit: 8
    t.string "economic_activity_code", limit: 6
    t.text "email_cc"
    t.integer "email_sender_type", default: 1, null: false
    t.integer "environment_id"
    t.integer "freight_type", default: 1, null: false
    t.string "grant_type"
    t.boolean "is_active", default: true, null: false
    t.string "issuer_id_number", limit: 12
    t.string "issuer_id_type", limit: 2
    t.string "issuer_legal_name", limit: 100
    t.string "logo_path"
    t.string "name", null: false
    t.string "print_format_path"
    t.integer "purchase_invoice_series"
    t.string "sap_db"
    t.string "tax_registry_8707", limit: 12
    t.string "token_password"
    t.string "token_user"
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.boolean "use_ap_invoice", default: false, null: false
    t.string "uuid"
    t.index ["environment_id"], name: "index_companies_on_environment_id"
    t.index ["uuid"], name: "index_companies_on_uuid", unique: true
  end

  create_table "connections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
    t.string "sl_type"
    t.string "sl_url", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
  end

  create_table "environments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.boolean "is_prod", default: false, null: false
    t.date "resolution_date"
    t.string "resolution_number"
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.string "uri_check"
    t.string "uri_send"
    t.string "uri_token"
  end

  create_table "permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "description"
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
    t.string "type", default: "normal", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
  end

  create_table "role_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.integer "permission_id", null: false
    t.integer "role_id", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.index ["permission_id"], name: "index_role_permissions_on_permission_id"
    t.index ["role_id"], name: "index_role_permissions_on_role_id"
  end

  create_table "roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
  end

  create_table "sl_resources", force: :cascade do |t|
    t.string "code", limit: 100, null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "description"
    t.boolean "is_active", default: true, null: false
    t.boolean "is_standard", default: false, null: false
    t.integer "page_size"
    t.text "query_params"
    t.text "resource", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.index ["code"], name: "index_sl_resources_on_code", unique: true
  end

  create_table "user_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.integer "permission_id", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.integer "user_id", null: false
    t.index ["permission_id"], name: "index_user_permissions_on_permission_id"
    t.index ["user_id", "permission_id"], name: "index_user_permissions_on_user_id_and_permission_id", unique: true
    t.index ["user_id"], name: "index_user_permissions_on_user_id"
  end

  create_table "user_roles", force: :cascade do |t|
    t.integer "company_id", null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.integer "role_id", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.integer "user_id", null: false
    t.index ["company_id"], name: "index_user_roles_on_company_id"
    t.index ["role_id"], name: "index_user_roles_on_role_id"
    t.index ["user_id"], name: "index_user_roles_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "doc_number_preference"
    t.string "email", null: false
    t.boolean "is_active", default: true, null: false
    t.string "name"
    t.string "oidc_sub"
    t.string "sap_password"
    t.string "sap_user"
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["oidc_sub"], name: "index_users_on_oidc_sub", unique: true
  end

  create_table "users_by_companies", force: :cascade do |t|
    t.integer "company_id", null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.integer "user_id", null: false
    t.index ["company_id"], name: "index_users_by_companies_on_company_id"
    t.index ["user_id", "company_id"], name: "index_users_by_companies_on_user_id_and_company_id", unique: true
    t.index ["user_id"], name: "index_users_by_companies_on_user_id"
  end

  add_foreign_key "companies", "connections"
  add_foreign_key "companies", "environments"
  add_foreign_key "role_permissions", "permissions"
  add_foreign_key "role_permissions", "roles"
  add_foreign_key "user_permissions", "permissions"
  add_foreign_key "user_permissions", "users"
  add_foreign_key "user_roles", "companies"
  add_foreign_key "user_roles", "roles"
  add_foreign_key "user_roles", "users"
  add_foreign_key "users_by_companies", "companies"
  add_foreign_key "users_by_companies", "users"
end

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

ActiveRecord::Schema[8.1].define(version: 2026_08_07_160000) do
  create_table "companies", force: :cascade do |t|
    t.integer "connection_id"
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
    t.string "sap_db_code"
    t.datetime "updated_at", null: false
    t.string "updated_by"
    t.string "uuid"
    t.index ["uuid"], name: "index_companies_on_uuid", unique: true
  end

  create_table "connections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
    t.string "service_layer_type"
    t.string "service_layer_url", null: false
    t.datetime "updated_at", null: false
    t.string "updated_by"
  end

  create_table "permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "description"
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
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
  add_foreign_key "role_permissions", "permissions"
  add_foreign_key "role_permissions", "roles"
  add_foreign_key "user_roles", "companies"
  add_foreign_key "user_roles", "roles"
  add_foreign_key "user_roles", "users"
  add_foreign_key "users_by_companies", "companies"
  add_foreign_key "users_by_companies", "users"
end

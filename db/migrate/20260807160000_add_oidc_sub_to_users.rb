# frozen_string_literal: true

# Identificador del usuario en el proveedor OIDC (claim `sub`, ej. "auth0|68f2...").
#
# Es la columna que Clavisco::Auth::Authenticatable busca por defecto
# (`User.find_by(oidc_sub: claims["sub"])`). A diferencia del correo, el `sub` no
# cambia si el usuario cambia de email en el proveedor.
class AddOidcSubToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :oidc_sub, :string
    add_index  :users, :oidc_sub, unique: true
  end
end

# frozen_string_literal: true

# Da de baja `S_AcceptDocsGT` en una base viva (CLAUDE.md §28 — un cambio de
# catálogo en una base con datos reales es una migración, no un re-seed).
#
# Gateaba "Aceptación documentos GT" (app/javascript/data/menu.js), una
# personalización hecha para un cliente puntual — no la vista de recepciones
# original (`/configurations/receptions` / `S_ReceptDocs`), que se conserva sin
# cambios. Se eliminó el nodo de menú y la rama de retorno que dependía de ella
# en `documents_reception_create_controller.js`; el permiso ya no lo evalúa
# nadie. Ver `db/permission_name_map.yml` → orphaned.
#
# Baja LÓGICA, no `DELETE` (§2.2 + FK de `role_permissions`/`user_permissions`).
class DeactivateGtReceptionPermission < ActiveRecord::Migration[8.1]
  DEACTIVATE = %w[S_AcceptDocsGT].freeze

  # Clase mínima y local: no depender del modelo de la app (su default_scope
  # escondería justo las filas que se quieren tocar).
  class MigrationPermission < ActiveRecord::Base
    self.table_name = 'permissions'
    self.inheritance_column = nil
  end

  def up
    MigrationPermission.where(name: DEACTIVATE, is_active: true)
                       .update_all(is_active: false, updated_at: Time.current)
  end

  def down
    MigrationPermission.where(name: DEACTIVATE, is_active: false)
                       .update_all(is_active: true, updated_at: Time.current)
  end
end

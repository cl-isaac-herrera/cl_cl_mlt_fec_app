# frozen_string_literal: true

# Renombra `qsGetMailQueueByDocument` → `getMailInformation` en el catálogo de
# `sl_resources`: el nombre que pidió el negocio, y ya sin el prefijo `qs` que
# las consultas nuevas vienen dejando de usar (`getDocuments01`,
# `getMailDocumentInfo01`, …).
#
# ── Por qué es un `UPDATE` en el lugar y no una fila nueva ───────────────────
# A diferencia de un permiso importado de SQL Server (`db/permission_name_map
# .yml`), el `code` de `sl_resources` es una invención de esta misma
# aplicación: no hay una fuente externa con la que reconciliar. Pero SÍ puede
# haber una personalización de `query_params` hecha por instalación desde la
# pantalla de mantenimiento (`Configurations_SlResources_Update`) — insertar
# una fila nueva con el `code` nuevo la abandonaría huérfana bajo el `code`
# viejo. Un `UPDATE` sobre el mismo `id` la conserva.
#
# Modelo propio y mínimo, no `SlResource`: mismo motivo que
# `20260905160000_add_get_documents_sl_resources.rb` — el `default_scope` de
# `SoftDeletable` escondería la fila si estuviera dada de baja.
class RenameMailQueueSlResource < ActiveRecord::Migration[8.1]
  OLD_CODE = 'qsGetMailQueueByDocument'
  NEW_CODE = 'getMailInformation'

  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    MigrationSlResource.where(code: OLD_CODE).update_all(code: NEW_CODE)
  end

  def down
    MigrationSlResource.where(code: NEW_CODE).update_all(code: OLD_CODE)
  end
end

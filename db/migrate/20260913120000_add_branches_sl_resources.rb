# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las cuatro filas de la UDT
# `@CL_FEC_SUCURSALES` (`config/sap_schemas/sucursales_udt.json`): la lista
# paginada, la lectura de una sucursal por su `Code`, el alta y la
# actualización. Las consume `Sap::Branches` desde `Api::BranchesController`.
#
# ── Qué reemplazan ──────────────────────────────────────────────────────────
# La tabla `Sucursal` de la base del .NET y sus tres SP (`spGetSucursalByCompany`,
# `spCreateSucursal`, `spUpdateSucursal`), a los que la pantalla llegaba por el
# proxy (`GET /api/Sucursal/GetSucursalByCompany?companyId=N`). La sucursal pasa
# a vivir donde la emisión ya la leía: la UDT de la compañía
# (`Documents::UnifiedBuilder#emisor` lee de ahí los campos `Emsr*`).
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del mismo
# seed (`CLAUDE.md` §36 y `TODOS.md` → Deploy), así que el catálogo se completa
# acá para que una base migrada quede idéntica a una sembrada de cero.
#
# ⚠️ Esto NO crea la UDT en SAP: eso lo hace `rake sap:schema:sync` con el schema
# declarado (`CLAUDE.md` §32). Sin ese paso las cuatro consultas resuelven un
# entity set que todavía no existe.
class AddBranchesSlResources < ActiveRecord::Migration[8.1]
  ENTITY = 'U_CL_FEC_SUCURSALES'

  # code               description                                    resource                 query_params
  ROWS = [
    ['getBranches',
     'Sucursales del emisor de la compañía (UDT)',
     ENTITY,
     '$orderby=U_SucursalNum asc'],
    ['getBranchByCode',
     'Sucursal del emisor por su Code (UDT)',
     "#{ENTITY}(#Code#)",
     nil],
    ['createBranch',
     'Registra una sucursal del emisor (UDT)',
     ENTITY,
     nil],
    ['updateBranch',
     'Actualiza una sucursal del emisor (UDT)',
     "#{ENTITY}(#Code#)",
     nil]
  ].freeze

  # Modelo propio y mínimo, no `SlResource`: el modelo de la app cambia con el
  # tiempo y su `default_scope` (`SoftDeletable`) escondería justo las filas
  # dadas de baja que haya que reactivar acá.
  class MigrationSlResource < ActiveRecord::Base
    self.table_name = 'sl_resources'
  end

  def up
    ROWS.each do |code, description, resource, query_params|
      record = MigrationSlResource.find_or_initialize_by(code: code)
      record.description  = description
      record.resource     = resource
      record.query_params = query_params
      record.page_size    = 0
      record.is_standard  = true
      record.is_active    = true
      record.save!
    end
  end

  def down
    MigrationSlResource.where(code: ROWS.map(&:first)).delete_all
  end
end

# frozen_string_literal: true

# Agrega al catálogo de `sl_resources` las tres filas de la UDT
# `@CL_FEC_ISSUERCONFIG` (`config/sap_schemas/company_config_udt.json`): la
# lectura de la fila única, el alta y la actualización. Las consume
# `Sap::CompanyConfig` desde la sección "Datos Generales" del formulario de
# compañías (`Api::CompaniesController`, `Api::Companies::GeneralController`).
#
# ── Qué reemplaza ────────────────────────────────────────────────────────────
# Cuatro columnas de `companies` (`issuer_legal_name`, `issuer_id_type`,
# `economic_activity_code`, `tax_registry_8707`) que a su vez habían vuelto de
# SAP en `20260819130000_add_issuer_fields_to_companies.rb`. Revierte esa
# decisión — el motivo está documentado en `CLAUDE.md` §32, caso
# `company_config_udt` (antes `oadm_company_config`).
#
# `companies.name` (nombre comercial) y `companies.issuer_id_number` (cédula)
# NO se mueven: la primera nunca tuvo columna propia en SAP, y la segunda sigue
# siendo componente de ruta en `CompanyFiles::Store` (`CLAUDE.md` §34) — moverla
# habría hecho depender de SAP hasta para guardar un logo.
#
# ── Por qué una migración y no solo `db/seeds.rb` ───────────────────────────
# Correr `db:seed` contra una base viva es destructivo en otras tablas del mismo
# seed (`CLAUDE.md` §36), así que el catálogo se completa acá para que una base
# migrada quede idéntica a una sembrada de cero.
#
# ⚠️ Esto NO crea la UDT en SAP: eso lo hace `rake sap:schema:sync` con el
# schema declarado (`CLAUDE.md` §32). Sin ese paso las tres consultas resuelven
# un entity set que todavía no existe.
class AddCompanyConfigSlResources < ActiveRecord::Migration[8.1]
  ENTITY = 'U_CL_FEC_ISSUERCONFIG'

  # code                  description                                                resource         query_params
  ROWS = [
    ['getCompanyConfig',
     'Configuración del emisor de FE de la compañía (UDT)',
     "#{ENTITY}(1)",
     nil],
    ['createCompanyConfig',
     'Registra la configuración del emisor de FE de la compañía (UDT)',
     ENTITY,
     nil],
    ['updateCompanyConfig',
     'Actualiza la configuración del emisor de FE de la compañía (UDT)',
     "#{ENTITY}(1)",
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

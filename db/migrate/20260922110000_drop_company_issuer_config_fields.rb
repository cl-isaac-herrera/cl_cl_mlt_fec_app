# frozen_string_literal: true

# Da de baja cuatro de los seis campos del bloque del emisor ante Hacienda que
# `20260819130000_add_issuer_fields_to_companies.rb` había traído de vuelta a
# `companies` desde los UDFs de `OADM`: razón social, tipo de identificación,
# actividad económica y registro fiscal 8707. Se mudan a la UDT
# `@CL_FEC_ISSUERCONFIG` (`Sap::CompanyConfig`) — revierte esa decisión otra
# vez, documentado en `docs/PLAN-UDT-CONFIG-EMISOR.md` y en `CLAUDE.md` §32
# (caso `company_config_udt`).
#
# ── Los otros dos NO se tocan ────────────────────────────────────────────────
# `name` (el nombre comercial) nunca tuvo columna en SAP — sigue siendo
# `companies.name`. `issuer_id_number` (la cédula) se QUEDA acá a propósito:
# `CompanyFiles::Store` la necesita para armar la carpeta del certificado/logo/
# formato de impresión en disco sin depender de SAP (`CLAUDE.md` §34), y
# `MailReceptionJob#archive` la usa para decidir a qué compañía pertenece un
# correo entrante (`Company.find_by(issuer_id_number: …)`) — una búsqueda que
# no se puede resolver contra SAP porque hace falta saber la compañía primero
# para tener su conexión. El listado y el filtro de compañías también la
# necesitan local para no volverse N llamadas a SAP por página.
#
# ⚠️ IRREVERSIBLE EN LOS DATOS: el `down` recrea las columnas vacías, no el
# contenido — que para las cinco compañías de esta base de `development` había
# que empujar antes a la UDT de cada una (plan §4, paso 4) y no se hizo: no
# hay conexión real para 4 de las 5 en `config/sap_connections.json`. Correr
# esto en una base con compañías reales sin haber hecho ese backfill deja su
# sección del emisor en blanco hasta que alguien la vuelva a cargar a mano
# desde el formulario.
class DropCompanyIssuerConfigFields < ActiveRecord::Migration[8.1]
  def change
    change_table :companies, bulk: true do |t|
      t.remove :issuer_legal_name,      type: :string, limit: 100
      t.remove :issuer_id_type,         type: :string, limit: 2
      t.remove :economic_activity_code, type: :string, limit: 6
      t.remove :tax_registry_8707,      type: :string, limit: 12
    end
  end
end

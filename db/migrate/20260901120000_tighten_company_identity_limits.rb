# frozen_string_literal: true

# Acota los dos campos de la compañía que ahora viajan en el XML como datos del
# EMISOR, a los largos que Hacienda acepta en la 4.4.
#
#   name             → 80  (era sin límite)  · `Emisor.NombreComercial`
#   issuer_id_number → 20  (era 12)          · `Emisor.Identificacion.Numero`
#
# ── Por qué cambian ahora ────────────────────────────────────────────────────
# Hasta hoy la identidad del emisor se esperaba de la vista de SAP y estas dos
# columnas solo alimentaban pantallas de la aplicación, donde un nombre largo de
# más no rompía nada. Al pasar a armarse desde `companies`
# (`Documents::UnifiedBuilder#emisor`), el largo dejó de ser cosmético: un valor
# que excede el máximo del esquema de Hacienda es un comprobante rechazado, y el
# rechazo llega de vuelta mucho después de que alguien escribió el dato.
#
# `issuer_id_number` sube de 12 a 20 y no baja: el 12 replicaba el `Size` del UDF
# `CL_FEC_EmsrIdeNumero` de `OADM`, que no alcanza para el DIMEX ni para el NITE.
# Ampliar no puede fallar contra los datos que ya existen.
#
# `name` baja a 80. Es el único de los dos que puede dejar afuera un valor ya
# guardado, así que la migración avisa en vez de truncar: recortar el nombre de
# una compañía sin decirlo cambia lo que ve el usuario en el selector y en los
# correos. SQLite además no valida el `limit:`, así que un valor viejo más largo
# sigue leyéndose igual — lo que lo va a atajar es la validación del modelo la
# próxima vez que alguien guarde el formulario.
#
# ── El `limit:` no es la validación ──────────────────────────────────────────
# SQLite ignora el largo de `varchar`. El que corta de verdad es el `validates
# … length` de `Company`; esto queda declarado para el día que la base se mude a
# un motor que sí lo respete, que es el mismo criterio de
# `20260819130000_add_issuer_fields_to_companies.rb`.
class TightenCompanyIdentityLimits < ActiveRecord::Migration[8.1]
  NAME_LIMIT = 80

  def up
    warn_about_long_names

    change_column :companies, :name,             :string, limit: NAME_LIMIT, null: false
    change_column :companies, :issuer_id_number, :string, limit: 20
  end

  def down
    change_column :companies, :name,             :string, null: false
    change_column :companies, :issuer_id_number, :string, limit: 12
  end

  private

  # No se trunca nada: solo se nombra a las compañías que van a empezar a fallar
  # la validación, para que quien corre la migración sepa a quién avisarle.
  def warn_about_long_names
    rows = select_all(<<~SQL.squish).to_a
      SELECT id, name FROM companies WHERE length(name) > #{NAME_LIMIT}
    SQL
    return if rows.empty?

    say("⚠ #{rows.size} compañía(s) con nombre de más de #{NAME_LIMIT} caracteres. " \
        'No se truncan, pero el formulario las va a rechazar hasta que se acorten:')
    rows.each { |row| say("· ##{row['id']} (#{row['name'].length}) #{row['name']}", true) }
  end
end

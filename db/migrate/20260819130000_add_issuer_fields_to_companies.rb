# frozen_string_literal: true

# Trae a la base de la aplicación los diez campos de configuración de FE que
# estaban viviendo en SAP como UDFs sobre `OADM` (`U_CL_FEC_*`).
#
# ── Por qué se revierte la decisión anterior ─────────────────────────────────
# Se habían puesto en SAP para no duplicar información. En la práctica no
# deduplicaban nada: ninguno de los diez es un dato que SAP use por su cuenta
# —son parámetros de la facturación electrónica de Costa Rica, que solo lee este
# producto— así que el UDF no era la misma información en dos lados, era la única
# copia, alojada en el sistema equivocado. A cambio costaba una vuelta al Service
# Layer para pintar un formulario, obligaba a que cada usuario tuviera
# credenciales de SAP para ver la pantalla, y volvía la validación de datos
# imposible de hacer del lado del modelo.
#
# Los UDFs de `OADM` se eliminan aparte, con
# `rake "sap:schema:delete[config/sap_schemas/delete/oadm_company_config.json,…]"`.
# Esta migración NO los toca: es DDL de SAP y va por el submódulo (`CLAUDE.md` §32).
#
# ── Nombres ──────────────────────────────────────────────────────────────────
# En SAP los campos seguían el vocabulario del XML de Hacienda (`EmsrNombre`,
# `CodigoActividad`). Acá siguen la convención de la base: inglés en snake_case,
# igual que el resto de la tabla (`sap_db`, `cert_path`, `token_user`).
#
#   CL_FEC_EmsrNombre         → issuer_legal_name
#   CL_FEC_EmsrIdeTipo        → issuer_id_type
#   CL_FEC_EmsrIdeNumero      → issuer_id_number
#   CL_FEC_CodigoActividad    → economic_activity_code
#   CL_FEC_EmsrRegFiscal8707  → tax_registry_8707
#   CL_FEC_EmailCc            → email_cc
#   CL_FEC_PurchInvSeriesNum  → purchase_invoice_series
#   CL_FEC_DefaultXmlTaxCode  → default_xml_tax_code
#   CL_FEC_DefaultWarehouse   → default_warehouse
#
# `CL_FEC_EmsrNomComercial` NO tiene columna nueva: el nombre comercial es el
# mismo dato que `companies.name`, que ya existía y es el que usa el resto de la
# app (el listado, el selector de compañía). Tener las dos columnas garantizaba
# que tarde o temprano dijeran cosas distintas. El UDF igual se borra de SAP.
#
# Los `limit:` replican el `Size` que tenían los UDFs, que era el límite real con
# el que se venían guardando. SQLite los ignora, pero quedan declarados para el
# día que la base se mude a una que sí los respete.
class AddIssuerFieldsToCompanies < ActiveRecord::Migration[8.1]
  def change
    change_table :companies, bulk: true do |t|
      # Bloque del emisor ante Hacienda.
      t.string :issuer_legal_name,      limit: 100
      # '01' Cédula Física · '02' Cédula Jurídica · '03' DIMEX · '04' NITE.
      # Texto y no entero: los códigos de Hacienda llevan el cero adelante.
      t.string :issuer_id_type,         limit: 2
      t.string :issuer_id_number,       limit: 12
      t.string :economic_activity_code, limit: 6
      t.string :tax_registry_8707,      limit: 12

      # Correos en copia al enviar documentos, separados por `;`. Era `db_Memo`
      # en SAP: sin límite declarado.
      t.text   :email_cc

      # Serie de numeración de SAP para las facturas de compra (`NNM1.Series`).
      t.integer :purchase_invoice_series

      # Valores por defecto de las líneas del XML.
      t.string :default_xml_tax_code,   limit: 8
      t.string :default_warehouse,      limit: 8
    end
  end
end

# frozen_string_literal: true

# Unifica en `companies` la configuración que en el legacy vivía repartida entre
# `dbo.Company` (base del API FE Sync) y `dbo.Companies` (base del API App). El
# split era un artefacto de dos servicios .NET separados que compartían la
# compañía por un FK cruzado entre bases; acá es una sola fila.
#
# De los 42 campos originales, en esta tabla quedan los que la aplicación necesita
# tener disponibles **sin** consultar a SAP: lo que hace falta para conectarse
# (`sap_db`, `connection_id`), los secretos de emisión, y las banderas de
# comportamiento propio. La identidad fiscal del emisor y las referencias a
# objetos de SAP se movieron a UDFs sobre `OADM` — ver
# `config/sap_schemas/oadm_company_config.json` y `CLAUDE.md` §32.
#
# `sap_db_code` se renombra a `sap_db`. Es la misma columna: el nombre cambia por
# decisión del diseño del modelo unificado, no hay migración de datos.
#
# Trece campos NO se migran: los dos ids del split (`Id` de Companies,
# `CompanyFEId`), el estado de proceso que pasa a la cola de trabajos (`Attempts`,
# `Busy`), la bandera que solo elegía entre Service Layer y ODBC cuando existían
# las dos vías (`IsExternal` — hoy todo es Service Layer, `CLAUDE.md` §29), los
# nombres y la identificación duplicados dentro de la propia tabla (`LegalName`,
# `Identification`, `Type` — el formulario escribía un solo input en las dos
# columnas), `ShortName` y `AdditionalInformation` sin ningún consumidor, los
# formatos de nota de crédito y débito que nunca se usaron (los PDF se generan
# siempre con `FEFormatTemp`), y `NumSerieProv`, que no lo lee nadie.
class AddFeConfigurationToCompanies < ActiveRecord::Migration[8.1]
  def change
    rename_column :companies, :sap_db_code, :sap_db

    # Ambiente de Hacienda (pruebas/producción) contra el que emite la compañía.
    add_reference :companies, :environment, foreign_key: true

    # Banderas de comportamiento de la aplicación, no datos de SAP.
    add_column :companies, :use_ap_invoice,   :boolean, null: false, default: false
    add_column :companies, :auto_send_ap_inv, :boolean, null: false, default: false

    # Modo de armado de los cargos del XML: 1 = líneas de la factura
    # (`APInvoiceLines`), 2 = gastos adicionales del documento
    # (`DocumentAdditionalExpenses`). El default replica el del legacy, que en el
    # front resuelve `data.FreightCharges ?? 1`.
    add_column :companies, :freight_type, :integer, null: false, default: 1

    # Qué nombre usar como remitente del correo (`NameToEmail` del legacy).
    add_column :companies, :email_sender_type, :integer, null: false, default: 0

    # Certificado de firma digital y credenciales del ATV de Hacienda.
    #
    # `cert_pin` y `token_password` van cifradas con ActiveRecord Encryption desde
    # el modelo. Sin `limit:` a propósito: lo guardado es un sobre JSON, no el
    # texto original, así que dimensionar contra el dato sería un error
    # (`CLAUDE.md` §29).
    add_column :companies, :cert_path,       :string
    add_column :companies, :cert_pin,        :string
    add_column :companies, :token_user,      :string
    add_column :companies, :token_password,  :string
    add_column :companies, :client_id,       :string
    add_column :companies, :grant_type,      :string
    add_column :companies, :cert_expires_at, :datetime

    # Rutas en disco, no adjuntos: el legacy copia el formato de impresión a un
    # temporal para renderizarlo (`CLVS_FE.DAO/GetData/GetData.cs:2160`). Requiere
    # que el directorio esté montado en cada servidor donde corra la app o el
    # worker, y que el alta de una compañía deje los archivos en su lugar.
    add_column :companies, :print_format_path, :string
    add_column :companies, :logo_path,         :string
  end
end

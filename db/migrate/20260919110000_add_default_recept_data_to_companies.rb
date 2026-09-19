# frozen_string_literal: true

# Valores por defecto de mensaje receptor para esta compañía, para cuando un
# correo de recepción NO trae alguno de los tags `[Tag:valor]` en el cuerpo
# (`MailReception::EmailBodyTags`). Reemplaza `DefaultReceptData.json` del
# conector legacy (`legacy/reception/clvsfemailsconector`, `DefaultReceptData.cs`
# + `EmailBodyTagsService.LoadDefaultsTagsValuesForCompany`), un archivo aparte
# en el disco del ejecutable indexado por `IdCompania` — acá es una fila más de
# `companies`, sin archivo ni id externo que sincronizar.
#
# Orden de resolución de cada campo (`MailReception::EmailBodyTags#resolve`):
# tag del cuerpo del correo → default de esta compañía → vacío/0 (lo que
# admita la UDT, `config/sap_schemas/reception_messages_udt.json`).
class AddDefaultReceptDataToCompanies < ActiveRecord::Migration[8.1]
  def change
    # Catálogo de 1 dígito de `MessageType` (`app/models/message_type.rb`):
    # 1 Aceptado, 2 Aceptar Parcialmente, 3 Rechazado — el mismo que
    # `MessageConverter`/`MessageConverterFromId` del legacy
    # (`InvoiceHandler.cs:104-141`) y que ya vive en el frontend
    # (`documents_reception_controller.js` `MESSAGE_TYPE`). NO es el código de
    # Hacienda de 2 dígitos (`DocType::AT/AP/RC`, `"05"/"06"/"07"`) — ese se
    # deriva de este con `MessageType.to_doc_type`.
    add_column :companies, :default_recept_message, :integer

    # Detalle/motivo por defecto del mensaje receptor (`DetalleMensaje`). Mismo
    # `Size` que la UDT (`reception_messages_udt.json` → `DetalleMensaje` es
    # `db_Memo` sin tope, pero el legacy siempre usó un texto corto de una
    # línea para esto — 160 replica el límite ya usado en otros campos de
    # texto libre de esta tabla, ver `email_sender_name`/`issuer_legal_name`).
    add_column :companies, :default_recept_details, :string, limit: 160

    # Factor de impuesto por defecto (`TaxFactor`), solo relevante si
    # `default_recept_tax_condition` es `03`/`05` (`TaxCondition::REQUIRES_TAX_FACTOR`).
    add_column :companies, :default_recept_tax_factor, :float

    # Condición del impuesto por defecto (`CondicionImpuesto`, catálogo
    # `"01".."05"` de `app/models/tax_condition.rb`). Texto y no entero, mismo
    # criterio que `Company::ISSUER_ID_TYPES`: el código lleva cero adelante.
    add_column :companies, :default_recept_tax_condition, :string, limit: 2
  end
end

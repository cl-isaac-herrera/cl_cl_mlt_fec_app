# frozen_string_literal: true

# ¿La compañía quiere el correo de recepción electrónica también para los
# comprobantes que Hacienda RECHAZA?
#
# `false` por defecto a propósito: es el comportamiento más conservador —avisar
# solo de lo aceptado— y una migración no debe empezar a mandarle correos de
# rechazo a un receptor sin que el cliente lo haya pedido. Quien lo necesite lo
# enciende.
#
# Lo consume `Sap::MailDocumentInfo` (`SendElectronicReceiptJob`): en `false`
# le suma `U_CL_FEC_Status eq 6` al `$filter` de `getMailDocumentInfo<DocType>`,
# así que un documento Rechazado no trae información y el job lo marca
# `Omitido` en vez de enviar el correo.
#
# `null: false` por el mismo motivo que `use_additional_fields`
# (`20260825140100`): el consumidor lo evalúa como condición y un `nil` ahí
# sería un tercer estado que no significa nada.
class AddSendRejectedDocumentsToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :send_rejected_documents, :boolean, default: false, null: false
  end
end

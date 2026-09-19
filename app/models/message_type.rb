# frozen_string_literal: true

# Catálogo de 1 dígito de la decisión del receptor sobre un documento
# recibido de un proveedor: 1 Aceptado, 2 Aceptar Parcialmente, 3 Rechazado.
#
# Es el `MessageConverter`/`MessageConverterFromId` del mail parser legacy
# (`legacy/reception/clvsfemailsconector/FEProcesadorCorreoLib/Classes/
# InvoiceHandler.cs:104-141`), que hoy solo vive portado en el frontend
# (`app/javascript/controllers/documents_reception_controller.js` →
# `MESSAGE_TYPE`). Este módulo es la versión Ruby, para que
# `companies.default_recept_message` y `MailReception::EmailBodyTags` no
# tengan que repetir el catálogo por tercera vez.
#
# ⚠️ NO es el código de Hacienda de 2 dígitos que el XML de mensaje receptor
# realmente envía (`DocType::AT/AP/RC`, `"05"/"06"/"07"`) — `to_doc_type`
# traduce de este dígito a ese código.
module MessageType
  ACCEPTED            = 1
  PARTIALLY_ACCEPTED  = 2
  REJECTED            = 3

  LABELS = {
    ACCEPTED           => 'Aceptado',
    PARTIALLY_ACCEPTED => 'Aceptar Parcialmente',
    REJECTED           => 'Rechazado'
  }.freeze

  ALL = LABELS.keys.freeze

  # El tag `[Status:...]` del cuerpo del correo trae uno de estos 6 valores,
  # no el dígito directamente (`EmailBodyTagsService.cs:43`, `_validStates`).
  FROM_BODY_TAG = {
    'ACEPTADO'  => ACCEPTED,
    'ACEPTADA'  => ACCEPTED,
    'PACEPTADO' => PARTIALLY_ACCEPTED,
    'PACEPTADA' => PARTIALLY_ACCEPTED,
    'RECHAZADO' => REJECTED,
    'RECHAZADA' => REJECTED
  }.freeze

  TO_DOC_TYPE = {
    ACCEPTED           => DocType::AT,
    PARTIALLY_ACCEPTED => DocType::AP,
    REJECTED           => DocType::RC
  }.freeze

  module_function

  def valid?(value)
    ALL.include?(value)
  end

  def label(value)
    LABELS.fetch(value, value.to_s)
  end

  # @param tag_value [String, nil] el valor crudo del tag `[Status:...]`.
  # @return [Integer, nil] el dígito 1/2/3, o `nil` si no matchea ninguno de
  #   los 6 valores válidos (un tag ausente o mal escrito).
  def from_body_tag(tag_value)
    FROM_BODY_TAG[tag_value.to_s.strip.upcase]
  end

  # @param value [Integer] 1, 2 o 3.
  # @return [String] el código Hacienda de 2 dígitos (`"05"/"06"/"07"`).
  def to_doc_type(value)
    TO_DOC_TYPE.fetch(value)
  end
end

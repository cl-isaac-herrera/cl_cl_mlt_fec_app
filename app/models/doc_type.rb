# frozen_string_literal: true

# Códigos de tipo de comprobante electrónico de Hacienda (Costa Rica).
#
# Es el `DocTypesString` del .NET, traído como módulo para que exista UN solo
# lugar en la aplicación donde estos códigos están escritos. Los consume el
# armado del documento unificado, la elección del XML a generar y el filtro de
# las pantallas de documentos.
#
# Strings y no enteros: los códigos llevan el cero adelante y `'01'.to_i` lo
# perdería — el mismo motivo por el que `Company::ISSUER_ID_TYPES` es texto.
#
# ── ⚠️ Discrepancia del fuente original, resuelta a favor de Hacienda ────────
# El `DocTypesString` del .NET trae los comentarios de `02` y `03` cruzados
# respecto del nombre de la constante:
#
#     public const string ND = "02"; // Nota de Crédito   ← el comentario miente
#     public const string NC = "03"; // Nota de Débito    ← el comentario miente
#
# La resolución DGT-R-48-2016 y el Anexo 4.4 fijan `02` = nota de **débito** y
# `03` = nota de **crédito**, que es lo que dicen los nombres `ND`/`NC`. Se
# conservan los nombres y se corrigen las etiquetas: cruzarlas acá haría que un
# documento se envíe a Hacienda como el comprobante equivocado, que es un error
# tributario, no un detalle de presentación.
module DocType
  FE  = '01' # Factura electrónica
  ND  = '02' # Nota de débito electrónica
  NC  = '03' # Nota de crédito electrónica
  TE  = '04' # Tiquete electrónico
  AT  = '05' # Mensaje receptor — aceptación total
  AP  = '06' # Mensaje receptor — aceptación parcial
  RC  = '07' # Mensaje receptor — rechazo
  FEC = '08' # Factura electrónica de compra
  FEE = '09' # Factura electrónica de exportación
  REP = '10' # Recibo electrónico de pago

  # Etiqueta visible de cada código. Es también la lista de códigos válidos: lo
  # que no esté acá no es un tipo de comprobante que este producto conozca.
  LABELS = {
    FE  => 'Factura electrónica',
    ND  => 'Nota de débito electrónica',
    NC  => 'Nota de crédito electrónica',
    TE  => 'Tiquete electrónico',
    AT  => 'Aceptación total',
    AP  => 'Aceptación parcial',
    RC  => 'Rechazo',
    FEC => 'Factura electrónica de compra',
    FEE => 'Factura electrónica de exportación',
    REP => 'Recibo electrónico de pago'
  }.freeze

  ALL = LABELS.keys.freeze

  # Los tres mensajes de receptor (`05`, `06`, `07`) no son comprobantes: no
  # llevan detalle de líneas ni resumen de factura, y su XML es otro. Se agrupan
  # para que el armado del documento no tenga que enumerarlos a mano.
  RECEIVER_MESSAGES = [AT, AP, RC].freeze

  module_function

  # Normaliza lo que venga de SAP o de la cola: el procedimiento almacenado
  # devuelve `DocType` como `nvarchar(2)`, y un `1` sin el cero adelante o con
  # espacios alrededor es el error de dato más común.
  #
  # @return [String, nil] el código canónico, o nil si no es uno conocido.
  def normalize(value)
    return nil if value.nil?

    code = value.to_s.strip
    return nil if code.empty?

    code = code.rjust(2, '0')
    ALL.include?(code) ? code : nil
  end

  def valid?(value)
    !normalize(value).nil?
  end

  # Etiqueta para mostrar. Devuelve el código crudo cuando no lo conoce, en vez
  # de una cadena vacía: un código desconocido en pantalla es información, y
  # esconderlo obliga a ir al log para saber qué llegó.
  def label(value)
    LABELS.fetch(normalize(value), value.to_s)
  end

  # ¿Es un mensaje de receptor y no un comprobante?
  def receiver_message?(value)
    RECEIVER_MESSAGES.include?(normalize(value))
  end
end

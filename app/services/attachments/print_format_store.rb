# frozen_string_literal: true

module Attachments
  # El formato de impresión (`.rpt` de Crystal Reports) con el que se genera el
  # PDF de los documentos de la compañía, en el disco del servidor:
  # `{FILES_BASE_PATH}/{cédula}/{archivo.rpt}`.
  #
  # Toda la mecánica está en `CompanyFiles::Store`; acá quedan nada más las
  # cuatro cosas que distinguen a este archivo.
  #
  # En disco y no en Active Storage por lo mismo que el certificado: el generador
  # del PDF abre el reporte **por su ruta** (`CreatePdf(DocId, FEPrintFormat)`) y
  # antes lo copia a una carpeta temporal al lado del original.
  #
  # ⚠️ El servicio de emisión **levanta** si la columna está vacía ("No se ha
  # configurado un formato de impresion para FE"), así que vaciarla deja a la
  # compañía sin poder emitir. Es la razón por la que el botón "Restablecer
  # formato" no se limpia con un borrado: tiene que dejar una ruta válida
  # apuntando al formato por defecto de la aplicación (`TODOS.md` → Compañías).
  class PrintFormatStore < CompanyFiles::Store
    ALLOWED_EXTENSIONS = %w[.rpt].freeze
    PATH_COLUMN        = :print_format_path
    NOUN               = 'formato de impresión'

    # Un `.rpt` con subreportes y logos embebidos llega a algunos MB. El tope es
    # más alto que el del logo por eso, no porque se espere que sea grande.
    MAX_BYTES = 10.megabytes
  end
end

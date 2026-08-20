# frozen_string_literal: true

module Certificates
  # El certificado digital (`.p12` / `.pfx`) de una compañía, en el disco del
  # servidor: `{FILES_BASE_PATH}/{cédula}/{archivo.p12}`.
  #
  # Toda la mecánica —armar la carpeta con la cédula, limpiar el nombre que vino
  # del cliente, sobrescribir, borrar solo dentro de la raíz configurada— vive en
  # `CompanyFiles::Store`, que comparte con el logo y el formato de impresión.
  # Acá quedan nada más las cuatro cosas que distinguen a este archivo. El
  # porqué de guardarlo en disco y no en Active Storage está en la clase base:
  # el servicio de firma lo abre por su ruta.
  class Store < CompanyFiles::Store
    ALLOWED_EXTENSIONS = %w[.p12 .pfx].freeze
    PATH_COLUMN        = :cert_path
    NOUN               = 'certificado'

    # Un PKCS#12 real pesa unos pocos KB. Es el mismo tope que
    # `Certificates::ExpirationReader::MAX_BYTES`, que además corre antes: acá
    # queda por si algún día se guarda un certificado sin haberlo leído primero.
    MAX_BYTES = 1.megabyte
  end
end

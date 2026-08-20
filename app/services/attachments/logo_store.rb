# frozen_string_literal: true

module Attachments
  # El logo de la compañía, en el disco del servidor:
  # `{FILES_BASE_PATH}/{cédula}/{archivo}`.
  #
  # Toda la mecánica está en `CompanyFiles::Store`; acá quedan nada más las
  # cuatro cosas que distinguen a este archivo.
  #
  # En disco y no en Active Storage por lo mismo que el certificado: el servicio
  # de correo lo adjunta **por su ruta** (`new Attachment(companyLogoPath)`) para
  # incrustarlo en el cuerpo del mensaje, así que `companies.logo_path` tiene que
  # ser una ruta que ese proceso pueda abrir.
  class LogoStore < CompanyFiles::Store
    # Las tres que acepta el `<input type="file">` de la pantalla. No se agrega
    # `.svg` ni `.webp`: el logo se incrusta en el cuerpo de un correo y ninguno
    # de los dos se ve en todos los clientes de mail.
    ALLOWED_EXTENSIONS = %w[.jpg .jpeg .png].freeze
    PATH_COLUMN        = :logo_path
    NOUN               = 'logo'

    # El archivo queda siempre como `logo.{extensión}`, sin importar cómo lo haya
    # llamado quien lo subió: `Logo Corporativo v3 (final).PNG` termina en
    # `logo.png`. Es lo que hace que la carpeta de la compañía tenga un solo logo
    # con un nombre predecible en vez de uno distinto por cada carga.
    #
    # Cambiar de extensión SÍ cambia la ruta (`logo.png` → `logo.jpg`), y de eso
    # se ocupa el controller: borra la anterior recién cuando la nueva ya está en
    # disco y la fila apunta a ella.
    FIXED_BASENAME = 'logo'

    # Va incrustado en cada correo que sale, así que el tope es chico a
    # propósito: un logo de más de 2 MB no mejora el mensaje, lo engorda.
    MAX_BYTES = 2.megabytes
  end
end

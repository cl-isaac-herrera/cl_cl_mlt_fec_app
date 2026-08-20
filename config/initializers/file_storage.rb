# frozen_string_literal: true

# ---------------------------------------------------------------
# Raíz de los archivos que la aplicación guarda en disco
# Configurar en .env (ver .env.example)
# ---------------------------------------------------------------
#
# De acá cuelgan los tres archivos de cada compañía, en
# `{FILES_BASE_PATH}/{cédula}/` (ver `CompanyFiles::Store` y `CLAUDE.md` §34):
# el certificado digital, el logo y el formato de impresión.
#
# **Es una ruta local, no un bucket, y eso es a propósito:** ninguno de los tres
# lo lee solo esta aplicación. El servicio de firma abre el `.p12` por su ruta
# (`new X509Certificate2(CertPath, CertPin)`) para firmar los XML, el de correo
# adjunta el logo (`new Attachment(companyLogoPath)`) y el generador del PDF abre
# el `.rpt`. Mientras esos servicios sigan siendo procesos aparte, lo que se
# guarda en `companies.{cert,logo,print_format}_path` tiene que ser una ruta que
# ellos puedan abrir; un blob de Active Storage con nombre de hash no les sirve.
#
# El valor de producción termina en la carpeta del ambiente, por ejemplo:
#   FILES_BASE_PATH='C:\inetpub\wwwroot\CL\Clavisco\Multicompania\fe\test\files'
#
# ⚠️ En el `.env` va **entre comillas simples**: dotenv trata la barra invertida
# como escape en un valor sin comillas, así que `C:\inetpub\...` se guarda como
# `C:inetpub...` — una ruta relativa que se crea sola, sin error, en un lugar
# donde nadie va a buscar los certificados.
#
# El default es para desarrollo y CI: `storage/files` dentro del proyecto, que ya
# está ignorado por git.
Rails.application.config.files_base_path =
  ENV.fetch('FILES_BASE_PATH', Rails.root.join('storage/files').to_s)

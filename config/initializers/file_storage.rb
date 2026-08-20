# frozen_string_literal: true

# ---------------------------------------------------------------
# Raíz de los archivos que la aplicación guarda en disco
# Configurar en .env (ver .env.example)
# ---------------------------------------------------------------
#
# Hoy la usa el certificado digital de cada compañía, que se guarda en
# `{FILES_BASE_PATH}/{cédula}/{archivo.p12}` (ver `Certificates::Store`). El
# logo y el formato de impresión van a colgar de la misma raíz cuando se migre
# la sección "Adjuntos".
#
# **Es una ruta local, no un bucket, y eso es a propósito:** el `.p12` no lo lee
# solo esta aplicación — el servicio de firma abre el archivo por su ruta
# (`new X509Certificate2(CertPath, CertPin)`) para firmar los XML. Mientras ese
# servicio siga siendo un proceso aparte, lo que se guarda en `companies.cert_path`
# tiene que ser una ruta que él pueda abrir; un blob de Active Storage con nombre
# de hash no le sirve.
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

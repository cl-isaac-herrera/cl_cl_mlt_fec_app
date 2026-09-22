# frozen_string_literal: true

# Carga el proveedor "legacy" de OpenSSL 3.x, sin el cual `OpenSSL::PKCS12` NO
# puede abrir un `.p12`/`.pfx` cifrado con los algoritmos que usaban las
# herramientas anteriores a OpenSSL 3.0 — típicamente `RC2-40-CBC` para el
# certificado y 3DES para la llave privada. Son justo los que trae en la
# práctica más de un certificado digital ya emitido (reproducido en
# desarrollo con un certificado ATV real de Hacienda): sin este proveedor,
# `OpenSSL::PKCS12.new` lo rechaza con
# `PKCS12_parse: unsupported (... Algorithm (RC2-40-CBC : 0) ...)`.
#
# Ese error es indistinguible de un PIN equivocado para quien lo mira desde
# afuera: `Certificates::ExpirationReader`, `Hacienda::XmlSigner` y
# `Hacienda::CompanySigner` rescatan `OpenSSL::OpenSSLError` en general (no
# hay forma de separar "MAC inválido" de "algoritmo no soportado" — ver el
# comentario de `ExpirationReader`) y responden siempre "Verifique que el PIN
# sea el correcto…", aunque el PIN esté perfecto. Confirmado en desarrollo:
# el mismo certificado y el mismo PIN abren sin problema en el ambiente de
# pruebas de Hacienda (.NET) y fallan acá, porque .NET usa el stack de
# criptografía de Windows (CryptoAPI/CNG), que sigue soportando esos
# algoritmos sin configuración adicional.
#
# Sin `rescue`: en desarrollo, que el boot falle si el proveedor no existe en
# esta instalación de OpenSSL es preferible a que la firma de documentos
# falle en silencio la primera vez que alguien suba un certificado viejo.
OpenSSL::Provider.load('legacy')

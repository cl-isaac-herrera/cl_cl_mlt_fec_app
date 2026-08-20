# frozen_string_literal: true

module Certificates
  # Falla que el usuario PUEDE corregir desde el formulario: el PIN no abre el
  # archivo, la compañía todavía no tiene cédula, la extensión no sirve.
  #
  # Existe para que el controller distinga estos casos de un error de programa y
  # los responda 422 con el motivo, en vez de dejarlos llegar como 500.
  #
  # Hereda de `CompanyFiles::Error`, que es lo mismo para los tres archivos de la
  # compañía: así el controller de la sección puede rescatar la de arriba y
  # cubrir tanto lo que levanta el `Store` como lo que agrega el certificado (el
  # PIN que no abre el `.p12`).
  Error = Class.new(CompanyFiles::Error)
end

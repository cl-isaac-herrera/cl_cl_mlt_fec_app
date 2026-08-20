# frozen_string_literal: true

module Certificates
  # Falla que el usuario PUEDE corregir desde el formulario: el PIN no abre el
  # archivo, la compañía todavía no tiene cédula, la extensión no sirve.
  #
  # Existe para que el controller distinga estos casos de un error de programa y
  # los responda 422 con el motivo, en vez de dejarlos llegar como 500.
  Error = Class.new(StandardError)
end

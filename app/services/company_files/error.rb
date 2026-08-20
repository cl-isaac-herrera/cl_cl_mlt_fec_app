# frozen_string_literal: true

module CompanyFiles
  # Falla que el usuario PUEDE corregir desde el formulario: la extensión no
  # sirve, el archivo pesa demasiado, la compañía todavía no tiene cédula, el
  # disco no acepta la escritura.
  #
  # Existe para que el controller distinga estos casos de un error de programa y
  # los responda 422 con el motivo, en vez de dejarlos llegar como 500.
  #
  # `Certificates::Error` hereda de esta: el certificado agrega sus propios
  # motivos (el PIN que no abre el `.p12`) pero son de la misma naturaleza, así
  # que un `rescue CompanyFiles::Error` los cubre todos.
  Error = Class.new(StandardError)
end

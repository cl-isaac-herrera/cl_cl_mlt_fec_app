# frozen_string_literal: true

module ExternalDb
  # La base rechazó la consulta: error de sintaxis, objeto que no existe, tipo
  # incompatible, permisos insuficientes sobre la tabla. También cubre lo que el
  # dialecto rechaza antes de mandar (un `SELECT` paginado sin `ORDER BY` en SQL
  # Server) y un nombre de procedimiento que no es un identificador válido.
  QueryError = Class.new(Error)
end

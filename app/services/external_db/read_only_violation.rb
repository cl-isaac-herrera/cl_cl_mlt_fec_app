# frozen_string_literal: true

module ExternalDb
  # Se intentó ejecutar algo que no es una lectura. Ver `StatementGuard` para el
  # alcance real de esta verificación —y para por qué la garantía de verdad son
  # los permisos del usuario de base de datos, no este chequeo.
  #
  # Es un error de programación, no del operador: significa que alguien escribió
  # un `UPDATE` donde va un `SELECT`, o que quiso invocar un procedimiento con
  # `#select` en lugar de `#call`. Su mensaje va al log; al usuario se le muestra
  # un error genérico.
  ReadOnlyViolation = Class.new(Error)
end

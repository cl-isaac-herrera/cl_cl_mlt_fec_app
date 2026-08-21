# frozen_string_literal: true

# Ajuste de la instalación, con el valor cifrado en la base.
#
# El catálogo lo declara `db/seeds.rb`: `code`, `group_code`, `description` e
# `is_visible` son metadatos del producto y NO se editan desde la interfaz. Lo
# único que la pantalla escribe es `value`, por `#update_value!`.
#
# Convención del `code` — `{DOMINIO}_{SUBDOMINIO}_{CAMPO}` en SCREAMING_SNAKE:
#
#   DOCS_DB_ODBC_SERVER      dominio DOCS, subdominio DB_ODBC, campo SERVER
#   DOCS_DB_ODBC_PASSWORD
#   CRYSTAL_USER             dominio CRYSTAL, campo USER
#
# El prefijo es lo que agrupa los ajustes en la pantalla, y `group_code` lo
# guarda explícito (ver el encabezado de la migración: derivarlo del `code` se
# rompe con los campos de dos palabras). Los `code` heredados del .NET venían en
# PascalCase (`CedulaProveedorSistemas`); su equivalencia con los nombres nuevos
# está en `db/setting_code_map.yml`.
class Setting < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Cifrado REVERSIBLE, no un digest: el valor hay que devolverlo en claro para
  # armar la cadena de conexión ODBC. Ver CLAUDE.md §29 — el cifrado es no
  # determinista, así que no se puede buscar ni indexar por esta columna.
  encrypts :value

  # Largo máximo del valor EN CLARO. Se valida acá y no con un `limit:` en la
  # columna porque lo que la base guarda es el sobre del cifrado, que es más
  # grande (CLAUDE.md §29 regla 4).
  MAX_VALUE_LENGTH = 500

  # `{DOMINIO}_{CAMPO}` como mínimo: al menos un `_`, solo mayúsculas, dígitos y
  # guiones bajos, y sin arrancar con dígito ni terminar en `_`. Es lo que hace
  # que el `code` nuevo no pueda nacer en PascalCase como los del origen.
  CODE_FORMAT = /\A[A-Z][A-Z0-9]*(_[A-Z0-9]+)+\z/

  validates :code, presence: true, length: { maximum: 100 }
  validates :code, format: { with: CODE_FORMAT, message: :invalid_format }, if: :code?
  # `conditions:` con `unscope` es obligatorio: `SoftDeletable` instala
  # `default_scope { where(is_active: true) }`, así que sin esto la validación no
  # ve a las filas dadas de baja y el choque lo termina reportando el índice
  # único de la base como un 500 (CLAUDE.md §28).
  validates :code, uniqueness: { case_sensitive: false,
                                 conditions: -> { unscope(where: :is_active) } }, if: :code?
  validates :group_code, presence: true, length: { maximum: 100 }
  validates :description, presence: true, length: { maximum: 250 }
  # `allow_nil`: un ajuste sembrado y todavía sin configurar es un estado válido.
  validates :value, length: { maximum: MAX_VALUE_LENGTH }, allow_nil: true

  scope :in_group, ->(group_code) { where(group_code: group_code) }

  # Valor de un ajuste, o `nil` si no existe o está sin configurar.
  #
  # Sin caché a propósito: son secretos, y guardarlos en `Rails.cache` los
  # sacaría de la columna cifrada para dejarlos en claro en el store de caché
  # (que en esta app es la base, y en otra instalación podría ser Redis o un
  # archivo). El costo es un SELECT por lectura sobre un índice único.
  def self.value_for(code)
    find_by(code: code)&.value.presence
  end

  # Todos los valores de un grupo, con el campo como llave y SIN el prefijo del
  # grupo: `DOCS_DB_ODBC_SERVER` → `'SERVER'`.
  #
  # Recorta por el largo del `group_code` en vez de partir por `_`, porque el
  # campo puede tener más de una palabra (`QUERY_TIMEOUT`).
  #
  # Devuelve solo las claves con valor: así el consumidor distingue "no
  # configurado" de "configurado en blanco" con un `fetch`, y el mensaje de
  # error puede nombrar exactamente el ajuste que falta.
  def self.group(group_code)
    prefix = "#{group_code}_"

    in_group(group_code).each_with_object({}) do |setting, acc|
      next if setting.value.blank?
      next unless setting.code.start_with?(prefix)

      acc[setting.code.delete_prefix(prefix)] = setting.value
    end
  end

  # Único camino de escritura desde la interfaz. `Auditable` llena `updated_at` y
  # `updated_by`; los metadatos del catálogo no se tocan.
  def update_value!(new_value)
    update!(value: new_value.presence)
  end

  # ¿Hay un valor guardado? Es lo que la pantalla necesita saber de un ajuste
  # oculto: sin esto, un campo de contraseña vacío es indistinguible de uno sin
  # configurar, y el operador no sabe si tiene que volver a escribirla.
  def value?
    value.present?
  end

  # Valor tal como puede salir del servidor. Un ajuste oculto devuelve `nil`
  # SIEMPRE, tanto en la respuesta del listado como en la del detalle: el valor
  # se escribe, no se lee.
  def visible_value
    is_visible ? value : nil
  end
end

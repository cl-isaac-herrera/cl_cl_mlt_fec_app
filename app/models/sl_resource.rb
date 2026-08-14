# frozen_string_literal: true

# Consulta al Service Layer administrable desde la interfaz.
#
# `resource` guarda el path relativo tal como se le pasa a
# `Clavisco::ServiceLayer::Client#get` — entidad estándar (`Orders`) o vista
# semántica ya calificada con su prefijo (`sml.svc/…` en HANA, `view.svc/…` en
# SQL). El prefijo se resuelve al sembrar, no en cada lectura: ver la sección de
# `sl_resources` en `db/seeds.rb`.
#
# El modelo NO habla HTTP: quien consuma estas filas sigue pasando por el Client
# del submódulo (CLAUDE.md §29).
class SlResource < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Marca que distingue una vista (calculation/semantic view expuesta por el
  # Service Layer) de una entidad estándar de SAP. Es el criterio que usa el
  # seed para decidir si hay que calificar el `resource` con un prefijo.
  VIEW_MARKER = 'B1SLQuery'

  validates :code, presence: true, length: { maximum: 100 }
  # `conditions:` con `unscope` es obligatorio: `SoftDeletable` instala
  # `default_scope { where(is_active: true) }`, así que sin esto la validación no
  # ve a las filas dadas de baja y el choque lo termina reportando el índice
  # único de la base como un 500 (CLAUDE.md §28).
  validates :code, uniqueness: { case_sensitive: false,
                                 conditions: -> { unscope(where: :is_active) } }, if: :code?
  validates :resource, presence: true
  # `0` es un valor legítimo y NO significa "una página de cero filas": es como el
  # origen expresa "sin paginación" — las escrituras (`Drafts`,
  # `PurchaseInvoices`, `Attachments2`) y las lecturas de una sola fila lo traen
  # en 0. Se conserva tal cual en vez de normalizarlo a NULL para que la fila sea
  # comparable contra el export.
  validates :page_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # ¿La consulta pagina? Distingue el 0 del origen de un tamaño de página real.
  def paginated?
    page_size.to_i.positive?
  end

  # Vistas vs. entidades estándar de SAP. La marca vive en el `resource` porque
  # es el nombre que el Service Layer expone; no hay una columna que lo declare.
  scope :views, -> { where(arel_table[:resource].matches("%#{VIEW_MARKER}%")) }

  # Carácter de escape del LIKE. Ver `#contains`.
  LIKE_ESCAPE = '\\'

  # Filtro de la pantalla de recursos. Los tres parámetros son opcionales; en
  # blanco no filtran nada.
  #
  # `is_standard` es terciario, no booleano: `nil` significa "no filtrar", que no
  # es lo mismo que `false` ("solo los personalizados"). Por eso se compara
  # contra `nil` y no con `present?` — `false.present?` es `false` y se comería
  # el filtro de "Personalizado".
  scope :search, lambda { |code: nil, resource: nil, is_standard: nil|
    scope = all
    scope = scope.where(contains(:code, code))         if code.present?
    scope = scope.where(contains(:resource, resource)) if resource.present?
    scope = scope.where(is_standard: is_standard)      unless is_standard.nil?
    scope
  }

  # Condición "contiene" para el LIKE, con el ESCAPE declarado.
  #
  # ⚠️ El `ESCAPE` no es opcional acá: `sanitize_sql_like` escapa los comodines
  # (`_` y `%`) con `\`, pero `Arel#matches` sin segundo argumento genera el LIKE
  # SIN cláusula `ESCAPE`, y entonces la base trata al `\` como un carácter más y
  # la búsqueda no encuentra nada. Se nota justo acá porque los nombres de las
  # vistas son todos guiones bajos: buscar `CL_D_CL` devolvía 0 filas de 22.
  # Público a propósito: `self` dentro de un `scope` es la relación, no la clase,
  # y una relación solo delega métodos de clase públicos.
  def self.contains(column, value)
    arel_table[column].matches("%#{sanitize_sql_like(value.to_s.strip)}%", LIKE_ESCAPE)
  end

  # Una consulta editada por el cliente deja de ser la que trae el producto: el
  # seed no la vuelve a escribir y la pantalla la muestra como "Personalizado".
  # Se llama desde el endpoint de actualización, no desde un callback, para que
  # el seed pueda escribir `is_standard: true` sin que se lo revierta.
  def mark_as_customized
    self.is_standard = false
  end

  # ¿El `resource` apunta a una vista? Case-insensitive porque el nombre viene
  # en mayúsculas cuando la base es HANA.
  def view?
    resource.to_s.match?(/#{Regexp.escape(VIEW_MARKER)}/i)
  end
end

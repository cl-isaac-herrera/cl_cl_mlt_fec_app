# frozen_string_literal: true

# Servidor SAP alcanzable por Service Layer. Varias compañías pueden vivir en el
# mismo servidor y distinguirse por su `sap_db`.
#
# Nombres de columna según CLAVISCO-PLATFORM-STANDARDS §8: `sl_url` es la URL del
# Service Layer. `sl_type` (motor: SQL Server o HANA) es propio de este producto.
#
# La tabla es deliberadamente más chica que la `SAPConnection` del .NET: los
# parámetros de DI-API/ODBC (LicenseServer, ODBCType, ServerType, DBUser,
# DBPass, BoSuppLangs, DST, UseTrusted) se eliminaron por decisión de producto,
# no quedaron pendientes — este producto llega a SAP únicamente por Service
# Layer (`CLAUDE.md` §29). El formulario refleja estas columnas y solo estas
# (`CLAUDE.md` §22).
class Connection < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Motores sobre los que puede correr SAP. Condiciona la sintaxis de las
  # consultas y de las funciones de fecha, no cómo se habla con el Service Layer.
  SL_TYPES = %w[SQL HANA].freeze

  # Credenciales de licencia del servidor, para los procesos que hablan con SAP
  # sin una persona detrás (`SyncIssuedDocumentsJob`). Ver la migración
  # `20260825140000_add_sap_license_to_connections.rb` para el razonamiento de
  # por qué viven acá y no en `companies`.
  #
  # Cifrado reversible y no digest: el `/Login` del Service Layer necesita la
  # contraseña en claro. `encrypts` solo actúa al ESCRIBIR el atributo, así que
  # una fila insertada por SQL directo o por una importación queda en texto plano
  # y nadie avisa (`CLAUDE.md` §29 regla 1).
  encrypts :sap_license_password

  # El largo se valida sobre el texto en claro, que es lo que el usuario escribe.
  # La columna no lleva `limit:` porque guarda el sobre del cifrado, que es más
  # largo que el dato (§29 regla 4).
  validates :sap_license_password, length: { maximum: 100 }, allow_nil: true

  # La asociación inversa se llama `sap_connection` en Company para no pisar
  # `ActiveRecord::Base#connection`.
  has_many :companies, foreign_key: :connection_id, inverse_of: :sap_connection, dependent: :nullify

  validates :name, presence: true, length: { maximum: 100 }
  # Único entre las activas: una conexión dada de baja no debe bloquear el
  # nombre. `is_active` está en el scope por eso, no por multitenancy.
  validates :name, uniqueness: { scope: :is_active, case_sensitive: false }, if: :name?
  validates :sl_url, presence: true, length: { maximum: 250 }, format: {
    with:    %r{\Ahttps?://}i,
    message: 'debe empezar con http:// o https://',
    allow_blank: true
  }
  validates :sl_type, inclusion: { in: SL_TYPES, message: 'no es un motor válido' }, allow_blank: true
  validates :sap_license, length: { maximum: 100 }, allow_nil: true

  # ¿Se puede autenticar un proceso de fondo contra este servidor?
  #
  # Las dos mitades tienen que estar: el Client valida sus argumentos con
  # `ArgumentError`, y un usuario sin contraseña produciría un rechazo de SAP que
  # se lee como "credenciales inválidas" en vez de "faltó configurarlas".
  def sap_license?
    sap_license.present? && sap_license_password.present?
  end

  # Filtro de la pantalla de conexiones. Ambos parámetros son opcionales y se
  # aplican como "contiene"; en blanco no filtran nada.
  scope :search, lambda { |name: nil, sl_url: nil|
    scope = all
    scope = scope.where(arel_table[:name].matches("%#{sanitize_sql_like(name.to_s.strip)}%"))     if name.present?
    scope = scope.where(arel_table[:sl_url].matches("%#{sanitize_sql_like(sl_url.to_s.strip)}%")) if sl_url.present?
    scope
  }
end

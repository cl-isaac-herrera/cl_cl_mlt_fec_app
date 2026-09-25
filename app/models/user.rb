# frozen_string_literal: true

# Persona que entra a la aplicación. La autenticación la resuelve el proveedor
# OIDC; esta tabla dice quién es, a qué compañías llega y con qué rol en cada
# una (`users_by_companies.role_id`), y con qué rol de INSTALACIÓN administra
# el producto entero (`installation_role_id` — docs/PLAN-ROLES-POR-ALCANCE.md).
#
# La tabla es más chica que la `Users` del .NET, que venía de ASP.NET Identity:
# no hay `PasswordHash`, `EmailConfirmed`, `UserName` ni `Identification`. Las
# tres primeras las reemplazó el IdP (ya no hay contraseña propia ni correo que
# confirmar, y el nombre de usuario ES el correo); `Identification` no tiene
# consumidor en este producto. El formulario refleja estas columnas y solo estas.
class User < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Cifrada en reposo, no hasheada: el Service Layer de SAP pide la contraseña en
  # claro para hacer /Login, así que tiene que poder descifrarse. Reemplaza al AES
  # que aplicaba el API .NET antes de llamar a `spUpdateUserInfo`.
  encrypts :sap_password

  has_many :users_by_companies, dependent: :destroy
  has_many :companies, through: :users_by_companies

  # Rol de INSTALACIÓN (docs/PLAN-ROLES-POR-ALCANCE.md): aplica sin depender de
  # ninguna compañía activa. Nullable — un usuario puede no administrar nada de
  # la instalación y solo operar dentro de las compañías que tiene asignadas.
  belongs_to :installation_role, class_name: 'Role', optional: true

  validates :email, presence: true, length: { maximum: 256 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  # El índice único de `users.email` NO excluye a los inactivos, así que la
  # validación tampoco puede: sin `unscope` el default_scope de SoftDeletable
  # esconde al homónimo dado de baja, la validación pasa y explota la base.
  validates :email, uniqueness: {
    case_sensitive: false,
    conditions:     -> { unscope(where: :is_active) }
  }, if: :email?

  validates :name, length: { maximum: 150 }

  # Largos heredados del contrato del API .NET (PatchProfileInformationDto), para
  # que los datos sigan cabiendo cuando la base vuelva a ser SQL Server.
  validates :sap_user,     length: { maximum: 75 }, allow_blank: true
  validates :sap_password, length: { maximum: 50 }, allow_blank: true
  validate :installation_role_must_be_installation_scoped

  # `true` cuando las credenciales que se están guardando son exactamente las que
  # acaban de pasar la prueba contra el Service Layer. No es una columna: lo
  # decide el controller con `Sap::CredentialVerification`, nunca el cliente.
  attr_accessor :sap_credentials_just_verified

  # `sap_credentials_verified` describe las credenciales GUARDADAS, así que cambia
  # con ellas: cualquier cambio de usuario o contraseña que no venga probado lo
  # apaga. Vive en el modelo para que ninguna pantalla que edite credenciales
  # (perfil propio, administración de usuarios) pueda dejar el ícono en verde
  # sobre unas credenciales que nadie probó.
  before_save :sync_sap_credentials_verified

  # Filtro de la lista de usuarios. Ambos parámetros son opcionales y se aplican
  # como "contiene"; en blanco no filtran nada.
  #
  # ⚠️ El `LIKE` de SQLite solo ignora la caja en ASCII: buscar `SOLÍ` no encuentra
  # a `Solís` (sí lo encuentra `solí`). No se corrige acá porque `LOWER()` tampoco
  # cubre acentos sin la extensión ICU, y en SQL Server —que es a donde va esta
  # base— la collation por defecto ya es case e accent insensitive. Anotado en
  # TODOS.md.
  scope :search, lambda { |name: nil, email: nil|
    scope = all
    scope = scope.where(arel_table[:name].matches("%#{sanitize_sql_like(name.to_s.strip)}%"))   if name.present?
    scope = scope.where(arel_table[:email].matches("%#{sanitize_sql_like(email.to_s.strip)}%")) if email.present?
    scope
  }

  private

  def installation_role_must_be_installation_scoped
    return if installation_role.nil? || installation_role.scope == 'installation'

    errors.add(:installation_role, "es de alcance #{installation_role.scope} y tiene que ser de instalación")
  end

  def sync_sap_credentials_verified
    if sap_credentials_just_verified
      self.sap_credentials_verified = true
    elsif will_save_change_to_sap_user? || will_save_change_to_sap_password?
      self.sap_credentials_verified = false
    end
  end
end

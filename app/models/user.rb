# frozen_string_literal: true

# Persona que entra a la aplicación. La autenticación la resuelve el proveedor
# OIDC; esta tabla dice quién es, a qué compañías llega (`users_by_companies`) y
# con qué rol en cada una (`user_roles`).
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
  has_many :user_roles, dependent: :destroy

  # Permisos concedidos directamente, sin rol y sin compañía. Solo `global`.
  has_many :user_permissions, dependent: :destroy
  has_many :global_permissions, through: :user_permissions, source: :permission

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
  validates :sap_user,              length: { maximum: 75 }, allow_blank: true
  validates :sap_password,          length: { maximum: 50 }, allow_blank: true
  validates :doc_number_preference, length: { maximum: 2 },  allow_blank: true

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

  # Usuarios asignados a una compañía. Es el alcance por defecto de la lista:
  # quien administra usuarios ve a los de su compañía, no a los de todo el
  # sistema (para eso está `Configurations_Users_ViewAllApplicationUsers`).
  scope :in_company, lambda { |company_id|
    where(id: UsersByCompany.where(company_id: company_id).select(:user_id))
  }
end

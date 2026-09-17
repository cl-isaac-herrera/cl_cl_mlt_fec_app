# frozen_string_literal: true

# Bandeja de correo de RECEPCIÓN: de dónde `MailReceptionJob` lee los
# documentos electrónicos que envían los proveedores. Administrada en
# `/configurations/mail-parser` ("Bandejas de recepción"); una compañía usa la
# que tenga asignada (`Company#reception_mailbox`) para archivar sus .eml en
# su propia carpeta — la compañía REAL de cada documento se resuelve aparte,
# por la identificación del receptor que trae el XML
# (`Mail::IncomingDocument`), porque una misma bandeja puede recibir
# documentos para más de una compañía.
#
# Reemplaza `MailParserConfig` del conector .NET legacy
# (`legacy/reception/clvsfemailsconector`), recortado a la conexión: sin
# `CompanyId` (la relación se invierte, ver `Company#reception_mailbox`) ni
# `IsAutomatic` (el job corre siempre por `config/recurring.yml`, no hay un
# modo manual).
class ReceptionMailbox < ApplicationRecord
  include Clavisco::DataAccess::Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Cifrados y reversibles: `MailReceptionJob` necesita los dos en claro para
  # autenticar contra el IMAP o pedir el token OAuth2 (CLAUDE.md §29).
  # `encrypts` solo actúa al ESCRIBIR el atributo — una fila insertada por
  # fuera del modelo queda en texto plano.
  encrypts :password
  encrypts :client_secret

  has_many :companies, dependent: :nullify

  validates :mail_server, presence: true, length: { maximum: 255 }
  validates :email, presence: true, length: { maximum: 160 },
                     format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :port, presence: true
  # `allow_nil` en la numericalidad: sin él, un puerto vacío dispara los DOS
  # validadores (mismo criterio que `EmailConfig#port`).
  validates :port, numericality: { only_integer: true, greater_than: 0,
                                   less_than_or_equal_to: 65_535 }, allow_nil: true

  # Dos bandejas activas con el mismo correo son la misma cuenta cargada dos
  # veces (mismo criterio que `EmailConfig#email`, CLAUDE.md §38).
  validates :email, uniqueness: { case_sensitive: false,
                                  conditions: -> { where(is_active: true) } },
                    allow_blank: true

  # Los campos de OAuth2 son de texto plano —viajan siempre, no son secretos
  # enmascarados como `client_secret`— así que se exigen completos apenas
  # `use_token` está encendido, sin esperar a guardar.
  #
  # Sin `tenant_id`: el "OAuth 2.0 token endpoint (v2)" que muestra el
  # registro de la app en Azure/Entra ID ya trae el tenant real incrustado
  # (`https://login.microsoftonline.com/<tenant-guid>/oauth2/v2.0/token`), así
  # que `url` sola alcanza — un campo aparte no tendría con qué armar nada.
  validates :url, :grant_type, :scope, :client_id, presence: true, if: :use_token?

  # Al CREAR, alguna de las dos mitades de credenciales tiene que venir: sin
  # esto se podría guardar una bandeja que ningún modo de autenticación puede
  # usar, y el error recién aparecería en el primer intento de
  # `MailReceptionJob`. En EDICIÓN no se exige — un campo en blanco significa
  # "conservar el guardado" (`password_param`/`client_secret_param` del
  # controller), igual que `EmailConfig#password`.
  validate :secret_present_on_create, on: :create

  # Bajar una bandeja que alguna compañía todavía usa la dejaría sin poder
  # recibir documentos, y sin ningún aviso.
  validate :not_in_use_when_deactivating, if: -> { is_active_changed?(to: false) }

  # Filtro del listado de administración. `email` como "contiene";
  # `use_token` en blanco no filtra nada.
  scope :search, lambda { |email: nil, use_token: nil|
    scope = all
    if email.present?
      scope = scope.where(arel_table[:email].matches("%#{sanitize_sql_like(email.to_s.strip)}%"))
    end
    use_token.nil? ? scope : scope.where(use_token: use_token)
  }

  # Orden de trabajo de `MailReceptionJob`: la que lleva más tiempo sin
  # procesarse va primero. Con el límite duro de la corrida
  # (`MailReceptionJob::DEFAULT_MAX_MESSAGES_PER_EXECUTION`) no siempre se
  # llega a todas las bandejas activas, así que sin este orden las últimas
  # de la lista podrían quedar sin turno corrida tras corrida.
  #
  # `NULL` (nunca procesada) ordena ANTES que cualquier fecha real en SQLite
  # con `ASC` — es exactamente la prioridad máxima que le corresponde a una
  # bandeja nueva.
  scope :oldest_first, -> { order(:last_processed_at) }

  # ¿Hay una contraseña/client secret guardados? Se pregunta por el valor
  # CRUDO de la columna y no por el atributo descifrado — mismo motivo que
  # `EmailConfig#password_stored?`: no hace falta descifrar un secreto solo
  # para poner un placeholder en el formulario, y no revienta con una fila
  # importada en texto plano.
  def password_stored?      = read_attribute_before_type_cast(:password).present?
  def client_secret_stored? = read_attribute_before_type_cast(:client_secret).present?

  private

  def secret_present_on_create
    if use_token?
      errors.add(:client_secret, 'no puede estar en blanco') if client_secret.blank?
    else
      errors.add(:password, 'no puede estar en blanco') if password.blank?
    end
  end

  def not_in_use_when_deactivating
    names = companies.order(:name).pluck(:name)
    return if names.empty?

    # Se agrega a `:base` y no a `is_active`: el mensaje ya es una oración
    # completa (mismo criterio que `EmailConfig#not_in_use_when_deactivating`).
    errors.add(:base, "La bandeja de recepción no se puede desactivar porque #{names.to_sentence} " \
                      "#{names.one? ? 'la usa' : 'la usan'} para recibir documentos")
  end
end

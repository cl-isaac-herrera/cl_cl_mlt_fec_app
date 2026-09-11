# frozen_string_literal: true

# Bandeja de correo SMTP para el envío de notificaciones. Una compañía usa la
# que tenga asignada (`Company#email_config`); sin asignar, no puede enviar
# todavía — ver `Documents::ReceiptMailer::MissingConfiguration`.
#
# La administra `/configurations/email-senders` (alta, edición y baja) y se le
# asigna a una compañía desde la sección "Datos Generales" del formulario de
# compañías, con el mismo patrón que la conexión de SAP.
#
# Equivalente Rails del `EmailConfig` del .NET legacy
# (`legacy/apis/clvsfesync4.3/CLVS_FE.Mails/Common.cs`), recortado a lo que el
# envío por SMTP necesita: sin los indicadores `ActiveMailsService` /
# `ActiveReceptMailsService` del legacy (una bandeja por compañía, no por tipo
# de servicio) ni `LastAttempt*` (eso lo lleva la cola externa,
# `Documents::MailQueue`).
#
# ── Una bandeja por compañía, y no varias ────────────────────────────────────
# El legacy tenía una tabla puente (`CompanyEmailConfig`) que permitía asignarle
# N bandejas a una compañía, pero el envío resolvía la suya con un
# `FirstOrDefault` (`GetData.getEmailConfigs`): de las N, usaba una arbitraria y
# las demás eran adorno. Acá la relación es `companies.email_config_id`, que es
# lo que el legacy hacía de verdad, dicho sin ambigüedad.
class EmailConfig < ApplicationRecord
  include Clavisco::DataAccess::Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Cifrada y reversible, no un digest: el SMTP necesita la contraseña en claro
  # para autenticar (CLAUDE.md §29). `encrypts` solo actúa al ESCRIBIR el
  # atributo — una fila insertada por fuera del modelo queda en texto plano.
  encrypts :password

  has_many :companies, dependent: :nullify

  validates :email, presence: true, length: { maximum: 160 },
                     format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :host, presence: true, length: { maximum: 50 }
  # `allow_nil` en la numericalidad: sin él, un puerto vacío dispara los DOS
  # validadores y el usuario lee "El puerto no puede estar en blanco y El puerto
  # no es un número" — la segunda mitad no agrega nada y hace dudar de la primera.
  validates :port, presence: true
  validates :port, numericality: { only_integer: true, greater_than: 0,
                                   less_than_or_equal_to: 65_535 }, allow_nil: true
  validates :sender_address, length: { maximum: 160 }, allow_nil: true

  # Dos bandejas activas con la misma dirección no son dos cosas distintas: son
  # la misma cuenta cargada dos veces, y el formulario de compañías mostraría dos
  # opciones idénticas sin manera de elegir.
  #
  # `conditions:` explícito y no confiando en el `default_scope` de
  # `SoftDeletable`: la pantalla de administración consulta con `unscoped` (§28) y
  # ahí el default_scope no está puesto. La condición acota la unicidad a las
  # ACTIVAS a propósito — dar de baja una bandeja tiene que dejar libre su
  # dirección para volver a cargarla.
  validates :email, uniqueness: { case_sensitive: false,
                                  conditions: -> { where(is_active: true) } },
                    allow_blank: true

  # Bajar una bandeja que alguna compañía todavía usa la dejaría sin poder
  # enviar, y sin ningún aviso: `Company#email_config` pasa a `nil` por el
  # `default_scope` y el correo falla recién cuando hay algo que mandar. Se
  # bloquea acá y el mensaje dice qué compañías hay que reasignar primero.
  validate :not_in_use_when_deactivating, if: -> { is_active_changed?(to: false) }

  # Filtro del listado de administración. Se aplica como "contiene" sobre la
  # dirección; `ssl` en blanco no filtra nada.
  scope :search, lambda { |email: nil, ssl: nil|
    scope = all
    if email.present?
      scope = scope.where(arel_table[:email].matches("%#{sanitize_sql_like(email.to_s.strip)}%"))
    end
    ssl.nil? ? scope : scope.where(ssl: ssl)
  }

  # El remitente que compone el header `From`: `email` es la dirección real
  # (la que autentica contra el SMTP); `sender_address`, cuando está, es el
  # nombre visible — mismo criterio que `MailAddress(Email, SenderAddress)` del
  # legacy.
  def from_header
    return email if sender_address.blank?

    %("#{sender_address}" <#{email}>)
  end

  # ¿Hay una contraseña guardada? Se pregunta por el valor CRUDO de la columna y
  # no por el atributo descifrado: la respuesta es la misma —o hay algo escrito o
  # no lo hay— y así no se descifra un secreto solo para poner un placeholder en
  # el formulario. Además no revienta con una fila importada en texto plano, que
  # con `support_unencrypted_data = false` levanta al leerla.
  #
  # Es lo único que se le cuenta al cliente de la contraseña: el valor no sale
  # nunca de la aplicación (ver `Api::EmailConfigsController#serialize`).
  def password_stored? = read_attribute_before_type_cast(:password).present?

  private

  def not_in_use_when_deactivating
    names = companies.order(:name).pluck(:name)
    return if names.empty?

    # Se agrega a `:base` y no a `is_active`: el mensaje ya es una oración
    # completa, y `errors.format` le antepondría "El estado" delante.
    errors.add(:base, "La bandeja no se puede desactivar porque #{names.to_sentence} " \
                      "#{names.one? ? 'la usa' : 'la usan'} para enviar correos")
  end
end

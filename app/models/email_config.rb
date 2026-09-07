# frozen_string_literal: true

# Bandeja de correo SMTP para el envío de notificaciones. Una compañía usa la
# que tenga asignada (`Company#email_config`); sin asignar, no puede enviar
# todavía — ver `Documents::ReceiptMailer::MissingConfiguration`.
#
# Equivalente Rails del `EmailConfig` del .NET legacy
# (`legacy/apis/clvsfesync4.3/CLVS_FE.Mails/Common.cs`), recortado a lo que el
# envío por SMTP necesita: sin los indicadores `ActiveMailsService` /
# `ActiveReceptMailsService` del legacy (una bandeja por compañía, no por tipo
# de servicio) ni `LastAttempt*` (eso lo lleva la cola externa,
# `Documents::MailQueue`).
class EmailConfig < ApplicationRecord
  # Cifrada y reversible, no un digest: el SMTP necesita la contraseña en claro
  # para autenticar (CLAUDE.md §29). `encrypts` solo actúa al ESCRIBIR el
  # atributo — una fila insertada por fuera del modelo queda en texto plano.
  encrypts :password

  has_many :companies, dependent: :nullify

  validates :email, presence: true, length: { maximum: 160 },
                     format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :host, presence: true, length: { maximum: 50 }
  validates :port, presence: true,
                    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 65_535 }
  validates :sender_address, length: { maximum: 160 }, allow_nil: true

  # El remitente que compone el header `From`: `email` es la dirección real
  # (la que autentica contra el SMTP); `sender_address`, cuando está, es el
  # nombre visible — mismo criterio que `MailAddress(Email, SenderAddress)` del
  # legacy.
  def from_header
    return email if sender_address.blank?

    %("#{sender_address}" <#{email}>)
  end
end

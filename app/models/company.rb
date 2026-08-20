class Company < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  has_many :users_by_companies, dependent: :destroy
  has_many :users, through: :users_by_companies

  # Nombrada `sap_connection` y no `connection` para no pisar
  # ActiveRecord::Base#connection en las instancias.
  belongs_to :sap_connection, class_name: 'Connection', foreign_key: :connection_id,
                              inverse_of: :companies, optional: true

  # Ambiente de Hacienda contra el que emite. Opcional porque una compañía puede
  # existir configurada a medias hasta que se le asigne.
  belongs_to :environment, inverse_of: :companies, optional: true

  # Cifrado reversible, no digest: el PIN se necesita en claro para abrir el .p12 y
  # la contraseña del ATV para pedirle el token a Hacienda. Ver `CLAUDE.md` §29 —
  # `encrypts` solo actúa al escribir el atributo, así que una fila insertada por
  # fuera del modelo queda en texto plano y nadie avisa.
  encrypts :cert_pin
  encrypts :token_password

  # Días de anticipación con los que se avisa que el certificado está por vencer.
  # Es el `certExpireCheckAlarm` de los appsettings del .NET, que valía 7 en los
  # tres ambientes: queda como constante y no como setting porque nunca cambió por
  # instalación.
  CERT_EXPIRATION_ALARM_DAYS = 7

  before_create :ensure_uuid

  # Compañías asignadas a un usuario. Es el filtro que define qué puede ver en el
  # selector: nunca se listan todas las compañías del sistema.
  scope :assigned_to, lambda { |user_id|
    joins(:users_by_companies).where(users_by_companies: { user_id: user_id, is_active: true })
  }

  # Filtro del listado de administración. Se aplica como "contiene"; en blanco no
  # filtra nada. Solo por `name`: el nombre legal, el comercial y la
  # identificación viven en SAP (UDFs `U_CL_FEC_Emsr*` sobre `OADM`), no acá.
  scope :search, lambda { |name: nil|
    next all if name.blank?

    where(arel_table[:name].matches("%#{sanitize_sql_like(name.to_s.strip)}%"))
  }

  # Alarma de vencimiento del certificado digital, la que pinta el toast del home.
  #
  # Reemplaza el stored procedure `spCertExpireDateAlarm` del .NET, que recibía el
  # umbral en días y devolvía estas dos claves. El cálculo sale de
  # `cert_expires_at`, que es la única fuente del dato: no hay que ir a SAP ni
  # volver a abrir el .p12 para saber si vence.
  #
  # Sin fecha registrada no hay alarma: no se sabe si vence, y avisar "no hay
  # certificado" es trabajo del formulario de la compañía, no de un toast que
  # aparece en cada carga del home.
  #
  # @param days [Integer] umbral de anticipación, en días.
  # @return [Hash] `ShowAlarm` y `SmsAlert` — PascalCase porque es el contrato que
  #   ya consume el frontend.
  def certificate_alarm(days: CERT_EXPIRATION_ALARM_DAYS)
    return { ShowAlarm: false, SmsAlert: nil } if cert_expires_at.blank?

    remaining = (cert_expires_at.to_date - Date.current).to_i
    return { ShowAlarm: false, SmsAlert: nil } if remaining > days

    { ShowAlarm: true, SmsAlert: cert_expiration_message(remaining) }
  end

  private

  # El texto del toast. Se arma en el servidor —y no en el JS— porque es el mismo
  # `SmsAlert` que armaba el SP: el cliente solo lo muestra.
  def cert_expiration_message(remaining)
    date    = cert_expires_at.to_date.strftime('%d/%m/%Y')
    subject = "El certificado digital de #{name}"
    action  = 'Debe cargar uno vigente'

    return "#{subject} venció el #{date}. #{action} para poder emitir documentos electrónicos." if remaining.negative?
    return "#{subject} vence hoy (#{date}). #{action} para no interrumpir la emisión." if remaining.zero?

    plural = remaining == 1 ? 'día' : 'días'
    "#{subject} vence en #{remaining} #{plural} (#{date}). #{action} antes de esa fecha."
  end

  # Generado en Ruby y no en la base: el estándar prohíbe SQL específico de SQLite.
  def ensure_uuid
    self.uuid ||= SecureRandom.uuid
  end
end

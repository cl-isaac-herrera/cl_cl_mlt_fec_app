class Company < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  has_many :users_by_companies, dependent: :destroy
  has_many :users, through: :users_by_companies

  # Nombrada `sap_connection` y no `connection` para no pisar
  # ActiveRecord::Base#connection en las instancias.
  belongs_to :sap_connection, class_name: 'Connection', foreign_key: :connection_id,
                              inverse_of: :companies, optional: true

  # Bandeja de correo SMTP para el envío de notificaciones (`SendElectronicReceiptJob`).
  # Opcional: sin asignar, la compañía simplemente no puede enviar todavía.
  belongs_to :email_config, optional: true

  # Bandeja de correo de RECEPCIÓN, de la que `MailReceptionJob` lee los
  # documentos de los proveedores para archivarlos en la carpeta de esta
  # compañía (`Documents::EmailArchive`). Opcional, mismo criterio que
  # `email_config`: sin asignar, la compañía simplemente no tiene todavía una
  # bandeja de la que leerle nada.
  belongs_to :reception_mailbox, optional: true

  # Cifrado reversible, no digest: el PIN se necesita en claro para abrir el .p12 y
  # la contraseña del ATV para pedirle el token a Hacienda. Ver `CLAUDE.md` §29 —
  # `encrypts` solo actúa al escribir el atributo, así que una fila insertada por
  # fuera del modelo queda en texto plano y nadie avisa.
  encrypts :cert_pin
  encrypts :token_password

  # Tipos de identificación de Hacienda. Texto y no entero: los códigos llevan el
  # cero adelante y `'01'.to_i` lo perdería.
  ISSUER_ID_TYPES = %w[01 02 03 04].freeze

  # Con qué nombre se envían los correos: 1 legal, 2 comercial. Son las dos
  # opciones del `<select>` del formulario; cualquier otro valor lo deja sin nada
  # seleccionado, que es lo que pasaba con el 0 que traía el default original.
  EMAIL_SENDER_TYPES = [1, 2].freeze

  # Dónde se cargan los otros cargos del documento: 1 en las líneas de artículos,
  # 2 como gastos adicionales del documento.
  FREIGHT_TYPES = [1, 2].freeze

  # Defaults del mensaje receptor para esta compañía (`MailReception::EmailBodyTags`):
  # se usan cuando un correo de recepción NO trae el tag `[Tag:valor]`
  # correspondiente en el cuerpo. `default_recept_message` es el catálogo de
  # `MessageType` (1/2/3), no el código Hacienda de 2 dígitos.
  DEFAULT_RECEPT_MESSAGES = MessageType::ALL

  # Días de anticipación con los que se avisa que el certificado está por vencer.
  # Es el `certExpireCheckAlarm` de los appsettings del .NET, que valía 7 en los
  # tres ambientes: queda como constante y no como setting porque nunca cambió por
  # instalación.
  CERT_EXPIRATION_ALARM_DAYS = 7

  # La columna es `not null`: sin esto, guardar el formulario con el nombre en
  # blanco revienta contra la restricción de la base y llega como un 500 en vez de
  # un mensaje.
  #
  # El máximo de 80 no es una preferencia de la pantalla: `name` es el nombre
  # comercial que viaja en el XML como `Emisor.NombreComercial`, y ese es el largo
  # que acepta el esquema 4.4 de Hacienda. Un nombre más largo no se ve mal, se
  # rechaza — y el rechazo llega mucho después de que alguien lo escribió.
  validates :name, presence: true, length: { maximum: 80 }

  # `belongs_to ... optional: true` no valida nada cuando el id SÍ viene: una
  # conexión inexistente pasaría el modelo y la rechazaría la llave foránea, que
  # también llega como 500. `unscoped` porque una conexión dada de baja sigue
  # siendo una referencia válida — es la que ya tenía la compañía.
  validate :sap_connection_must_exist

  # Mismo motivo que arriba: `optional: true` no valida nada cuando el id SÍ
  # viene, y una bandeja inexistente la rechazaría la llave foránea como un 500.
  #
  # A diferencia de la conexión, acá NO se usa `unscoped`: asignarle a una
  # compañía una bandeja dada de baja la dejaría sin poder enviar en silencio
  # (`Company#email_config` devuelve `nil` por el `default_scope`). La bandeja
  # que ya tenía asignada tampoco se puede dar de baja mientras la use
  # (`EmailConfig#not_in_use_when_deactivating`), así que no hay forma de que una
  # compañía guardada apunte a una inactiva.
  validate :email_config_must_be_available

  # Mismo motivo y mismo criterio que la validación de arriba: sin
  # `unscoped`, asignarle a una compañía una bandeja de recepción dada de baja
  # la dejaría sin recibir documentos en silencio, y la que ya tenía asignada
  # tampoco se puede dar de baja mientras la use
  # (`ReceptionMailbox#not_in_use_when_deactivating`).
  validate :reception_mailbox_must_be_available

  # Los largos replican el `Size` que estos campos tenían como UDFs de `OADM`,
  # que es el límite con el que se venían guardando. La validación mira el texto
  # original; el `limit:` de la columna es la otra mitad (ver la migración).
  #
  # `issuer_id_number` es la excepción: subió de 12 a 20 porque el `Size` del UDF
  # no alcanzaba para el DIMEX ni para el NITE, y desde que la identificación del
  # emisor sale de acá (`Documents::UnifiedBuilder#emisor`) el recorte se llevaría
  # puesto el comprobante. Ver `20260901120000_tighten_company_identity_limits.rb`.
  validates :issuer_legal_name,      length: { maximum: 100 }, allow_nil: true
  validates :issuer_id_number,       length: { maximum: 20 },  allow_nil: true
  validates :economic_activity_code, length: { maximum: 6 },   allow_nil: true
  validates :tax_registry_8707,      length: { maximum: 12 },  allow_nil: true
  validates :default_xml_tax_code,   length: { maximum: 8 },   allow_nil: true
  validates :default_warehouse,      length: { maximum: 8 },   allow_nil: true
  validates :issuer_id_type, inclusion: { in: ISSUER_ID_TYPES }, allow_blank: true
  validates :purchase_invoice_series, numericality: { only_integer: true, greater_than: 0 },
                                      allow_nil: true

  # Sin `allow_nil`: las dos columnas son `not null` con default, así que un valor
  # fuera de la lista es un error, no un campo sin llenar.
  validates :email_sender_type, inclusion: { in: EMAIL_SENDER_TYPES }
  validates :freight_type,      inclusion: { in: FREIGHT_TYPES }

  # Los cuatro son opcionales (`allow_nil`): una compañía sin default
  # simplemente no auto-resuelve el mensaje receptor que le falte el tag
  # correspondiente (`MailReception::EmailBodyTags` cae al vacío/0 de la UDT).
  validates :default_recept_message,       inclusion: { in: DEFAULT_RECEPT_MESSAGES }, allow_nil: true
  validates :default_recept_details,       length: { maximum: 160 }, allow_nil: true
  validates :default_recept_tax_condition, inclusion: { in: TaxCondition::ALL }, allow_nil: true

  before_create :ensure_uuid

  # Compañías asignadas a un usuario. Es el filtro que define qué puede ver en el
  # selector: nunca se listan todas las compañías del sistema.
  scope :assigned_to, lambda { |user_id|
    joins(:users_by_companies).where(users_by_companies: { user_id: user_id, is_active: true })
  }

  # Filtro del listado de administración. Cada parámetro se aplica como
  # "contiene"; en blanco no filtra nada. Por decisión de producto solo
  # `name` (el comercial) e `issuer_id_number` (la cédula) son filtrables — el
  # nombre legal es columna pero no se ofrece como filtro.
  scope :search, lambda { |name: nil, issuer_id_number: nil|
    scope = all
    scope = scope.where(arel_table[:name].matches("%#{sanitize_sql_like(name.to_s.strip)}%")) if name.present?
    if issuer_id_number.present?
      scope = scope.where(
        arel_table[:issuer_id_number].matches("%#{sanitize_sql_like(issuer_id_number.to_s.strip)}%")
      )
    end
    scope
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
  # ¿Hay un PIN de certificado guardado? Se pregunta por el valor CRUDO de la
  # columna y no por el atributo descifrado: la respuesta es la misma —o hay
  # algo escrito o no lo hay— y así no se descifra solo para poner un
  # placeholder en el formulario. Además no revienta con una fila importada en
  # texto plano, que con `support_unencrypted_data = false` levanta al leerla.
  #
  # Es lo único que se le cuenta al cliente de los dos secretos: el valor no sale
  # nunca de la aplicación (ver `Api::Companies::TaxAuthorityController`).
  def cert_pin_stored? = read_attribute_before_type_cast(:cert_pin).present?

  def token_password_stored? = read_attribute_before_type_cast(:token_password).present?

  # Con qué nombre se identifica la compañía en el correo de recepción
  # electrónica, según `email_sender_type` (1 legal, 2 comercial). El legal es
  # opcional (`issuer_legal_name` admite `nil`); si no está cargado, cae al
  # comercial (`name`, `NOT NULL`) en vez de mandar un correo sin nombre.
  def email_sender_name
    email_sender_type == 1 ? issuer_legal_name.presence || name : name
  end

  def certificate_alarm(days: CERT_EXPIRATION_ALARM_DAYS)
    return { ShowAlarm: false, SmsAlert: nil } if cert_expires_at.blank?

    remaining = (cert_expires_at.to_date - Date.current).to_i
    return { ShowAlarm: false, SmsAlert: nil } if remaining > days

    { ShowAlarm: true, SmsAlert: cert_expiration_message(remaining) }
  end

  private

  # Mensaje explícito, así que no pasa por i18n y no necesita clave (§30). El
  # nombre del atributo sí sale de `es.yml`.
  def sap_connection_must_exist
    return if connection_id.blank?
    return if Connection.unscoped.exists?(id: connection_id)

    errors.add(:connection_id, 'no corresponde a una conexión existente')
  end

  def email_config_must_be_available
    return if email_config_id.blank?
    return if EmailConfig.exists?(id: email_config_id)

    errors.add(:email_config_id, 'no corresponde a una bandeja de correo activa')
  end

  def reception_mailbox_must_be_available
    return if reception_mailbox_id.blank?
    return if ReceptionMailbox.exists?(id: reception_mailbox_id)

    errors.add(:reception_mailbox_id, 'no corresponde a una bandeja de recepción activa')
  end

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

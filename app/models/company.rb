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

  before_create :ensure_uuid

  # Compañías asignadas a un usuario. Es el filtro que define qué puede ver en el
  # selector: nunca se listan todas las compañías del sistema.
  scope :assigned_to, lambda { |user_id|
    joins(:users_by_companies).where(users_by_companies: { user_id: user_id, is_active: true })
  }

  # Filtro del listado de administración. Se aplica como "contiene"; en blanco no
  # filtra nada. Solo por `name` por decisión de producto: el nombre legal, el
  # comercial y la identificación sí son columnas y se podrían agregar acá.
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

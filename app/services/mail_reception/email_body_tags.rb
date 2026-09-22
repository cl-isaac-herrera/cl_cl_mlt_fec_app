# frozen_string_literal: true

module MailReception
  # Extrae los tags `[Tag:valor]` del cuerpo de un correo de recepción y
  # resuelve, campo por campo, el valor final del mensaje receptor:
  #
  #   tag del cuerpo del correo → default de la compañía → vacío/0 (lo que
  #   admita la UDT, `config/sap_schemas/reception_messages_udt.json`)
  #
  # Reemplaza `EmailBodyTagsService` del mail parser legacy
  # (`legacy/reception/clvsfemailsconector/FEProcesadorCorreoLib/Classes/
  # EmailBodyTagsService.cs`), que leía los mismos 5 tags de un cuerpo con
  # esta forma (en cualquier parte del texto, no en líneas separadas):
  #
  #   [Status:ACEPTADO][DetalleMensaje:Recibido conforme][CondicionImpuesto:01][TaxFactor:100]
  #
  # ── Diferencia deliberada frente al legacy ──────────────────────────────────
  # El legacy LANZA una excepción si `Status`/`CondicionImpuesto` trae un valor
  # fuera de catálogo (`ValidateBodyTagValue`, `EmailBodyTagsService.cs:188-209`).
  # Acá un tag inválido se trata como AUSENTE —con un warning en el log— y
  # sigue la misma cadena de resolución: un correo con un tag mal escrito no
  # puede tumbar el procesamiento del documento completo (mismo criterio de
  # resiliencia que el resto de `MailReceptionJob`).
  class EmailBodyTags
    TAG_PATTERN = /\[(?<tag>[A-Za-z]+):(?<value>[^\]]*)\]/

    KNOWN_TAGS = %w[Status DetalleMensaje CodigoActividadReceptor CondicionImpuesto TaxFactor].freeze

    Result = Struct.new(
      :message, :details, :tax_condition, :tax_factor, :economic_activity_code,
      keyword_init: true
    )

    # @param body [String] el cuerpo del correo (texto plano).
    # @param company [Company] de dónde salen los defaults cuando falta un tag.
    # @param client [Clavisco::ServiceLayer::Client] el de la compañía — lee la
    #   actividad económica de `Sap::CompanyConfig`, que ya no vive en
    #   `companies` (ver `#resolve_economic_activity_code`).
    def initialize(body, company:, client:)
      @tags = extract(body.to_s)
      @company = company
      @client = client
    end

    # @return [Result]
    def resolve
      Result.new(
        message: resolve_message,
        details: resolve_details,
        tax_condition: resolve_tax_condition,
        tax_factor: resolve_tax_factor,
        economic_activity_code: resolve_economic_activity_code
      )
    end

    private

    attr_reader :company, :client

    # Último match gana si el mismo tag aparece más de una vez en el cuerpo —
    # mismo criterio que el `foreach` de `SubstractBodyTags` en el legacy, que
    # sobrescribe el diccionario en cada vuelta.
    def extract(body)
      body.scan(TAG_PATTERN).each_with_object({}) do |(tag, value), acc|
        acc[tag] = value.strip if KNOWN_TAGS.include?(tag)
      end
    end

    def resolve_message
      raw = @tags['Status']
      return company.default_recept_message if raw.blank?

      digit = MessageType.from_body_tag(raw)
      return digit if digit

      log_invalid('Status', raw)
      company.default_recept_message
    end

    def resolve_details
      @tags['DetalleMensaje'].presence || company.default_recept_details
    end

    def resolve_tax_condition
      raw = @tags['CondicionImpuesto']
      return company.default_recept_tax_condition if raw.blank?
      return raw if TaxCondition.valid?(raw)

      log_invalid('CondicionImpuesto', raw)
      company.default_recept_tax_condition
    end

    def resolve_tax_factor
      raw = @tags['TaxFactor']
      return company.default_recept_tax_factor if raw.blank?

      Float(raw)
    rescue ArgumentError, TypeError
      log_invalid('TaxFactor', raw)
      company.default_recept_tax_factor
    end

    # Sin default propio: se reusa la actividad económica que la compañía ya
    # declara para sí misma (`Sap::CompanyConfig`, la UDT `@CL_FEC_ISSUERCONFIG`)
    # en vez de agregar un cuarto default redundante.
    def resolve_economic_activity_code
      @tags['CodigoActividadReceptor'].presence || Sap::CompanyConfig.new(client: client).read&.economic_activity_code
    end

    def log_invalid(tag, value)
      Rails.logger.warn(
        "[MailReception] tag [#{tag}:#{value}] inválido en el cuerpo del correo de " \
        "#{company.name.inspect} — se usa el default de la compañía."
      )
    end
  end
end

# frozen_string_literal: true

module Sap
  # Escribe la cabecera y las seis colecciones hijas del mensaje receptor de
  # un documento recibido de un proveedor, en las siete UDTs declaradas en
  # `config/sap_schemas/reception_messages_udt.json` (y sus hijas). Las llama
  # `MailReceptionJob` al identificar un XML de comprobante (FE/ND/NC) entre
  # los adjuntos de un correo de recepción.
  #
  #   Sap::ReceptionMessages.new(client: Sap::CompanyClient.for(company)).create_from_document(
  #     document: MailReception::ReceivedDocument.new(attachment.root, doc_type: attachment.doc_type),
  #     company: company, email_body: body_text, mailbox_email: mailbox.email
  #   )
  #
  # ── Reparto de responsabilidades ────────────────────────────────────────────
  # `MailReception::ReceivedDocument` solo sabe leer el XML del comprobante.
  # `MailReception::EmailBodyTags` solo sabe resolver Mensaje/DetalleMensaje/
  # CondicionImpuesto/TaxFactor/CodigoActividadReceptor (tag del correo →
  # default de la compañía → vacío). `TaxCondition` solo sabe calcular
  # crédito/gasto a partir de la condición. Esta clase es la única que conoce
  # el nombre de los siete `code` de `sl_resources` y el orden en que hay que
  # escribir cabecera → hijas para poder encadenar el `Code` que SAP asigna.
  #
  # ── `Code`, no `DocEntry`/`DocType`, es la llave entre tablas ───────────────
  # A diferencia de `Sap::DocSyncAttempts`/`Sap::MailQueue`, un documento
  # recibido no tiene `DocEntry` propio todavía (no es un objeto de SAP hasta
  # que, ya aceptado, se cree la factura de compra) — ver
  # `config/sap_schemas/README.md` §6. Por eso cada hija guarda el `Code`
  # autonumérico que devolvió el `POST` de su padre, en vez de `DocEntry`+
  # `DocType`.
  #
  # ── Qué NO decide esta clase ────────────────────────────────────────────────
  # No envía nada a Hacienda ni decide `DocEntry`/`DocTypeSAP` (se llenan
  # cuando exista el flujo que crea la factura de compra, todavía sin
  # implementar — CLAUDE.md §41, Prioridad 3). El `Status` con el que nace la
  # fila es siempre `STATUS_PENDING`: la cabecera queda creada con la decisión
  # YA resuelta (Mensaje, si hubo tag o default), pero sin enviar.
  class ReceptionMessages
    CREATE_HEADER       = 'createReceptionMessage'
    CREATE_LINE         = 'createReceptionMessageLine'
    CREATE_LINE_DETAIL  = 'createReceptionMessageLineDetail'
    CREATE_PAYMENT      = 'createReceptionMessagePayment'
    CREATE_OTHER_CHARGE = 'createReceptionMessageOtherCharge'
    CREATE_OTHER        = 'createReceptionMessageOther'
    CREATE_REFERENCE    = 'createReceptionMessageReference'

    # `0 Pending` del catálogo de `reception_messages_udt.json` → "decisión
    # resuelta, mensaje todavía sin enviar a Hacienda". Es el mismo catálogo
    # de 7 valores que `doc_sync_attempts_udt.json`, no el `StatusConverter`
    # 1-8 del legacy (`config/sap_schemas/README.md` → nota de `EmailBodyTags`).
    STATUS_PENDING = 0

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía
    #   (`Sap::CompanyClient.for(company)`).
    def initialize(client:)
      @client = client
    end

    # @param document [MailReception::ReceivedDocument]
    # @param company [Company]
    # @param email_body [String] cuerpo de texto del correo, para los tags.
    # @param mailbox_email [String] la bandeja que recibió el correo
    #   (`U_BandejaReceptor`).
    # @return [Integer] el `Code` de la cabecera creada.
    def create_from_document(document:, company:, email_body:, mailbox_email:)
      tags = MailReception::EmailBodyTags.new(email_body, company: company, client: client).resolve
      tax = TaxCondition.apply(
        condition: tags.tax_condition,
        tax_amount: document.header['MontoTotalImpuesto'] || 0,
        tax_factor: tags.tax_factor
      )

      header_code = create_header(document.header, tags: tags, tax: tax, mailbox_email: mailbox_email)

      document.lines.each { |line| create_line(header_code, line) }
      document.payments.each { |payment| create_payment(header_code, payment) }
      document.other_charges.each { |charge| create_other_charge(header_code, charge) }
      document.others.each { |other| create_other(header_code, other) }
      document.references.each { |reference| create_reference(header_code, reference) }

      header_code
    end

    private

    attr_reader :client

    def create_header(fields, tags:, tax:, mailbox_email:)
      now = Time.current.iso8601

      body = prefixed(fields).merge(
        'U_Mensaje' => tags.message && MessageType.to_doc_type(tags.message),
        'U_DetalleMensaje' => tags.details,
        'U_CondicionImpuesto' => tags.tax_condition,
        'U_TaxFactor' => tags.tax_factor,
        'U_CodigoActividadReceptor' => tags.economic_activity_code,
        'U_MontoTotalImpuestoAcreditar' => tax.tax_credit,
        'U_MontoTotalDeGastoAplicable' => tax.applicable_expense,
        'U_TaxesTag' => taxes_tag(fields['MontoTotalImpuesto']),
        'U_Status' => STATUS_PENDING,
        'U_Attempts' => 0,
        'U_CreationDate' => now,
        'U_LastTransact' => now,
        'U_BandejaReceptor' => mailbox_email,
        'U_DocName' => doc_name(fields['Clave'], tags.message)
      )

      post(CREATE_HEADER, body)
    end

    def create_line(header_code, line)
      surtido = line['surtido'] || []
      body = prefixed(line.except('surtido')).merge('U_MensajeReceptorCode' => header_code)
      line_code = post(CREATE_LINE, body)

      surtido.each { |item| create_line_detail(line_code, item) }
    end

    def create_line_detail(line_code, item)
      post(CREATE_LINE_DETAIL, prefixed(item).merge('U_MensajeReceptorLineaCode' => line_code))
    end

    def create_payment(header_code, payment)
      post(CREATE_PAYMENT, prefixed(payment).merge('U_MensajeReceptorCode' => header_code))
    end

    def create_other_charge(header_code, charge)
      post(CREATE_OTHER_CHARGE, prefixed(charge).merge('U_MensajeReceptorCode' => header_code))
    end

    def create_other(header_code, other)
      post(CREATE_OTHER, prefixed(other).merge('U_MensajeReceptorCode' => header_code))
    end

    def create_reference(header_code, reference)
      post(CREATE_REFERENCE, prefixed(reference).merge('U_MensajeReceptorCode' => header_code))
    end

    # `nil` se conserva y no se convierte en `''`/`0`: un campo opcional sin
    # dato en el XML es NULL en SAP, no un valor inventado (mismo criterio que
    # `Sap::DocSyncAttempts#create` con `U_Details`).
    def prefixed(fields)
      fields.transform_keys { |key| "U_#{key}" }
    end

    def post(code, body)
      Documents::Row.new(client.post(Sap::ResourceQuery.path_for(code), body: body)).integer('Code')
    end

    def taxes_tag(monto_total_impuesto)
      monto_total_impuesto.to_d.positive? ? 'Y' : 'N'
    end

    def doc_name(clave, message_digit)
      return clave unless message_digit

      "#{clave}-#{MessageType.label(message_digit)}"
    end
  end
end

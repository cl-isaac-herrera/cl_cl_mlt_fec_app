# frozen_string_literal: true

module Sap
  # Trae de SAP, por Service Layer, todo el detalle de UN documento de la cola.
  #
  #   details = Sap::DocumentDetails.new(company: company, doc_entry: 25, doc_type: '01').call
  #   details.header['Clave']   # => '506…'
  #   details.lines.size        # => 12
  #
  # Son las seis consultas de los puntos 3 al 8 de `docs/sync-documents-flow.md`.
  # Ninguna está escrita acá: viven en `sl_resources` (ver `db/seeds.rb` →
  # `SL_RESOURCES_OWN`) y se resuelven con `Sap::ResourceQuery`, que es el único
  # lugar que traduce código funcional → path de SAP. Es lo que hace que el
  # cliente pueda ajustar una consulta desde la pantalla y que el cambio tenga
  # efecto sin tocar el código.
  #
  # ── Las seis van SIEMPRE contra el mismo documento ───────────────────────────
  # Todas filtran por `@DocEntry` y `@DocType`, que es el par que identifica al
  # documento dentro de la compañía. Los marcadores los ata esta clase; si una
  # consulta del catálogo esperara otro parámetro, `ResourceQuery` levanta
  # `MissingBinding` en vez de mandarle a SAP un filtro a medias.
  class DocumentDetails
    # Códigos del catálogo. Los nombres siguen la convención `qs…` de las
    # consultas que ya venían del .NET.
    HEADER          = 'qsGetDocumentHeaderInfo'
    LINES           = 'qsGetDocumentLinesInfo'
    OTHER_CHARGES   = 'qsGetDocumentOtherChargesInfo'
    PAYMENT_METHODS = 'qsGetDocumentPaymentMethodsInfo'
    REFERENCES      = 'qsGetDocumentReferenceInfo'
    OTHERS          = 'qsGetDocumentOthersInfo'

    # La cabecera no vino. Es distinto de "el documento no tiene líneas": sin
    # cabecera no hay nada que armar, así que corta el documento en vez de dejar
    # pasar un comprobante vacío.
    class HeaderNotFound < StandardError; end

    # Lo que SAP devolvió, ya desenvuelto y en `Documents::Row`.
    #
    # `header` es UNA fila; el resto son listas —posiblemente vacías, que es un
    # estado legítimo: un documento puede no tener otros cargos ni referencias.
    Result = Data.define(:header, :lines, :other_charges, :payment_methods, :references, :others)

    # @param company [Company] dueña del documento; de acá salen `sap_db` y la conexión.
    # @param doc_entry [Integer] consecutivo interno de SAP.
    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param client [Clavisco::ServiceLayer::Client, nil] inyectable para los specs.
    #   Cuando no se pasa, lo arma `Sap::CompanyClient` — que es lo que reutiliza
    #   la sesión entre documentos de la misma compañía.
    def initialize(company:, doc_entry:, doc_type:, client: nil)
      @company   = company
      @doc_entry = doc_entry
      @doc_type  = doc_type
      @client    = client
    end

    # @raise [HeaderNotFound] si la cabecera vino vacía.
    # @return [Result]
    def call
      Result.new(
        header:          fetch_header,
        lines:           fetch_many(LINES),
        other_charges:   fetch_many(OTHER_CHARGES),
        payment_methods: fetch_many(PAYMENT_METHODS),
        references:      fetch_many(REFERENCES),
        others:          fetch_others
      )
    end

    private

    attr_reader :company, :doc_entry, :doc_type

    def client
      @client ||= Sap::CompanyClient.for(company)
    end

    # La cabecera se pide como lista y se toma la primera fila.
    #
    # No es un rodeo: una vista del Service Layer **siempre** devuelve una
    # colección, aunque el `$filter` deje una sola fila (punto 9 de
    # `docs/sync-documents-flow.md`). Tratarla como objeto daría `nil` en todos
    # los campos.
    def fetch_header
      rows = fetch_many(HEADER)

      if rows.empty?
        raise HeaderNotFound,
              "SAP no devolvió cabecera para el documento #{doc_type}/#{doc_entry} " \
              "de #{company.name.inspect} (consulta #{HEADER})."
      end

      if rows.size > 1
        # No corta: la consulta pide un documento puntual, así que más de una fila
        # significa que la vista está mal filtrada. Se avisa y se sigue con la
        # primera, que es lo que el .NET hacía de hecho.
        Rails.logger.warn(
          "[Sap::DocumentDetails] #{HEADER} devolvió #{rows.size} filas para " \
          "#{doc_type}/#{doc_entry}; se usa la primera."
        )
      end

      rows.first
    end

    # El bloque `Otros` es opcional por compañía (punto 8). Cuando está apagado no
    # se consulta: es una vuelta menos al Service Layer por documento, y el
    # resultado no se iba a usar.
    def fetch_others
      return [] unless company.use_additional_fields?

      fetch_many(OTHERS)
    end

    # @return [Array<Documents::Row>]
    def fetch_many(code)
      response = client.get(path_for(code))

      # `Client#get` ya desenvuelve el `{"value": [...]}` de OData. `Array.wrap`
      # cubre los dos bordes que quedan: una respuesta vacía (`nil`) y una vista
      # que devolviera un objeto suelto en vez de una colección.
      Array.wrap(response).map { |row| Documents::Row.new(row) }
    end

    # El `$top` sale del catálogo y no de una constante de esta clase.
    #
    # Sin él, el Service Layer devuelve **20 filas** y corta: un documento de 25
    # líneas se emitiría con 20 y los totales no cuadrarían contra Hacienda. El
    # `page_size` en 0 significa "sin paginación" (`SlResource#paginated?`) y ahí
    # no se agrega nada.
    def path_for(code)
      query = Sap::ResourceQuery.new(code, bindings: { DocEntry: doc_entry, DocType: doc_type })
      query = query.merge('$top' => query.page_size) if query.page_size.to_i.positive?

      query.path
    end
  end
end

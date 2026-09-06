# frozen_string_literal: true

module Sap
  # Búsqueda paginada de documentos emitidos, en vivo contra SAP Service Layer.
  #
  # Consume el catálogo `getDocuments01`..`10` (`db/seeds.rb` sección 5,
  # `SL_RESOURCES_DOCUMENT_QUERIES`): una fila por tipo de comprobante,
  # cada una apuntando a la entidad estándar de SAP que le corresponde
  # (`Invoices`, `CreditNotes`, `PurchaseInvoices`, `IncomingPayments`).
  #
  #   result = Sap::IssuedDocumentsSearch.new(
  #     doc_type: DocType::FE, client: client, page: 1, per_page: 10,
  #     filters: { start_date: '2026-09-01', end_date: '2026-09-05', receptor: 'ACME' }
  #   ).call
  #   result.items    # => [{ 'DocEntry' => 25, 'CardName' => 'ACME S.A.', ... }, ...]
  #   result.has_more # => true/false
  #
  # ── Por qué NO hay `Total` ────────────────────────────────────────────────────
  # El Service Layer nunca devuelve más de 20 filas por respuesta si no se manda
  # el header `Prefer: odata.maxpagesize`, y `Clavisco::ServiceLayer::Client`
  # todavía no lo soporta ni sigue `odata.nextLink` (`TODOS.md` → SAP, "deuda del
  # acceso a Service Layer"). Sin eso no hay forma honesta de saber cuántas filas
  # hay en total. En vez de mentir un total, se pide una fila de más (`per_page +
  # 1`): si vuelve, se recorta y se avisa `has_more: true`; si no, esa es
  # realmente la última página.
  #
  # `MAX_PAGE_SIZE` deja margen bajo el techo real de 20 para que `per_page + 1`
  # nunca choque contra ese límite y el "espiar una fila de más" siga siendo
  # confiable.
  #
  # ── Por qué el tipo de documento decide el objeto de SAP, no un `$filter` ────
  # `Invoices` es compartido por FE/ND/TE/FEE dentro de SAP: lo que distingue un
  # subtipo de otro es la `Series` de numeración, configurada por instalación
  # (varía de un cliente a otro) — por eso NO se hornea en `db/seeds.rb` (que es
  # compartido) sino directamente en el `query_params` de la fila `sl_resources`
  # de esta instalación, vía la pantalla de mantenimiento
  # (`Configurations_SlResources_Update`). Esta clase no conoce la `Series`: solo
  # agrega los filtros que SÍ varían por request (fechas, receptor, etc.) al
  # `$filter` que el catálogo ya trae.
  class IssuedDocumentsSearch
    # El tipo pedido no tiene una fila `getDocuments<tipo>` en el catálogo (no es
    # de los 7 que `DocType` admite para esto, o la fila fue dada de baja).
    class UnsupportedDocType < StandardError; end

    # `start_date`/`end_date` faltan o no tienen forma `AAAA-MM-DD`. A
    # diferencia del resto de los filtros (opcionales), estos dos son
    # OBLIGATORIOS: toda búsqueda filtra por rango de `DocDate`, nunca "todas
    # las fechas" — es la misma restricción que ya traía el `WHERE DocDate >=`
    # fijo de la vista legacy (`view.txt`), pero con el rango a cargo de quien
    # busca en vez de una fecha de corte fija en la consulta.
    class InvalidDateRange < StandardError; end

    MAX_PAGE_SIZE = 19

    Result = Struct.new(:items, :has_more, keyword_init: true)

    # @param doc_type [String] código de Hacienda (`DocType::FE`, …).
    # @param client [Clavisco::ServiceLayer::Client]
    # @param page [Integer] 1-indexado.
    # @param per_page [Integer] se acota a `MAX_PAGE_SIZE`.
    # @param filters [Hash] `:start_date, :end_date` (`AAAA-MM-DD`, OBLIGATORIOS
    #   — filtran `DocDate`) + `:status, :consecutivo, :consecutivo_fe,
    #   :receptor, :cedula, :clave, :codigo_moneda` (opcionales).
    def initialize(doc_type:, client:, page: 1, per_page: 10, filters: {})
      @doc_type = doc_type
      @client   = client
      @page     = [page.to_i, 1].max
      @per_page = per_page.to_i.clamp(1, MAX_PAGE_SIZE)
      @filters  = filters
    end

    def call
      rows = Array.wrap(client.get(query.path))
      has_more = rows.size > per_page

      Result.new(items: rows.first(per_page), has_more: has_more)
    rescue Sap::ResourceQuery::UnknownResource
      raise UnsupportedDocType, "El tipo de documento #{doc_type.inspect} no tiene una consulta " \
                                'configurada (catálogo `getDocuments<tipo>`).'
    end

    private

    attr_reader :doc_type, :client, :page, :per_page, :filters

    def query
      base = Sap::ResourceQuery.new("getDocuments#{doc_type}")
      # El `$filter` de la Series ya viene en el catálogo (por instalación); acá
      # se le suman las condiciones del request con `and`, nunca reemplazándolo.
      combined_filter = [base.params['$filter'], extra_filter].reject(&:blank?).join(' and ')

      extra = { '$top' => per_page + 1, '$skip' => (page - 1) * per_page }
      extra['$filter'] = combined_filter if combined_filter.present?

      base.merge(extra)
    end

    # Arma las condiciones que dependen del request (nunca las del catálogo).
    # `contains` para texto libre, `eq`/`ge`/`le` para exactos y rangos.
    def extra_filter
      [
        date_range,
        text_contains('FederalTaxID', filters[:cedula]),
        text_contains('DocCurrency', filters[:codigo_moneda]),
        text_contains('U_CL_FEC_Clave', filters[:clave]),
        text_contains('CardName', filters[:receptor]),
        text_contains('U_CL_FEC_NumConsecutivo', filters[:consecutivo_fe]),
        numeric_eq('DocNum', filters[:consecutivo]),
        numeric_eq('U_CL_FEC_Status', filters[:status])
      ].compact.join(' and ')
    end

    # Formato exigido a `start_date`/`end_date`: `AAAA-MM-DD`, lo único que
    # manda el `<input type="date">` de la vista. No se acepta nada más ancho
    # para no tener que sanitizar un literal `datetime'...'` con datos libres.
    DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

    # `DocDate` es una fecha NATIVA de SAP (`Edm.DateTime`), a diferencia de
    # `U_CL_FEC_FechaEmision` (`db_Alpha`, texto): el literal OData va con el
    # prefijo `datetime'…'`, comillas simples no alcanzan. Filtra por la fecha
    # del documento en SAP, no por la fecha de emisión ante Hacienda —son datos
    # distintos y el legacy (`view.txt`) también filtraba `DocDate`.
    #
    # Siempre presente: a diferencia de los demás filtros, `start_date`/
    # `end_date` son obligatorios (levanta `InvalidDateRange` si faltan o no
    # tienen el formato esperado) — nunca se busca sin acotar por fecha.
    def date_range
      start_date = filters[:start_date]
      end_date   = filters[:end_date]

      if start_date.blank? || end_date.blank?
        raise InvalidDateRange, 'Debe indicar la fecha de inicio y la fecha final.'
      end

      unless start_date.match?(DATE_FORMAT) && end_date.match?(DATE_FORMAT)
        raise InvalidDateRange, 'La fecha de inicio y la fecha final deben tener el formato AAAA-MM-DD.'
      end

      # `le` con la medianoche del día final excluiría cualquier documento
      # creado más tarde ese mismo día: se completa con el último instante
      # para incluirlo entero.
      "DocDate ge datetime'#{start_date}T00:00:00' and DocDate le datetime'#{end_date}T23:59:59'"
    end

    def text_contains(field, value)
      return nil if value.blank?

      "contains(#{field},#{quote(value)})"
    end

    def numeric_eq(field, value)
      return nil if value.blank?
      return nil unless value.to_s.match?(/\A-?\d+\z/)

      "#{field} eq #{value}"
    end

    # Literal string OData: comillas simples, duplicando las que traiga el
    # valor. Duplica `Clavisco::ServiceLayer::OdataFilter#format_value`, que es
    # `private` en el submódulo — mismo motivo que `Sap::ResourceQuery#odata_literal`
    # (`TODOS.md` → SAP, "`OdataFilter#format_value` es `private`").
    def quote(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end
  end
end

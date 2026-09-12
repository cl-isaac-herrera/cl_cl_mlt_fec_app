# frozen_string_literal: true

module Api
  # Búsqueda de documentos emitidos, en vivo contra SAP Service Layer.
  #
  # Reemplaza `GET /api/documents` del .NET (`DocumentsController#GetDocuments`),
  # que en realidad consultaba la base propia de la app (`spGetDocuments`), no
  # SAP. Acá se decidió lo contrario a propósito: SAP es la fuente de verdad del
  # documento emitido, y la tabla de la app (`DocumentsQueue`, §37) queda para
  # decidir cuándo reintentar, no para este listado. El historial de intentos
  # también vive en SAP, en la UDT `@CL_FEC_DOCSYNCATTMP` (ver `#attempts`).
  #
  # ── Alcance de esta migración ────────────────────────────────────────────────
  # La BÚSQUEDA/listado, la consulta puntual de un documento (`show`, para
  # refrescar el panel de información) y la acción "Reprocesar". El panel
  # "Correos" —listar y reenviar— vive en `Api::Documents::MailsController`, que
  # cuelga de este recurso. El resto de las acciones por fila del legacy
  # (ver/descargar PDF, ver/descargar XML, anulación interna, omitir
  # validaciones, descarga masiva) siguen sin migrar y sin consumidor coherente
  # con esta forma de fila —usaban un `Id` de la base local que ya no existe en
  # un resultado que viene de SAP—. Anotado en `TODOS.md` → Emisión de
  # documentos.
  #
  # `reprocess` SÍ se puede resolver con lo que da SAP (`DocEntry`+`DocType`) más
  # la compañía activa (`SAPDB`): no depende del `Id` local ni de ningún dato que
  # solo tenga el .NET, así que no comparte el bloqueo del resto.
  #
  # ⚠️ Los servicios del namespace `Documents` se nombran con `::` adelante
  # (`::Documents::PendingQueue`, `::Documents::Row`). Desde que existe
  # `Api::Documents` (el controller de correos), un `Documents::X` a secas se
  # resuelve por alcance léxico contra `Api::Documents` —que SÍ existe— y muere
  # con `uninitialized constant Api::Documents::X`, sin seguir buscando en el
  # nivel superior. Vale para cualquier clase bajo `module Api`.
  #
  # ── Por qué no hay `Total` en la respuesta ──────────────────────────────────
  # Ver `Sap::IssuedDocumentsSearch`: el Service Layer no permite pedir más de 20
  # filas por respuesta sin un header que el submódulo no soporta, así que no hay
  # forma honesta de contar el total. Se manda `HasMore` en su lugar.
  class DocumentsController < AuthorizedController
    # El orden importa: primero el permiso (401/403), después los datos del
    # pedido (403 de compañía y 422 de tipo). Un usuario sin permiso no tiene
    # por qué enterarse de si mandó bien los parámetros.
    before_action :authorize_action
    before_action :require_company!
    before_action :require_doc_type!

    MAX_PER_PAGE = Sap::IssuedDocumentsSearch::MAX_PAGE_SIZE
    DEFAULT_PER_PAGE = 10

    PERMISSIONS = {
      'index' => 'Documents_Issued_ViewDocuments',
      'show' => 'Documents_Issued_ViewDocuments',
      'attempts' => 'Documents_Issued_ViewDocuments',
      'reprocess' => 'Documents_Emission_Reprocess'
    }.freeze

    # GET /api/documents?doc_type=01&start_date=&end_date=&status=&consecutivo=
    #                    &consecutivo_fe=&receptor=&cedula=&clave=&codigo_moneda=
    #                    &page=1&per_page=10
    def index
      result = Sap::IssuedDocumentsSearch.new(
        doc_type: doc_type,
        client: Sap::CompanyClient.for(company),
        page: page,
        per_page: per_page,
        filters: filters
      ).call

      render json: ApiResponse.success({ Items: result.items, HasMore: result.has_more }).to_h
    rescue Sap::CompanyClient::MissingConfiguration, Sap::IssuedDocumentsSearch::UnsupportedDocType,
           Sap::IssuedDocumentsSearch::InvalidDateRange => e
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
      render json: ApiResponse.error(e.sap_message || e.message).to_h, status: :bad_gateway
    end

    # GET /api/documents/:id?doc_type=01
    #
    # `:id` es el `DocEntry` de SAP. Trae el `U_CL_FEC_Status`/
    # `U_CL_FEC_ErrorDetails` ACTUALES de un solo documento, en vivo — el panel
    # "Información del documento" del listado (`documents_issued_controller.js`)
    # lo consulta cada vez que se abre, en vez de arrastrar el valor que trajo
    # la búsqueda (`#mapDocument` ya no lo incluye a propósito): esos dos campos
    # los pisa constantemente la sincronización (reprocesos, la verificación de
    # `CheckSentDocumentsJob`), así que el de la última página del listado puede
    # quedar desactualizado frente al estado real del documento.
    #
    # Consulta la ENTIDAD del documento por llave
    # (`getDocumentErrorDetails<tipo>` → `Invoices(25)?$select=U_CL_FEC_Status,
    # U_CL_FEC_ErrorDetails`), una fila del catálogo por tipo de documento.
    #
    # ⚠️ NO usar `qsGetDocumentHeaderInfo` para esto, aunque sea la consulta que
    # ya existe: es una SQL Query view y devuelve sus propios alias (`Status`,
    # `ErrDetails`), no los nombres de los UDFs — pedirle `U_CL_FEC_ErrorDetails`
    # devuelve `nil` y el panel se queda sin mostrar la sección, sin ningún
    # error. Contra la entidad los nombres son los del campo real y el `$select`
    # es confiable; la advertencia sobre `$select` de
    # `CheckSentDocumentsJob#header_for` aplica a las vistas, no a las entidades
    # OData nativas.
    def show
      row = fetch_error_details(doc_type: doc_type, doc_entry: doc_entry)
      if row.to_h.empty?
        render json: ApiResponse.error('SAP no devolvió el documento solicitado.').to_h, status: :not_found
        return
      end

      render json: ApiResponse.success({
                                         Status: row.integer('U_CL_FEC_Status'),
                                         ErrorDetails: row.string('U_CL_FEC_ErrorDetails')
                                       }).to_h
    rescue Clavisco::ServiceLayer::Client::NotFoundError
      # Antes que el rescue de abajo: un `DocEntry` que no existe es un 404 del
      # recurso pedido, no una falla del enlace con SAP (502).
      render json: ApiResponse.error('SAP no devolvió el documento solicitado.').to_h, status: :not_found
    rescue Sap::CompanyClient::MissingConfiguration, Sap::ResourceQuery::UnknownResource => e
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
      render json: ApiResponse.error(e.sap_message || e.message).to_h, status: :bad_gateway
    end

    # GET /api/documents/:id/attempts?doc_type=01
    #
    # `:id` es el `DocEntry` de SAP (ver la nota de la ruta). El historial vive
    # en la UDT `@CL_FEC_DOCSYNCATTMP` de la compañía (`Sap::DocSyncAttempts`),
    # no en la cola propia: ahí quedó solo el estado y el contador de intentos.
    # Antes lo leía `Documents::AttemptDetails` por ODBC, contra una tabla que
    # ya no existe.
    def attempts
      items = Sap::DocSyncAttempts
              .new(client: Sap::CompanyClient.for(company))
              .list(doc_entry: doc_entry, doc_type: doc_type)

      render json: ApiResponse.success({ Items: items.map { |a| serialize_attempt(a) } }).to_h
    rescue Sap::CompanyClient::MissingConfiguration, Sap::ResourceQuery::UnknownResource => e
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
      render json: ApiResponse.error(e.sap_message || e.message).to_h, status: :bad_gateway
    end

    # PATCH /api/documents/:id/reprocess?doc_type=01
    #
    # `:id` es el `DocEntry` de SAP (ver la nota de la ruta). Reencola el
    # documento en la cola propia (§37) para que `SyncIssuedDocumentsJob` lo
    # vuelva a tomar — reemplaza `PATCH /api/Documents/:id/Reprocess` del
    # servidor de sincronización .NET (`ApiFEUrl`).
    #
    # La validación de que el documento esté `Rejected` vive en el SP
    # (`Documents::PendingQueue::REPROCESS_PROCEDURE`), no acá: `reprocess`
    # devuelve `false` tanto si el documento no existe en la cola como si ya no
    # estaba rechazado, y las dos se reportan igual — el llamador no puede
    # actuar distinto en ninguno de los dos casos.
    #
    # Reencolada la fila, el pedido se asienta en SAP (`#record_reprocess_in_sap`):
    # el intento en la UDT del historial y el estado del comprobante. Del estado
    # se manda SOLO `U_CL_FEC_Status` (`Sap::DocumentStatus#update_status_only`)
    # — no los otros seis campos, que siguen describiendo el intento anterior.
    # Es best-effort: si SAP no responde, la cola —la fuente de verdad— ya quedó
    # reencolada, y el próximo desenlace de la sincronización va a corregir el
    # campo de todas formas.
    #
    # ⚠️ Acá SÍ hay una persona detrás del click: el `Client` se arma con
    # `Sap::UserClient` (credenciales de `Current.user`), no con
    # `Sap::CompanyClient` (licencia) — ese queda para procesos de fondo sin
    # usuario, como `SyncIssuedDocumentsJob`.
    def reprocess
      reprocessed = ::Documents::PendingQueue.reprocess(
        sap_db: company.sap_db,
        doc_entry: doc_entry,
        doc_type: doc_type
      )

      unless reprocessed
        render json: ApiResponse.error(
          'El documento no está en estado Rechazado, no se puede reprocesar.'
        ).to_h, status: :unprocessable_content
        return
      end

      record_reprocess_in_sap(doc_type: doc_type, doc_entry: doc_entry)

      render json: ApiResponse.success({ Message: 'Solicitud de reprocesamiento registrada.' }).to_h
    rescue ExternalDb::ConfigurationError => e
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue ExternalDb::Error => e
      render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
    end

    private

    # Las cinco acciones operan sobre un documento de la compañía activa y todas
    # necesitan lo mismo antes de empezar: que la compañía sea del usuario y que
    # el tipo de comprobante sea uno que este producto emite. Vive acá y no
    # repetido en cada acción para que una acción nueva no pueda nacer sin los
    # dos controles — que es justo lo que pasa cuando el guard es copia y pega.
    def require_company!
      return if company

      render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
             status: :forbidden
    end

    # Los tres mensajes de receptor (`05`, `06`, `07`) no son comprobantes
    # emitidos: no los devuelve ninguna de estas consultas, así que pedirlos es
    # un error del llamador y no una búsqueda sin resultados.
    def require_doc_type!
      @doc_type = DocType.normalize(params[:doc_type])
      return if @doc_type && !DocType.receiver_message?(@doc_type)

      render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
             status: :unprocessable_content
    end

    # El tipo ya normalizado por `#require_doc_type!`.
    attr_reader :doc_type

    # `:id` del path. Es el `DocEntry` de SAP, no un id de la base de la app
    # (ver la cabecera de la clase).
    def doc_entry = params[:id].to_i

    def reprocess_details
      "Reprocesamiento solicitado por #{Current.user.name.presence || Current.user.email}"
    end

    # Deja el pedido asentado en SAP: el intento en la UDT del historial
    # (`Sap::DocSyncAttempts`, con quién lo pidió) y el estado del comprobante
    # (`U_CL_FEC_Status` → `Reprocess`).
    #
    # No puede tumbar la respuesta: la cola ya quedó reencolada (lo que de
    # verdad decide si el documento se reprocesa) y esto es solo lo que ve el
    # operador al mirar SAP directamente. Mismo criterio de tolerancia que
    # `SyncIssuedDocumentsJob#mark_sap`.
    #
    # El intento va PRIMERO porque es el que nadie más va a escribir: el estado
    # lo corrige el próximo desenlace de la sincronización, pero "lo pidió tal
    # usuario a tal hora" se pierde para siempre si esta llamada no ocurre.
    #
    # Un solo cliente para las dos escrituras, y `Sap::UserClient` (no
    # `Sap::CompanyClient`) porque acá SÍ hay una persona en sesión ejecutando
    # la acción — ver la nota de `#reprocess`.
    def record_reprocess_in_sap(doc_type:, doc_entry:)
      client = Sap::UserClient.for(company, user: Current.user)

      Sap::DocSyncAttempts.new(client: client).create(
        doc_entry: doc_entry,
        doc_type: doc_type,
        status: ::Documents::PendingQueue::STATUS_REPROCESS,
        details: reprocess_details
      )

      Sap::DocumentStatus.new(client: client, doc_type: doc_type, doc_entry: doc_entry)
                         .update_status_only(::Documents::PendingQueue::STATUS_REPROCESS)
    rescue Sap::UserClient::MissingConfiguration, Sap::ResourceQuery::UnknownResource,
           Clavisco::ServiceLayer::Client::ServiceLayerError => e
      Rails.logger.error(
        "[Api::DocumentsController#reprocess] DocEntry #{doc_entry} DocType #{doc_type.inspect}: " \
        "no se pudo registrar el reprocesamiento en SAP — #{e.message}"
      )
    end

    # La fila COMPLETA de la cabecera para `#show` — mismo criterio que
    # `CheckSentDocumentsJob#header_for` (ver el comentario de `#show`).
    # El documento por llave (`Invoices(25)?$select=U_CL_FEC_Status,…`), una
    # fila del catálogo por tipo (`getDocumentErrorDetails<tipo>`, ver
    # `db/seeds.rb`). Un tipo sin fila levanta `UnknownResource`, que `#show`
    # traduce a 422.
    #
    # Devuelve la entidad, no una colección: el Service Layer contesta el objeto
    # solo, así que no hay `.first` que sacar — y si el `DocEntry` no existe
    # contesta 404, que llega como `NotFoundError`.
    def fetch_error_details(doc_type:, doc_entry:)
      query = Sap::ResourceQuery.new("getDocumentErrorDetails#{doc_type}", bindings: { DocEntry: doc_entry })

      ::Documents::Row.new(Sap::CompanyClient.for(company).get(query.path))
    end

    def serialize_attempt(attempt)
      { CreatedAt: attempt.created_at, StatusCode: attempt.status_code, Details: attempt.details }
    end

    def authorize_action
      require_permission!(PERMISSIONS.fetch(action_name))
    end

    # La compañía activa, validada contra las asignadas al usuario — igual que
    # `Api::CertificateAlarmsController` (§28 regla 5): el id sale de la sesión,
    # nunca de un parámetro, y se confirma que sea una compañía del usuario.
    def company
      @company ||= Company.assigned_to(Current.user.id).find_by(id: Current.company_id)
    end

    def page = [params[:page].to_i, 1].max

    def per_page
      (params[:per_page].presence || DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
    end

    def filters
      params.slice(:start_date, :end_date, :status, :consecutivo, :consecutivo_fe,
                   :receptor, :cedula, :clave, :codigo_moneda).to_unsafe_h.symbolize_keys
    end
  end
end

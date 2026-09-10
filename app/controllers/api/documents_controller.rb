# frozen_string_literal: true

module Api
  # Búsqueda de documentos emitidos, en vivo contra SAP Service Layer.
  #
  # Reemplaza `GET /api/documents` del .NET (`DocumentsController#GetDocuments`),
  # que en realidad consultaba la base propia de la app (`spGetDocuments`), no
  # SAP. Acá se decidió lo contrario a propósito: SAP es la fuente de verdad del
  # documento emitido, y la tabla de la app (`DocumentsQueue`, §37) queda para el
  # historial de reintentos, no para este listado.
  #
  # ── Alcance de esta migración ────────────────────────────────────────────────
  # La BÚSQUEDA/listado, la consulta puntual de un documento (`show`, para
  # refrescar el panel de información) y la acción "Reprocesar". El resto de
  # las acciones por fila del legacy (ver/descargar PDF, ver/descargar XML,
  # reenviar correo, anulación interna, omitir validaciones, descarga masiva)
  # siguen sin migrar y sin consumidor coherente con esta forma de fila —usaban
  # un `Id` de la base local que ya no existe en un resultado que viene de
  # SAP—. Anotado en `TODOS.md` → Emisión de documentos.
  #
  # `reprocess` SÍ se puede resolver con lo que da SAP (`DocEntry`+`DocType`) más
  # la compañía activa (`SAPDB`): no depende del `Id` local ni de ningún dato que
  # solo tenga el .NET, así que no comparte el bloqueo del resto.
  #
  # ── Por qué no hay `Total` en la respuesta ──────────────────────────────────
  # Ver `Sap::IssuedDocumentsSearch`: el Service Layer no permite pedir más de 20
  # filas por respuesta sin un header que el submódulo no soporta, así que no hay
  # forma honesta de contar el total. Se manda `HasMore` en su lugar.
  class DocumentsController < AuthorizedController
    before_action :authorize_action

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
      unless company
        render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
               status: :forbidden
        return
      end

      doc_type = DocType.normalize(params[:doc_type])
      if doc_type.nil? || DocType.receiver_message?(doc_type)
        render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
               status: :unprocessable_content
        return
      end

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
      unless company
        render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
               status: :forbidden
        return
      end

      doc_type = DocType.normalize(params[:doc_type])
      if doc_type.nil? || DocType.receiver_message?(doc_type)
        render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
               status: :unprocessable_content
        return
      end

      row = fetch_error_details(doc_type: doc_type, doc_entry: params[:id].to_i)
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
    # en la cola propia (§37), no en SAP, así que la fuente es
    # `Documents::AttemptDetails` — ODBC, no Service Layer.
    def attempts
      unless company
        render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
               status: :forbidden
        return
      end

      doc_type = DocType.normalize(params[:doc_type])
      if doc_type.nil? || DocType.receiver_message?(doc_type)
        render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
               status: :unprocessable_content
        return
      end

      items = Documents::AttemptDetails.for(sap_db: company.sap_db, doc_entry: params[:id].to_i, doc_type: doc_type)

      render json: ApiResponse.success({ Items: items.map { |a| serialize_attempt(a) } }).to_h
    rescue ExternalDb::ConfigurationError => e
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue ExternalDb::Error => e
      render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
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
    # Reencolada la fila, se marca lo mismo en SAP (igual que hace
    # `SyncIssuedDocumentsJob#mark_sap` con cada desenlace, ver
    # `docs/sync-documents-flow.md`), pero SOLO `U_CL_FEC_Status`
    # (`Sap::DocumentStatus#update_status_only`) — no los otros seis campos,
    # que siguen describiendo el intento anterior. Es best-effort: si SAP no
    # responde, la cola —la fuente de verdad— ya quedó reencolada, y el
    # próximo desenlace de la sincronización va a corregir el campo de todas
    # formas.
    #
    # ⚠️ Acá SÍ hay una persona detrás del click: el `Client` se arma con
    # `Sap::UserClient` (credenciales de `Current.user`), no con
    # `Sap::CompanyClient` (licencia) — ese queda para procesos de fondo sin
    # usuario, como `SyncIssuedDocumentsJob`.
    def reprocess
      unless company
        render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
               status: :forbidden
        return
      end

      doc_type = DocType.normalize(params[:doc_type])
      if doc_type.nil? || DocType.receiver_message?(doc_type)
        render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
               status: :unprocessable_content
        return
      end

      doc_entry = params[:id].to_i

      reprocessed = Documents::PendingQueue.reprocess(
        sap_db: company.sap_db,
        doc_entry: doc_entry,
        doc_type: doc_type,
        details: reprocess_details
      )

      unless reprocessed
        render json: ApiResponse.error(
          'El documento no está en estado Rechazado, no se puede reprocesar.'
        ).to_h, status: :unprocessable_content
        return
      end

      mark_sap_reprocessing(doc_type: doc_type, doc_entry: doc_entry)

      render json: ApiResponse.success({ Message: 'Solicitud de reprocesamiento registrada.' }).to_h
    rescue ExternalDb::ConfigurationError => e
      render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
    rescue ExternalDb::Error => e
      render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
    end

    private

    def reprocess_details
      "Reprocesamiento solicitado por #{Current.user.name.presence || Current.user.email}"
    end

    # No puede tumbar la respuesta: la cola ya quedó reencolada (lo que de
    # verdad decide si el documento se reprocesa) y esto es solo lo que ve el
    # operador al mirar SAP directamente. Mismo criterio de tolerancia que
    # `SyncIssuedDocumentsJob#mark_sap`.
    #
    # `Sap::UserClient` (no `Sap::CompanyClient`) porque acá SÍ hay una persona
    # en sesión ejecutando la acción — ver la nota de `#reprocess`.
    def mark_sap_reprocessing(doc_type:, doc_entry:)
      Sap::DocumentStatus.new(
        client: Sap::UserClient.for(company, user: Current.user),
        doc_type: doc_type,
        doc_entry: doc_entry
      ).update_status_only(Documents::PendingQueue::STATUS_REPROCESS)
    rescue Sap::UserClient::MissingConfiguration, Clavisco::ServiceLayer::Client::ServiceLayerError => e
      Rails.logger.error(
        "[Api::DocumentsController#reprocess] DocEntry #{doc_entry} DocType #{doc_type.inspect}: " \
        "no se pudo actualizar el estado en SAP — #{e.message}"
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

      Documents::Row.new(Sap::CompanyClient.for(company).get(query.path))
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

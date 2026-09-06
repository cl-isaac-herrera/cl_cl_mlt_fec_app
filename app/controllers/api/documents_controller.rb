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
  # Solo la BÚSQUEDA/listado. Las acciones por fila del legacy (ver/descargar
  # PDF, ver/descargar XML, reenviar correo, reprocesar, anulación interna,
  # omitir validaciones, descarga masiva) siguen sin migrar y sin consumidor
  # coherente con esta forma de fila —usaban un `Id` de la base local que ya no
  # existe en un resultado que viene de SAP—. Anotado en `TODOS.md` → Emisión de
  # documentos.
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
      'index' => 'Documents_Issued_ViewDocuments'
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

    private

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

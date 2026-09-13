# frozen_string_literal: true

module Api
  module Documents
    # Los XML archivados de un documento emitido: "Descargar XML comprobante" y
    # "Descargar XML respuesta" del listado (`documents_issued_controller.js`).
    #
    #   GET /api/documents/:document_id/xml_files/sent?doc_type=01
    #   GET /api/documents/:document_id/xml_files/response?doc_type=01
    #
    # Reemplazan `GET /api/Documents/GetXMLDoc?docId=N` y
    # `GET /api/Documents/DownloadDocumentXML?docId=N` del .NET, que devolvían el
    # XML en Base64 dentro de un JSON y esperaban un `Id` de la base local que ya
    # no existe en un listado que viene de SAP (`Api::DocumentsController`).
    #
    # ── El XML no está en SAP: está en Azure ────────────────────────────────────
    # SAP guarda su DIRECCIÓN, en dos UDFs que escribió `Sap::DocumentStatus` al
    # sincronizar el documento — `U_CL_FEC_XmlSentUrl` (el comprobante firmado
    # que se envió) y `U_CL_FEC_XmlResponseUrl` (lo que devolvió Hacienda). Así
    # que bajar uno son dos pasos: resolver la URL contra SAP
    # (`getDocumentXmlUrls<tipo>`) y traer el blob (`::Documents::XmlArchive.fetch`).
    #
    # ── Por qué la URL NO viaja en el pedido, si el listado ya la tiene ─────────
    # Porque una URL que llega del cliente es una URL que el cliente eligió:
    # bastaría cambiarle la carpeta (`<contenedor>/<cédula>/…`) para bajar el XML
    # de otro contribuyente con las credenciales de Azure de la instalación. La
    # URL de la fila decide si la acción se OFRECE; la que se baja se resuelve acá
    # por `DocEntry`, contra la compañía activa del usuario.
    #
    # ── Por qué `xml_files` y no dos acciones del documento ────────────────────
    # Son dos archivos DE este documento, así que cuelgan del documento como
    # recurso anidado (§28), y el `:id` los nombra (`sent`/`response`) en vez de
    # un verbo en el path (`DownloadDocumentXML`). Son dos y no una acción con un
    # parámetro `kind` porque cada uno es un archivo distinto con su propio
    # nombre y su propio momento de existir.
    #
    # El cuerpo es el XML, no un JSON con Base64 adentro: lo que el navegador
    # guarda es un archivo, y `send_data` ya sabe nombrarlo.
    class XmlFilesController < AuthorizedController
      # El orden importa: primero el permiso (401/403), después los datos del
      # pedido. Un usuario sin permiso no tiene por qué enterarse de si mandó
      # bien los parámetros.
      before_action :authorize_action
      before_action :require_company!
      before_action :require_doc_type!
      before_action :require_kind!

      # Bajar el XML es leer el documento: el mismo permiso que el listado y que
      # el panel de información. El .NET no pedía ninguno (`[Authorize]` a secas).
      PERMISSIONS = { 'show' => 'Documents_Issued_ViewDocuments' }.freeze

      # El `:id` de la ruta → el UDF que guarda la URL, y cómo se le nombra al
      # usuario cuando no hay nada que bajar. El motivo dice CUÁNDO va a haberlo
      # (§2): el comprobante se archiva al enviarse, la respuesta al resolverse.
      KINDS = {
        'sent' => {
          field: 'U_CL_FEC_XmlSentUrl',
          missing: 'Este documento todavía no tiene un XML de comprobante archivado: ' \
                   'se guarda cuando el documento se firma y se envía a Hacienda.'
        },
        'response' => {
          field: 'U_CL_FEC_XmlResponseUrl',
          missing: 'Este documento todavía no tiene un XML de respuesta archivado: ' \
                   'se guarda cuando Hacienda lo acepta o lo rechaza.'
        }
      }.freeze

      # Lo que impide siquiera intentar hablar con SAP: la compañía sin conexión
      # configurada o una consulta que no está en el catálogo. Las dos son 422
      # (el pedido no se puede resolver), no 502 (SAP contestó mal).
      SAP_REQUEST_ERRORS = [Sap::CompanyClient::MissingConfiguration,
                            Sap::ResourceQuery::UnknownResource].freeze

      # GET /api/documents/:document_id/xml_files/:id?doc_type=01
      def show
        url = archived_url
        return render json: ApiResponse.not_found(@kind.fetch(:missing)).to_h, status: :not_found if url.blank?

        send_data ::Documents::XmlArchive.fetch(url),
                  filename: ::Documents::XmlArchive.file_name(url) || default_filename,
                  type: 'application/xml',
                  disposition: 'attachment'
      rescue Clavisco::ServiceLayer::Client::NotFoundError
        # Antes que el rescue de abajo: un `DocEntry` que no existe es un 404 del
        # recurso pedido, no una falla del enlace con SAP (502).
        render json: ApiResponse.not_found('SAP no devolvió el documento solicitado.').to_h, status: :not_found
      rescue *SAP_REQUEST_ERRORS => e
        render json: ApiResponse.error(e.message).to_h, status: :unprocessable_content
      rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
        render json: ApiResponse.error(e.sap_message || e.message).to_h, status: :bad_gateway
      rescue Azure::BlobStorage::Error => e
        # Azure sin configurar o rechazando la descarga no es un error de lo que
        # pidió el usuario: es la instalación, y el mensaje lo dice.
        render json: ApiResponse.error(e.message).to_h, status: :bad_gateway
      end

      private

      # La URL que guardó `Sap::DocumentStatus`, leída en vivo del documento.
      # `::Documents::Row` y no `row['…']` porque HANA devuelve los
      # identificadores en MAYÚSCULAS y el mismo catálogo sirve a las dos bases.
      def archived_url
        query = Sap::ResourceQuery.new("getDocumentXmlUrls#{doc_type}", bindings: { DocEntry: doc_entry })
        row   = ::Documents::Row.new(Sap::CompanyClient.for(company).get(query.path))

        row.string(@kind.fetch(:field))
      end

      # Solo si la URL no termina en un segmento con nombre — un blob archivado
      # siempre lo tiene (`<clave>.xml` / `<clave>_respuesta.xml`).
      def default_filename = "#{doc_entry}-#{params[:id]}.xml"

      def require_kind!
        @kind = KINDS[params[:id].to_s]
        return if @kind

        render json: ApiResponse.not_found('El archivo XML solicitado no existe.').to_h, status: :not_found
      end

      def authorize_action
        require_permission!(PERMISSIONS.fetch(action_name))
      end

      def require_company!
        return if company

        render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
               status: :forbidden
      end

      # Los tres mensajes de receptor (`05`, `06`, `07`) no son comprobantes
      # emitidos y no tienen fila en el catálogo.
      def require_doc_type!
        @doc_type = DocType.normalize(params[:doc_type])
        return if @doc_type && !DocType.receiver_message?(@doc_type)

        render json: ApiResponse.error('Debe indicar un tipo de documento válido.').to_h,
               status: :unprocessable_content
      end

      attr_reader :doc_type

      # El `DocEntry` de SAP, no un id de la base de la app (ver la nota de la
      # clase padre del recurso).
      def doc_entry = params[:document_id].to_i

      # La compañía activa, validada contra las asignadas al usuario — el id
      # sale de la sesión, nunca de un parámetro (§28 regla 5).
      def company
        @company ||= Company.assigned_to(Current.user.id).find_by(id: Current.company_id)
      end
    end
  end
end

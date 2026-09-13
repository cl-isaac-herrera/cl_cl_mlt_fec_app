# frozen_string_literal: true

module Documents
  # Guarda en Azure Storage el XML de un comprobante y devuelve su URL, para
  # `U_CL_FEC_XmlSentUrl` / `U_CL_FEC_XmlResponseUrl` (`Sap::DocumentStatus`).
  #
  #   Documents::XmlArchive.store_sent(company: company, clave: clave, xml: signed_xml)
  #   # => "https://miempresa.blob.core.windows.net/appfiles/fec/aaeda6a9-…/xmls/5061….xml"
  #
  # La ruta es `<contenedor>/<workspace>/<uuid de la compañía>/xmls/<archivo>`:
  #
  #   - el CONTENEDOR y el WORKSPACE salen de `settings` (`Azure::BlobStorage
  #     .container`/`.workspace`). El workspace separa este producto de los demás
  #     que comparten la cuenta;
  #   - el UUID DE LA COMPAÑÍA (`companies.uuid`) separa una compañía de otra. Es
  #     el identificador que no cambia nunca: la cédula sí puede corregirse —y
  #     corregirla movería de carpeta a una compañía con documentos ya
  #     archivados, dejando las URLs guardadas en SAP apuntando a un blob que ya
  #     no existe—;
  #   - `xmls/` deja lugar, al lado, a las otras carpetas de la compañía sin
  #     tener que mover nada.
  #
  # El NOMBRE del archivo lo fija Hacienda/el legacy y no cambió: `<clave>.xml`
  # para el firmado que se envía, `<clave>_respuesta.xml` para el que Hacienda
  # devuelve.
  #
  # ⚠️ Esto describe dónde se ESCRIBE de ahora en adelante. Los documentos ya
  # archivados siguen donde están y se siguen leyendo igual: `fetch` saca la ruta
  # de la URL guardada en SAP, no la recompone (ver el comentario del método).
  module XmlArchive
    class Error < StandardError; end

    # La compañía no tiene `uuid`. Lo genera un `before_create`, así que en la
    # práctica solo puede pasar con una fila insertada por fuera del modelo (una
    # importación, SQL directo). Sin él no hay carpeta donde guardar nada — el
    # mismo prerrequisito que `CompanyFiles::Store` exige sobre la cédula (§34).
    class MissingUuid < Error; end

    module_function

    # @param company [Company]
    # @param clave [String] la clave de 50 dígitos del comprobante.
    # @param xml [String] el XML firmado (bytes, no Base64).
    # @return [String] la URL del blob.
    # @raise [MissingUuid, Azure::BlobStorage::MissingConfiguration,
    #   Azure::BlobStorage::TransientError]
    def store_sent(company:, clave:, xml:)
      store(company: company, path: "#{clave}.xml", content: xml)
    end

    # @param company [Company]
    # @param clave [String]
    # @param xml [String] el XML de respuesta que devuelve Hacienda (bytes, ya
    #   decodificado del Base64 con el que viaja `respuesta-xml`).
    # @return [String] la URL del blob.
    #
    # La llama `CheckSentDocumentsJob` cuando `Hacienda::Client#check_status`
    # confirma un desenlace final (`aceptado`/`rechazado`).
    def store_response(company:, clave:, xml:)
      store(company: company, path: "#{clave}_respuesta.xml", content: xml)
    end

    def store(company:, path:, content:)
      Azure::BlobStorage.new.upload(
        container: container,
        path: "#{folder(company)}/#{path}",
        content: content,
        content_type: 'application/xml'
      )
    end
    private_class_method :store

    # `<workspace>/<uuid>/xmls` — la carpeta de los XML de esta compañía.
    def folder(company) = "#{workspace}/#{uuid(company)}/xmls"
    private_class_method :folder

    # Baja de Azure un XML ya archivado, a partir de la URL que guardó
    # `store_sent`/`store_response` (`U_CL_FEC_XmlSentUrl`/`U_CL_FEC_XmlResponseUrl`).
    # Es la única clase que conoce la forma de esas URLs
    # (`https://{cuenta}.blob.core.windows.net/{contenedor}/{cédula}/{archivo}`),
    # así que es la que sabe partirlas de vuelta en `container`/`path` para
    # `Azure::BlobStorage#download`.
    #
    # @param url [String]
    # @return [String] los bytes del XML.
    # @raise [Azure::BlobStorage::MissingConfiguration, Azure::BlobStorage::TransientError,
    #   Azure::BlobStorage::RejectedError]
    def fetch(url)
      # `#path` viene con los segmentos codificados (`blob_uri` los codificó al
      # subir); se decodifican acá porque `Azure::BlobStorage#download` los
      # vuelve a codificar — sin esto, un segmento con caracteres especiales
      # quedaría codificado dos veces.
      container, *segments = URI.parse(url).path.delete_prefix('/').split('/').map { |s| CGI.unescape(s) }

      Azure::BlobStorage.new.download(container: container, path: segments.join('/'))
    end

    # El nombre del blob, tal como quedó guardado en Azure: `<clave>.xml` para el
    # comprobante y `<clave>_respuesta.xml` para la respuesta de Hacienda (los
    # arma `store_sent`/`store_response`).
    #
    # Es lo que `SendElectronicReceiptJob` usa para nombrar los adjuntos del
    # correo, en vez de recomponerlos a mano: el nombre del archivo que recibe
    # quien abre el correo es entonces EL MISMO que el del archivo archivado, y
    # no dos convenciones que se pueden separar sin que nadie lo note.
    #
    # Vive acá por la misma razón que `fetch`: esta es la única clase que conoce
    # la forma de esas URLs.
    #
    # @param url [String]
    # @return [String, nil] `nil` si la URL no termina en un segmento con nombre.
    def file_name(url)
      # `CGI.unescape` por lo mismo que en `fetch`: los segmentos viajan
      # codificados. Sin esto, una clave con caracteres escapados quedaría como
      # adjunto con el `%XX` literal en el nombre.
      name = CGI.unescape(URI.parse(url).path.split('/').last.to_s)

      name.presence
    end

    PURPOSE = 'guardar los XML de Hacienda'

    def container = Azure::BlobStorage.container(purpose: PURPOSE)
    private_class_method :container

    def workspace = Azure::BlobStorage.workspace(purpose: PURPOSE)
    private_class_method :workspace

    # El `uuid` de la compañía, ya validado como segmento de ruta.
    #
    # El formato se comprueba aunque lo genere `SecureRandom.uuid`: la columna es
    # un `string` cualquiera y una compañía importada pudo llegar con otra cosa
    # adentro. Es la misma razón por la que se validaba la cédula.
    def uuid(company)
      uuid = company.uuid.to_s.strip

      raise MissingUuid, "La compañía #{company.name.inspect} no tiene identificador (uuid)." if uuid.blank?
      raise MissingUuid, "El identificador (uuid) de #{company.name.inspect} no es válido." unless
        uuid.match?(Azure::BlobStorage::VALID_SEGMENT)

      uuid
    end
    private_class_method :uuid
  end
end

# frozen_string_literal: true

module Documents
  # Guarda en Azure Storage el XML de un comprobante y devuelve su URL, para
  # `U_CL_FEC_XmlSentUrl` / `U_CL_FEC_XmlResponseUrl` (`Sap::DocumentStatus`).
  #
  #   Documents::XmlArchive.store_sent(company: company, clave: clave, xml: signed_xml)
  #   # => "https://miempresa.blob.core.windows.net/clvsfe/3101822733/5061....xml"
  #
  # El nombre de archivo lo fija Hacienda/el legacy, no una elección de esta
  # clase: `<contenedor>/<cédula>/<clave>.xml` para el firmado que se envía,
  # `<clave>_respuesta.xml` para el que Hacienda devuelve — el contenedor sale
  # del ajuste `AZURE_STORAGE_CONTAINER` (`db/seeds.rb`), sembrado con "clvsfe"
  # igual que el legacy. La cédula (y no `company.id` ni `company.sap_db`) es la carpeta
  # porque es el identificador estable del contribuyente — el mismo criterio
  # que usa `CompanyFiles::Store` para el certificado y el logo (`CLAUDE.md` §34).
  module XmlArchive
    # Mismo patrón que `CompanyFiles::Store::VALID_ID_NUMBER`: solo alfanumérico
    # y guion. Una cédula con `/` cambiaría a qué blob se está escribiendo.
    VALID_ID_NUMBER = /\A[A-Za-z0-9-]+\z/

    class Error < StandardError; end

    # La compañía no tiene cédula todavía. Sin ella no hay carpeta donde
    # guardar nada — el mismo prerrequisito que exige `CompanyFiles::Store`.
    class MissingIdNumber < Error; end

    module_function

    # @param company [Company]
    # @param clave [String] la clave de 50 dígitos del comprobante.
    # @param xml [String] el XML firmado (bytes, no Base64).
    # @return [String] la URL del blob.
    # @raise [MissingIdNumber, Azure::BlobStorage::MissingConfiguration,
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
        path: "#{id_number(company)}/#{path}",
        content: content,
        content_type: 'application/xml'
      )
    end
    private_class_method :store

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

    # "clvsfe", el mismo contenedor que usaba el legacy — es un ajuste (no una
    # constante) para poder corregirlo desde la UI sin deploy si Hacienda
    # alguna vez pidiera otro (`db/seeds.rb` lo reafirma en cada corrida).
    def container
      Setting.group('AZURE_STORAGE').fetch('CONTAINER')
    rescue KeyError
      raise Azure::BlobStorage::MissingConfiguration,
            'Falta el ajuste AZURE_STORAGE_CONTAINER en Configuraciones → Generales, ' \
            'necesario para guardar los XML de Hacienda.'
    end
    private_class_method :container

    def id_number(company)
      id_number = company.issuer_id_number.to_s.strip

      raise MissingIdNumber, "La compañía #{company.name.inspect} no tiene número de identificación." if
        id_number.blank?
      raise MissingIdNumber, "El número de identificación de #{company.name.inspect} no es válido." unless
        id_number.match?(VALID_ID_NUMBER)

      id_number
    end
    private_class_method :id_number
  end
end

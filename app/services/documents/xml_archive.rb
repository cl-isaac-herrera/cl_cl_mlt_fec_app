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
    # ⚠️ Sin llamador todavía: es para cuando exista la pasada que recoge la
    # resolución de Hacienda (`TODOS.md` → Emisión de documentos). Se declara
    # ahora, con el mismo patrón que `#store_sent`, para que esa pasada no
    # tenga que inventar la convención de nombre otra vez.
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

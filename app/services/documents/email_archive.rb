# frozen_string_literal: true

module Documents
  # Guarda en Azure Storage el correo (.eml) completo de un documento de
  # recepción, para `MailReceptionJob`. Mismo patrón que `Documents::XmlArchive`
  # (CLAUDE.md): el contenedor y el workspace salen de `settings`
  # (`Azure::BlobStorage`), y la carpeta es la del UUID de la compañía.
  #
  #   Documents::EmailArchive.store(company: company, clave: clave, eml: raw)
  #   # => "https://miempresa.blob.core.windows.net/appfiles/fec/aaeda6a9-…/reception-emails/5061….eml"
  #
  # `reception-emails/` y no la raíz de la compañía: deja lugar, al lado, a
  # las otras carpetas de la compañía (`xmls/`, la de `Documents::XmlArchive`)
  # sin tener que mover nada.
  module EmailArchive
    class Error < StandardError; end

    # La compañía no tiene `uuid`. Mismo prerrequisito que `Documents::XmlArchive`
    # y `CompanyFiles::Store` (§34): sin él no hay carpeta donde archivar nada.
    class MissingUuid < Error; end

    module_function

    # @param company [Company]
    # @param clave [String] la clave de 50 dígitos del comprobante.
    # @param eml [String] los bytes crudos del correo (RFC822).
    # @return [String] la URL del blob.
    # @raise [MissingUuid, Azure::BlobStorage::MissingConfiguration,
    #   Azure::BlobStorage::TransientError, Azure::BlobStorage::RejectedError]
    def store(company:, clave:, eml:)
      Azure::BlobStorage.new.upload(
        container: container,
        path: "#{folder(company)}/#{clave}.eml",
        content: eml,
        content_type: 'message/rfc822'
      )
    end

    # `<workspace>/<uuid>/reception-emails` — la carpeta de los correos de
    # recepción de esta compañía.
    def folder(company) = "#{workspace}/#{uuid(company)}/reception-emails"
    private_class_method :folder

    PURPOSE = 'guardar los correos de recepción electrónica'

    def container = Azure::BlobStorage.container(purpose: PURPOSE)
    private_class_method :container

    def workspace = Azure::BlobStorage.workspace(purpose: PURPOSE)
    private_class_method :workspace

    # El `uuid` de la compañía, ya validado como segmento de ruta — mismo
    # criterio que `Documents::XmlArchive.uuid`.
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

# frozen_string_literal: true

module Hacienda
  # Arma el `Hacienda::XmlSigner` de una compañía con su certificado digital.
  #
  #   signer = Hacienda::CompanySigner.for(company)
  #
  # Es el equivalente de `Sap::CompanyClient.for` para la firma: el único lugar
  # que sabe de dónde sale el certificado de una compañía y qué decir cuando
  # falta. Y por el mismo motivo se llama una vez por compañía y no una por
  # documento — abrir el `.p12` descifra la llave privada, que es trabajo de
  # criptografía real y no algo para repetir por cada comprobante.
  module CompanySigner
    # Falta el certificado o su PIN, o el archivo ya no está en el disco. No es
    # una falla de la firma: no se llegó a intentar. La arregla quien administra
    # la compañía, así que el mensaje nombra qué cargar y dónde.
    class MissingCertificate < StandardError; end

    module_function

    # @param company [Company]
    # @raise [MissingCertificate] si no hay con qué firmar.
    # @raise [OpenSSL::PKCS12::PKCS12Error] si el PIN no abre el certificado.
    # @return [Hacienda::XmlSigner]
    def for(company)
      if company.cert_path.blank?
        raise MissingCertificate,
              "#{label(company)} no tiene certificado digital cargado. " \
              'Cárguelo en la sección Hacienda (ATV) de la compañía.'
      end

      raise MissingCertificate, "#{label(company)} no tiene el PIN del certificado digital." if
        company.cert_pin.blank?

      # El certificado vive en el disco del servidor (`CLAUDE.md` §34) y la
      # columna guarda su ruta absoluta, así que puede quedar apuntando a un
      # archivo que se movió o que era del servidor .NET. Se avisa con la ruta:
      # sin ella, `Errno::ENOENT` no dice qué compañía ni qué archivo.
      unless File.exist?(company.cert_path)
        raise MissingCertificate,
              "El certificado digital de #{label(company).downcase} no está en el disco " \
              "(#{company.cert_path}). Vuelva a cargarlo en la compañía."
      end

      XmlSigner.new(company.cert_path, company.cert_pin)
    end

    # Lleva el id porque dos compañías pueden llamarse parecido y este mensaje
    # se lee para saber cuál hay que arreglar.
    def label(company)
      "La compañía #{company.name.inspect} (id #{company.id})"
    end
  end
end

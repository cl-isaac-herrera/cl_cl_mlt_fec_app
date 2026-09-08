# frozen_string_literal: true

module Documents
  # Arma `[to, cc]` para el correo de recepción electrónica a partir de la
  # cabecera del documento (`Sap::DocumentDetails::HEADER`) y la compañía.
  #
  # Extraído de `CheckSentDocumentsJob#recipients` porque `SyncIssuedDocumentsJob`
  # necesita EXACTAMENTE la misma lógica para crear la fila de la UDT
  # (`Sap::MailQueue#create`) tan pronto Hacienda recibe el documento — antes,
  # solo `CheckSentDocumentsJob` la calculaba, y solo al resolverse.
  #
  #   to, cc = Documents::MailRecipients.for(header: header, company: company)
  module MailRecipients
    module_function

    # `To` es la posición 0 de `RcprCorreoElectronico` (partido por `;`); el
    # resto de esa lista, más `company.email_cc` (partido por el mismo
    # caracter), va en `Cc`.
    #
    # @return [Array(String, nil), Array(nil, nil)] `[to, cc]`, o `[nil, nil]`
    #   sin destinatario configurado en SAP — no es un error, es un documento
    #   sin correo configurado.
    def for(header:, company:)
      addresses = split_emails(header.string('RcprCorreoElectronico'))
      return [nil, nil] if addresses.empty?

      to = addresses[0]
      cc = (addresses[1..] + split_emails(company.email_cc)).join(';').presence

      [to, cc]
    end

    def split_emails(raw)
      return [] if raw.blank?

      raw.split(';').map(&:strip).reject(&:blank?)
    end
  end
end

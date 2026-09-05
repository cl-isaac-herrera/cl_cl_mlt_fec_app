# frozen_string_literal: true

module Hacienda
  # Firma un comprobante electrónico con XAdES-EPES (enveloped), como exige el
  # Ministerio de Hacienda de Costa Rica (política DGT-R-48-2016).
  #
  #   signer   = Hacienda::XmlSigner.new(company.cert_path, company.cert_pin)
  #   b64_xml  = signer.sign(xml_sin_firmar)   # => Base64 del XML YA FIRMADO
  #
  # Portado casi literal desde `xml_signer_rails` (prototipo aparte, sin
  # dependencias de Rails). No usa la gema `signer` — todo con `openssl` +
  # `nokogiri` puros, que es lo único que necesita.
  #
  # ── Por qué existe esta clase y no se reutiliza algo del legacy ────────────
  # El .NET firmaba con `FirmaXadesNet`. Acá se reconstruye la misma firma a
  # mano porque no hay equivalente Ruby de esa librería; el prototipo ya la
  # validó contra el proceso C# (mismo DN del emisor en formato RFC 2253, mismo
  # digest SHA-256, misma política) y quedó documentado en su README.
  #
  # ── El orden de las 8 operaciones de `#sign` NO es arbitrario ──────────────
  # Cada paso está comentado en el cuerpo del método porque un reordenamiento
  # que parezca inocuo puede introducir drift de canonicalización: el digest
  # del documento se calcula sobre los BYTES REALES que quedaron serializados
  # una sola vez (`intermediate_xml`), no sobre una reserialización posterior —
  # es exactamente lo que Hacienda recalcula al validar, y por eso el
  # documento se auto-verifica antes de devolver algo (paso 8).
  #
  # ── Lo que NO hace ──────────────────────────────────────────────────────────
  # Solo firma. No valida el documento contra el XSD de negocio (eso es
  # `Hacienda::InvoiceValidator`), no habla con los web services de Hacienda
  # (token/envío/consulta — ver los ajustes `HACIENDA_FE_URI_*` de `settings`,
  # todavía sin cliente que los use) y no incluye la cadena de certificación:
  # solo el certificado hoja en `KeyInfo/X509Data`. Si Hacienda llegara a
  # exigir la cadena completa, se agrega con `pkcs12.ca_certs`. Anotado en
  # `TODOS.md` → Emisión de documentos.
  class XmlSigner
    # La URL y el SHA-1 (Base64) del documento de política DGT-R-48-2016 salen
    # de `settings` (`HACIENDA_XADES_POLICY_IDENTIFIER` / `_POLICY_HASH`), no de
    # una constante: no son secretos ni varían por cliente —es la MISMA política
    # para todas las instalaciones—, pero si Hacienda la actualiza hace falta
    # poder corregirla desde la UI sin esperar un deploy. El valor VIGENTE sigue
    # viviendo en código: `db/seeds.rb` lo reafirma en cada corrida (a
    # diferencia del resto de `settings`, ver el encabezado de esa sección) y un
    # cambio manual desde la UI es solo un parche de emergencia que el próximo
    # `db:seeds` revierte. Ver `#policy_identifier` / `#policy_hash`.
    #
    # El hash usa SHA-1 y no SHA-256 — es el único punto de toda la firma que lo
    # hace; así lo exige el perfil XAdES-EPES y así lo emitía `FirmaXadesNet`.

    NS_DSIG     = 'http://www.w3.org/2000/09/xmldsig#'
    NS_XADES    = 'http://uri.etsi.org/01903/v1.3.2#'
    ALG_C14N    = 'http://www.w3.org/2001/10/xml-exc-c14n#'
    ALG_ENV     = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature'
    ALG_RSA256  = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256'
    ALG_SHA256  = 'http://www.w3.org/2001/04/xmlenc#sha256'
    ALG_SHA1    = 'http://www.w3.org/2000/09/xmldsig#sha1'
    TYPE_SPROPS = 'http://uri.etsi.org/01903#SignedProperties'

    # Se lanza cuando la auto-verificación del paso 8 detecta una firma que
    # Hacienda rechazaría. Nunca debería salir de un `.p12` válido: es la red
    # de seguridad para no devolver nunca un comprobante mal firmado.
    class VerificationError < StandardError; end

    # @param cert_path [String] ruta al `.p12`/`.pfx` en disco (`company.cert_path`).
    # @param cert_password [String] PIN del certificado, en claro
    #   (`company.cert_pin`, que `Company#encrypts` ya descifra al leerlo).
    # @raise [OpenSSL::PKCS12::PKCS12Error] si el PIN no abre el certificado.
    def initialize(cert_path, cert_password)
      pkcs12 = OpenSSL::PKCS12.new(File.binread(cert_path), cert_password)
      @cert  = pkcs12.certificate
      @key   = pkcs12.key
    end

    # @param xml_input [String, IO] el XML del comprobante, YA VALIDADO contra
    #   el XSD de negocio (`Hacienda::InvoiceValidator`) y sin firmar.
    # @return [String] Base64 (strict, sin saltos de línea) del XML firmado —
    #   es literalmente el `comprobanteXml` que espera el envío a Hacienda.
    # @raise [Nokogiri::XML::SyntaxError] si el XML de entrada no es válido.
    # @raise [VerificationError] si la auto-verificación final falla.
    def sign(xml_input)
      xml_string = xml_input.respond_to?(:read) ? xml_input.read : xml_input

      original_doc = Nokogiri::XML(xml_string) { |cfg| cfg.strict }
      original_doc.encoding = 'UTF-8'

      sig_id          = "xmldsig-#{SecureRandom.uuid}"
      signed_props_id = "#{sig_id}-signedprops"
      sig_value_id    = "#{sig_id}-sigvalue"
      object_id       = "#{sig_id}-object0"
      key_info_id     = "#{sig_id}-keyinfo"
      doc_ref_id      = "#{sig_id}-ref0"
      ki_ref_id       = "#{sig_id}-ref1"
      sp_ref_id       = "#{sig_id}-ref2"

      signing_time = Time.now.utc.iso8601
      cert_digest  = sha256_b64(@cert.to_der)
      issuer_dn    = x509_issuer_dn(@cert)
      serial       = @cert.serial.to_s
      cert_b64     = Base64.strict_encode64(@cert.to_der)

      # Paso 1 — arma el esqueleto con el digest del documento en blanco. El
      # digest real se calcula más abajo sobre los bytes que de verdad quedan
      # serializados (paso 3), no sobre este esqueleto.
      sig_xml = build_signature_skeleton(
        sig_id, signed_props_id, sig_value_id, object_id, key_info_id,
        doc_ref_id, ki_ref_id, sp_ref_id,
        signing_time, cert_digest, cert_b64, issuer_dn, serial,
        '' # doc_digest en blanco, se parcha en el paso 4
      )
      sig_doc = Nokogiri::XML(sig_xml)

      # Paso 2 — adjunta el esqueleto al documento y serializa UNA sola vez.
      original_doc.root.add_child(sig_doc.root)
      intermediate_xml = original_doc.to_xml(encoding: 'UTF-8')

      # Paso 3 — el digest del documento se calcula EXACTAMENTE como lo va a
      # recalcular Hacienda: reparsear esos bytes, quitar `<ds:Signature>` y
      # canonicalizar (exc-c14n) el resto. Reparsear en vez de reusar
      # `original_doc` es lo que evita el drift de un round-trip distinto.
      digest_doc = Nokogiri::XML(intermediate_xml)
      digest_doc.at_xpath('//ds:Signature', 'ds' => NS_DSIG).remove
      doc_digest = sha256_b64(
        digest_doc.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
      )

      # Paso 4 — el parche va sobre `original_doc` (el que sigue vivo en
      # memoria), no sobre `digest_doc`: todo lo que sigue queda DENTRO de
      # `<ds:Signature>`, así que quitarla después para verificar da los
      # mismos bytes canónicos.
      sig_in_doc = original_doc.at_xpath('//ds:Signature', 'ds' => NS_DSIG)
      sig_in_doc.at_xpath(
        "ds:SignedInfo/ds:Reference[@URI='']/ds:DigestValue", 'ds' => NS_DSIG
      ).content = doc_digest

      # Paso 5 — digest de KeyInfo.
      ki_node   = sig_in_doc.at_xpath('ds:KeyInfo', 'ds' => NS_DSIG)
      ki_digest = sha256_b64(ki_node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0))
      sig_in_doc.at_xpath(
        "ds:SignedInfo/ds:Reference[@URI='##{key_info_id}']/ds:DigestValue", 'ds' => NS_DSIG
      ).content = ki_digest

      # Paso 6 — digest de SignedProperties.
      sp_node   = sig_in_doc.at_xpath('.//xades:SignedProperties', 'xades' => NS_XADES)
      sp_digest = sha256_b64(sp_node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0))
      sig_in_doc.at_xpath(
        "ds:SignedInfo/ds:Reference[@URI='##{signed_props_id}']/ds:DigestValue", 'ds' => NS_DSIG
      ).content = sp_digest

      # Paso 7 — firma `SignedInfo` canonicalizado con RSA-SHA256.
      si_node = sig_in_doc.at_xpath('ds:SignedInfo', 'ds' => NS_DSIG)
      si_c14n = si_node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
      sig_val = Base64.strict_encode64(@key.sign(OpenSSL::Digest.new('SHA256'), si_c14n))
      sig_in_doc.at_xpath('ds:SignatureValue', 'ds' => NS_DSIG).content = sig_val

      # Paso 8 — se auto-verifica ANTES de devolver nada: mejor que la firma
      # falle acá que en la validación real de Hacienda.
      signed_xml = original_doc.to_xml(encoding: 'UTF-8')
      verify_signature!(signed_xml)

      Base64.strict_encode64(signed_xml)
    end

    private

    def sha256_b64(data)
      Base64.strict_encode64(OpenSSL::Digest.digest('SHA256', data))
    end

    # Ver el comentario junto a la clase: `db/seeds.rb` reafirma este valor en
    # cada corrida, así que en una instalación seedeada siempre hay uno.
    def policy_identifier
      Setting.value_for('HACIENDA_XADES_POLICY_IDENTIFIER')
    end

    def policy_hash
      Setting.value_for('HACIENDA_XADES_POLICY_HASH')
    end

    # DN del emisor en formato RFC 2253 — es el mismo formato que emitía
    # `FirmaXadesNet` en el .NET, así que la firma es bit-compatible con el
    # proceso legacy en este punto.
    def x509_issuer_dn(cert)
      cert.issuer.to_s(OpenSSL::X509::Name::RFC2253)
    end

    # Repite los cuatro chequeos criptográficos que hará el validador de
    # Hacienda. No es una verificación superficial de forma: recalcula cada
    # digest y revalida la firma RSA contra el certificado.
    def verify_signature!(signed_xml_string)
      doc = Nokogiri::XML(signed_xml_string)
      sig = doc.at_xpath('//ds:Signature', 'ds' => NS_DSIG)
      raise VerificationError, '<ds:Signature> no encontrada' unless sig

      verify_document_digest!(signed_xml_string, sig)
      verify_reference_digest!(sig, 'ds:KeyInfo', 'digest de KeyInfo no coincide')
      verify_reference_digest!(sig, './/xades:SignedProperties', 'digest de SignedProperties no coincide',
                                namespace: 'xades', ns_uri: NS_XADES)
      verify_signature_value!(sig)

      true
    end

    def verify_document_digest!(signed_xml_string, sig)
      doc_no_sig = Nokogiri::XML(signed_xml_string)
      doc_no_sig.at_xpath('//ds:Signature', 'ds' => NS_DSIG).remove
      computed = sha256_b64(doc_no_sig.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0))
      declared = sig.at_xpath("ds:SignedInfo/ds:Reference[@URI='']/ds:DigestValue", 'ds' => NS_DSIG)
                    .text.strip

      raise VerificationError, 'digest del documento no coincide' if computed != declared
    end

    def verify_reference_digest!(sig, node_xpath, error_message, namespace: 'ds', ns_uri: NS_DSIG)
      node = sig.at_xpath(node_xpath, namespace => ns_uri)
      ref_id = node['Id']
      computed = sha256_b64(node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0))
      declared = sig.at_xpath(
        "ds:SignedInfo/ds:Reference[@URI='##{ref_id}']/ds:DigestValue", 'ds' => NS_DSIG
      ).text.strip

      raise VerificationError, error_message if computed != declared
    end

    def verify_signature_value!(sig)
      si_node = sig.at_xpath('ds:SignedInfo', 'ds' => NS_DSIG)
      si_c14n = si_node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
      sig_val_bytes = Base64.strict_decode64(
        sig.at_xpath('ds:SignatureValue', 'ds' => NS_DSIG).text.strip.gsub(/\s+/, '')
      )

      return if @cert.public_key.verify(OpenSSL::Digest.new('SHA256'), sig_val_bytes, si_c14n)

      raise VerificationError, 'SignatureValue no valida contra SignedInfo'
    end

    # Los dos namespaces (`ds`, `xades`) van en la RAÍZ de `<ds:Signature>`
    # para que la canonicalización exclusiva de los nodos hijos los herede
    # correctamente. Los `DigestValue` de KeyInfo/SignedProperties/
    # SignatureValue quedan vacíos: se parchan una vez calculados.
    def build_signature_skeleton(
      sig_id, sp_id, sv_id, obj_id, ki_id,
      doc_ref_id, ki_ref_id, sp_ref_id,
      time, cert_digest, cert_b64, issuer, serial,
      doc_digest
    )
      <<~XML
        <ds:Signature xmlns:ds="#{NS_DSIG}" xmlns:xades="#{NS_XADES}" Id="#{sig_id}">
          <ds:SignedInfo>
            <ds:CanonicalizationMethod Algorithm="#{ALG_C14N}"/>
            <ds:SignatureMethod Algorithm="#{ALG_RSA256}"/>
            <ds:Reference Id="#{doc_ref_id}" URI="">
              <ds:Transforms>
                <ds:Transform Algorithm="#{ALG_ENV}"/>
                <ds:Transform Algorithm="#{ALG_C14N}"/>
              </ds:Transforms>
              <ds:DigestMethod Algorithm="#{ALG_SHA256}"/>
              <ds:DigestValue>#{doc_digest}</ds:DigestValue>
            </ds:Reference>
            <ds:Reference Id="#{ki_ref_id}" URI="##{ki_id}">
              <ds:Transforms>
                <ds:Transform Algorithm="#{ALG_C14N}"/>
              </ds:Transforms>
              <ds:DigestMethod Algorithm="#{ALG_SHA256}"/>
              <ds:DigestValue></ds:DigestValue>
            </ds:Reference>
            <ds:Reference Id="#{sp_ref_id}" URI="##{sp_id}" Type="#{TYPE_SPROPS}">
              <ds:Transforms>
                <ds:Transform Algorithm="#{ALG_C14N}"/>
              </ds:Transforms>
              <ds:DigestMethod Algorithm="#{ALG_SHA256}"/>
              <ds:DigestValue></ds:DigestValue>
            </ds:Reference>
          </ds:SignedInfo>
          <ds:SignatureValue Id="#{sv_id}"></ds:SignatureValue>
          <ds:KeyInfo Id="#{ki_id}">
            <ds:X509Data>
              <ds:X509Certificate>#{cert_b64}</ds:X509Certificate>
            </ds:X509Data>
          </ds:KeyInfo>
          <ds:Object Id="#{obj_id}">
            <xades:QualifyingProperties Target="##{sig_id}">
              <xades:SignedProperties Id="#{sp_id}">
                <xades:SignedSignatureProperties>
                  <xades:SigningTime>#{time}</xades:SigningTime>
                  <xades:SigningCertificate>
                    <xades:Cert>
                      <xades:CertDigest>
                        <ds:DigestMethod Algorithm="#{ALG_SHA256}"/>
                        <ds:DigestValue>#{cert_digest}</ds:DigestValue>
                      </xades:CertDigest>
                      <xades:IssuerSerial>
                        <ds:X509IssuerName>#{issuer}</ds:X509IssuerName>
                        <ds:X509SerialNumber>#{serial}</ds:X509SerialNumber>
                      </xades:IssuerSerial>
                    </xades:Cert>
                  </xades:SigningCertificate>
                  <xades:SignaturePolicyIdentifier>
                    <xades:SignaturePolicyId>
                      <xades:SigPolicyId>
                        <xades:Identifier>#{policy_identifier}</xades:Identifier>
                      </xades:SigPolicyId>
                      <xades:SigPolicyHash>
                        <ds:DigestMethod Algorithm="#{ALG_SHA1}"/>
                        <ds:DigestValue>#{policy_hash}</ds:DigestValue>
                      </xades:SigPolicyHash>
                    </xades:SignaturePolicyId>
                  </xades:SignaturePolicyIdentifier>
                </xades:SignedSignatureProperties>
                <xades:SignedDataObjectProperties>
                  <xades:DataObjectFormat ObjectReference="##{doc_ref_id}">
                    <xades:Description>Comprobante Electrónico</xades:Description>
                    <xades:MimeType>text/xml</xades:MimeType>
                    <xades:Encoding>UTF-8</xades:Encoding>
                  </xades:DataObjectFormat>
                </xades:SignedDataObjectProperties>
              </xades:SignedProperties>
            </xades:QualifyingProperties>
          </ds:Object>
        </ds:Signature>
      XML
    end
  end
end

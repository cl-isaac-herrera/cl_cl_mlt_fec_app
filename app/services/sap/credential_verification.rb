# frozen_string_literal: true

module Sap
  # Recuerda, entre la prueba y el guardado, qué credenciales de SAP pasaron la
  # prueba contra el Service Layer.
  #
  # La pantalla prueba los valores del FORMULARIO (`POST /api/sap_credential_validations`)
  # y los guarda en otra petición (`PATCH /api/profile`). El guardado no puede
  # creerle al cliente un "ya las probé": cualquiera mandaría `true`. Por eso la
  # prueba exitosa deja en la sesión una huella de lo probado, y el guardado marca
  # `users.sap_credentials_verified` solo si lo que se guarda coincide con esa huella.
  #
  # La huella es un HMAC con una llave del servidor, no la contraseña: la cookie de
  # sesión va cifrada, pero no hay motivo para que la contraseña viaje en ella.
  # Se guarda una sola verificación a la vez, y vence sola.
  module CredentialVerification
    SESSION_KEY = :sap_credential_verification
    TTL         = 15.minutes

    module_function

    def remember(session, user:, sap_user:, sap_password:)
      session[SESSION_KEY] = {
        'uid' => user.id,
        'fp'  => fingerprint(sap_user, sap_password),
        'exp' => TTL.from_now.to_i
      }
    end

    def forget(session)
      session.delete(SESSION_KEY)
    end

    # @return [Boolean] true si esas credenciales, de ese usuario, pasaron la
    #   prueba hace menos de `TTL`.
    def confirmed?(session, user:, sap_user:, sap_password:)
      entry = session[SESSION_KEY]
      return false unless entry.is_a?(Hash)
      return false unless entry['uid'] == user.id && entry['exp'].to_i > Time.current.to_i

      ActiveSupport::SecurityUtils.secure_compare(entry['fp'].to_s, fingerprint(sap_user, sap_password))
    end

    # `to_json` y no un `join`: cualquier separador puede aparecer dentro de una
    # contraseña (mismo criterio que `#licenseFingerprint` en el JS).
    def fingerprint(sap_user, sap_password)
      OpenSSL::HMAC.hexdigest('SHA256', key, [sap_user.to_s.strip, sap_password.to_s].to_json)
    end

    def key
      Rails.application.key_generator.generate_key('sap_credential_verification', 32)
    end
  end
end

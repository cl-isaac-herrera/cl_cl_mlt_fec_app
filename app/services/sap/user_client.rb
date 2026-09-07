# frozen_string_literal: true

module Sap
  # Arma el `Clavisco::ServiceLayer::Client` de una compañía para las acciones
  # que SÍ tienen una persona detrás — a diferencia de `Sap::CompanyClient`
  # (credenciales de LICENCIA, para los procesos de fondo que no tienen
  # `Current.user`, como `SyncIssuedDocumentsJob`), acá las credenciales son
  # las del usuario en sesión (`users.sap_user`/`sap_password`, CLAUDE.md §29).
  #
  #   client = Sap::UserClient.for(company, user: Current.user)
  #   client.patch(Sap::ResourceQuery.path_for('updateDocument01', DocumentEntry: 25), body: {...})
  #
  # ── Por qué NO reutiliza `Sap::CompanyClient` ────────────────────────────────
  # Usar la licencia acá le mentiría a SAP sobre quién hizo el cambio: la acción
  # (ej. `Api::DocumentsController#reprocess`) la disparó una persona concreta
  # con su propio botón, y el historial de SAP debería poder atribuírsela a
  # ella y no al usuario técnico de la sincronización de fondo.
  #
  # ── La sesión se comparte por USUARIO, no por request ───────────────────────
  # `session_owner_id` es el id del usuario (estable entre requests), así que el
  # pool del Client reutiliza el `/Login` entre las acciones de la MISMA persona
  # sobre la MISMA compañía — misma regla de CLAVISCO-PLATFORM-STANDARDS §2.7
  # ("nunca crear sesiones SAP por request") que `Sap::CompanyClient`, solo que
  # acá la llave del pool es la persona y no el producto.
  module UserClient
    # Falta configuración para poder hablar con SAP en nombre de esta persona.
    # No es un error de SAP: no se llegó a intentar.
    class MissingConfiguration < StandardError; end

    module_function

    # @param company [Company]
    # @param user [User] quien ejecuta la acción — SIEMPRE `Current.user`,
    #   nunca un id que viaje en el request.
    # @raise [MissingConfiguration] si falta la conexión, la base o las
    #   credenciales personales de SAP del usuario.
    # @return [Clavisco::ServiceLayer::Client]
    def for(company, user:)
      connection = company.sap_connection

      raise MissingConfiguration, "#{label(company)} no tiene una conexión de SAP asignada." if connection.nil?

      if connection.sl_url.blank?
        raise MissingConfiguration,
              "La conexión #{connection.name.inspect} de #{label(company)} no tiene URL de Service Layer."
      end

      raise MissingConfiguration, "#{label(company)} no tiene base de datos de SAP (sap_db)." if company.sap_db.blank?

      unless user.sap_user.present? && user.sap_password.present?
        raise MissingConfiguration,
              "El usuario #{user.email.inspect} no tiene credenciales de SAP configuradas en su perfil."
      end

      Clavisco::ServiceLayer::Client.new(
        base_url:         connection.sl_url,
        company_db:       company.sap_db,
        username:         user.sap_user,
        password:         user.sap_password,
        session_owner_id: "user:#{user.id}"
      )
    end

    # Identificación de la compañía para los mensajes de error. Lleva el id
    # porque dos compañías pueden llamarse parecido y el log tiene que ser
    # accionable — mismo criterio que `Sap::CompanyClient.label`.
    def label(company)
      "La compañía #{company.name.inspect} (id #{company.id})"
    end
  end
end

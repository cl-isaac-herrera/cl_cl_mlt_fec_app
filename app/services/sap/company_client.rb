# frozen_string_literal: true

module Sap
  # Arma el `Clavisco::ServiceLayer::Client` de una compañía para los procesos
  # que corren SIN una persona en sesión.
  #
  # Es el único lugar del producto que sabe de dónde salen las credenciales de un
  # proceso de fondo. Cuando exista la tabla `sap_licenses` del estándar §8
  # (`TODOS.md` → SAP), se cambia acá y nada más.
  #
  #   client = Sap::CompanyClient.for(company)
  #   client.get(Sap::ResourceQuery.path_for('qsGetDocumentHeaderInfo', DocEntry: 25, DocType: '01'))
  #
  # ── Por qué NO usa `users.sap_user` ──────────────────────────────────────────
  # Esas credenciales son de una persona y se resuelven con `Current.user`, que en
  # un job es `nil`. Ver la migración `20260825140000_add_sap_license_to_connections.rb`.
  #
  # ── La sesión se comparte a propósito ────────────────────────────────────────
  # `session_owner_id` es una constante y no un UUID por llamada: el pool del
  # Client indexa por `owner|company_db|username`, así que con un owner fijo TODOS
  # los documentos de una misma compañía reutilizan un solo `/Login`. Eso es
  # exactamente lo que pide CLAVISCO-PLATFORM-STANDARDS §2.7 («nunca crear
  # sesiones SAP por request») y lo que evita gastar una licencia de SAP por
  # documento.
  #
  # Compañías distintas siguen teniendo sesiones distintas aunque compartan
  # servidor, porque `company_db` es parte de la llave.
  #
  # ⚠️ Es la diferencia con `Sap::CredentialValidator`, que usa un owner único por
  # intento *y* cierra la sesión: ahí reutilizar sería un defecto (haría pasar
  # cualquier contraseña). Acá reutilizar es el objetivo. Por lo mismo, **no se
  # llama `logout`** al terminar.
  module CompanyClient
    # Falta configuración para poder hablar con SAP. No es un error de SAP: no se
    # llegó a intentar.
    class MissingConfiguration < StandardError; end

    # Dueño de las sesiones de la sincronización de emitidos. Un nombre estable y
    # legible, para que una sesión colgada en el pool se pueda atribuir.
    SESSION_OWNER_ID = 'fe-sync'

    module_function

    # @param company [Company]
    # @param session_owner_id [String] dueño de la sesión en el pool del Client.
    # @raise [MissingConfiguration] si falta la conexión, la base o la licencia.
    # @return [Clavisco::ServiceLayer::Client]
    def for(company, session_owner_id: SESSION_OWNER_ID)
      connection = company.sap_connection

      # Se valida todo junto y nombrando la compañía: este error lo va a leer
      # alguien revisando por qué una compañía no emitió, y "falta la conexión"
      # sin decir de cuál no le sirve de nada.
      raise MissingConfiguration, "#{label(company)} no tiene una conexión de SAP asignada." if connection.nil?

      if connection.sl_url.blank?
        raise MissingConfiguration,
              "La conexión #{connection.name.inspect} de #{label(company)} no tiene URL de Service Layer."
      end

      raise MissingConfiguration, "#{label(company)} no tiene base de datos de SAP (sap_db)." if company.sap_db.blank?

      unless connection.sap_license?
        raise MissingConfiguration,
              "La conexión #{connection.name.inspect} no tiene credenciales de licencia de SAP. " \
              'Configure el usuario y la contraseña de licencia para que la sincronización pueda autenticarse.'
      end

      Clavisco::ServiceLayer::Client.new(
        base_url:         connection.sl_url,
        company_db:       company.sap_db,
        username:         connection.sap_license,
        password:         connection.sap_license_password,
        session_owner_id: session_owner_id
      )
    end

    # Identificación de la compañía para los mensajes de error. Lleva el id porque
    # dos compañías pueden llamarse parecido y el log tiene que ser accionable.
    def label(company)
      "La compañía #{company.name.inspect} (id #{company.id})"
    end
  end
end

# frozen_string_literal: true

module Api
  module Companies
    # Sección "Datos Generales" del formulario de compañías.
    #
    # Es un endpoint por sección, a propósito: en la pantalla cada sección tiene
    # su propio botón "Actualizar" y su propio loader, así que a nivel de proceso
    # también son independientes. Este PATCH escribe **solo** los catorce campos
    # de "Datos Generales" —diez en `companies` (`general_params`) y cuatro en la
    # UDT `@CL_FEC_ISSUERCONFIG` (`issuer_config_params`, ver `Sap::CompanyConfig`)—
    # y no puede tocar el certificado, el token de Hacienda ni los adjuntos ni
    # siquiera si vinieran en el cuerpo.
    #
    # Reemplaza el `PATCH /api/Companies?groupId=N&action=1` del .NET, que mandaba
    # las 42 columnas de las dos tablas del legado en cada guardado: apretar
    # "Actualizar" en una sección reescribía todas las demás con lo que hubiera en
    # pantalla, así que un campo mal cargado en una sección se propagaba al
    # guardar otra.
    #
    # `resource` singular y sin id: la sección pertenece a la compañía del path,
    # no es una colección (`CLAUDE.md` §28).
    class GeneralController < AuthorizedController
      # El alcance lo comparte con la lectura (`GET /api/companies/:id`): si no
      # resolvieran el mismo conjunto, el formulario abriría una compañía que este
      # guardado después rechaza (`CLAUDE.md` §28).
      include VisibleCompanies

      # El permiso se resuelve ANTES de buscar el registro: si se hiciera al
      # revés, un 404 le confirmaría a quien no tiene permiso qué ids existen.
      before_action :authorize_action
      before_action :load_company

      # PATCH /api/companies/:company_id/general
      #
      # ── Dos sistemas, un solo botón ──────────────────────────────────────
      # Cuatro de los catorce campos (`EmsrNombre`, `EmsrIdeTipo`,
      # `CodigoActividad`, `EmsrRegistroFiscal8707`) ya no son columna de
      # `companies`: viven en la UDT `@CL_FEC_ISSUERCONFIG` (`Sap::CompanyConfig`).
      # El PATCH no puede ser atómico entre los dos sistemas, así que el orden
      # es el que menos deja a medias:
      #
      #   1. Validar TODO contra el modelo, sin guardar (`assign_attributes` +
      #      `valid?`) — así la enorme mayoría de los rechazos (conexión que no
      #      existe, bandeja inactiva, `email_sender_type` fuera de catálogo)
      #      cortan ANTES de tocar SAP.
      #   2. Si pasó, escribir en SAP lo que vino de esa sección (PATCH parcial,
      #      solo si algo del bloque del emisor vino en el cuerpo).
      #   3. Recién si eso salió bien, `save` en SQLite.
      #
      # ⚠️ No hay revert de la UDT si el paso 3 falla: con el paso 1 ya validado
      # contra el modelo, un `save` que rechace algo ahí es un caso borde
      # (condición de carrera, restricción de la base) que revertir obligaría a
      # leer el estado anterior de SAP solo para poder reescribirlo — una vuelta
      # más al Service Layer que ningún otro paso necesita. Se documenta el
      # riesgo en vez de resolverlo con más complejidad.
      def update
        @company.assign_attributes(general_params)
        return render_invalid unless @company.valid?

        issuer_attrs = issuer_config_params
        if issuer_attrs.any?
          begin
            write_issuer_config!(issuer_attrs)
          rescue Sap::UserClient::MissingConfiguration, Sap::CompanyConfig::InvalidConfig => e
            return render_error(e.message)
          rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
            return render_error(e.sap_message || e.message)
          end
        end

        return render_invalid unless @company.save

        render json: ApiResponse.success(serialize(@company, read_issuer_config(@company)),
                                         message: 'Datos generales actualizados con éxito.').to_h
      end

      private

      def authorize_action
        require_permission!('Configurations_Companies_Update')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end

      # Los cuatro campos del bloque del emisor que vinieron en la petición,
      # SOLO los que vinieron (`params.key?`) — mismo criterio que
      # `general_params`: un PATCH parcial no puede borrar en SAP lo que esta
      # petición no mencionó. `Sap::CompanyConfig#update` ya sabe mandar solo
      # las llaves presentes.
      def issuer_config_params
        attrs = {}
        attrs[:legal_name]             = text(:EmsrNombre)             if params.key?(:EmsrNombre)
        attrs[:id_type]                = text(:EmsrIdeTipo)            if params.key?(:EmsrIdeTipo)
        attrs[:economic_activity_code] = text(:CodigoActividad)        if params.key?(:CodigoActividad)
        attrs[:tax_registry_8707]      = text(:EmsrRegistroFiscal8707) if params.key?(:EmsrRegistroFiscal8707)
        attrs
      end

      # Atribuida a quien edita (`Sap::UserClient`), no a la licencia — mismo
      # criterio que `Api::CompaniesController#write_issuer_config!` y que
      # `Api::Companies::ActivityCodesController` para toda escritura.
      def write_issuer_config!(attrs)
        Sap::CompanyConfig.new(client: Sap::UserClient.for(@company, user: Current.user),
                               actor:  Current.user&.email)
                          .update(attrs)
      end

      # Para devolver la sección tal como quedó (ver `serialize`): acá SÍ hay
      # que preguntarle a SAP, aunque el PATCH haya sido parcial — los campos
      # que esta petición no tocó siguen viniendo de ahí.
      def read_issuer_config(company)
        Sap::CompanyConfig.new(client: Sap::CompanyClient.for(company)).read
      end

      # Mismo criterio que `Api::CompaniesController`: falta de configuración
      # de SAP → 422, el Service Layer respondió mal → 502. Cubre la lectura
      # que hace `read_issuer_config` al devolver la respuesta; la escritura de
      # `update` maneja sus propios errores porque, a diferencia de la lectura,
      # tiene mensajes más específicos que devolver (`InvalidConfig`, por
      # ejemplo, no aplica a una lectura).
      rescue_from Sap::CompanyClient::MissingConfiguration do |error|
        render json: ApiResponse.error(error.message).to_h, status: :unprocessable_content
      end

      rescue_from Clavisco::ServiceLayer::Client::ServiceLayerError do |error|
        render json: ApiResponse.error(error.sap_message || error.message).to_h, status: :bad_gateway
      end

      # Los trece campos de la sección, y nada más. Lo que venga de otras secciones
      # se ignora en silencio: es lo que hace que los botones sean independientes
      # de verdad y no solo en la pantalla.
      #
      # Se copia únicamente lo que vino en la petición, para que un PATCH parcial
      # no borre lo que no mencionó — mismo criterio que `connection_params` y
      # `user_params`.
      #
      # Un campo de texto que llega vacío se guarda como `NULL`, no como `''`: son
      # la misma cosa para el negocio y tener las dos representaciones obliga a
      # preguntar por ambas en cada consulta.
      # `send_rejected_documents` decide si el correo de recepción electrónica
      # sale también para los comprobantes que Hacienda RECHAZA. Lo lee
      # `Sap::MailDocumentInfo`: en `false` le suma `Status eq 6` al
      # `$filter`, así que el job marca el documento `Omitido` en vez de mandarle
      # el correo al receptor.
      def general_params
        attrs = {}
        attrs[:name]                    = text(:Name)                   if params.key?(:Name)
        attrs[:sap_db]                  = text(:SapDb)                  if params.key?(:SapDb)
        attrs[:issuer_id_number]        = text(:EmsrIdeNumero)          if params.key?(:EmsrIdeNumero)
        attrs[:connection_id]           = number(:ConnectionId)         if params.key?(:ConnectionId)
        attrs[:email_config_id]         = number(:EmailConfigId)        if params.key?(:EmailConfigId)
        attrs[:reception_mailbox_id]    = number(:ReceptionMailboxId)   if params.key?(:ReceptionMailboxId)
        attrs[:email_sender_type]       = number(:EmailSenderType)      if params.key?(:EmailSenderType)
        attrs[:freight_type]            = number(:FreightType)          if params.key?(:FreightType)
        attrs[:is_active]               = boolean(:Active)              if params.key?(:Active)
        attrs[:send_rejected_documents] = boolean(:SendRejectedDocuments) if params.key?(:SendRejectedDocuments)
        attrs
      end

      def text(key)    = params[key].to_s.strip.presence
      def number(key)  = params[key].to_s.strip.presence&.to_i
      def boolean(key) = ActiveModel::Type::Boolean.new.cast(params[key])

      # Se devuelve la sección tal como quedó guardada, no lo que vino en el
      # cuerpo: el modelo normaliza (los vacíos pasan a `NULL`) y el formulario
      # necesita el estado real para volver a marcar la sección como "sin
      # cambios".
      #
      # ⚠️ Estas catorce claves tienen que ser las mismas que devuelve
      # `Api::CompaniesController#serialize_detail` para esta sección. Si una se
      # agrega en un lado y no en el otro, el formulario muestra un campo que este
      # PATCH ignora: el usuario lo edita, guarda, y no pasa nada — sin error.
      # `spec/requests/api/company_general_spec.rb` compara las dos listas.
      #
      # @param issuer_config [Sap::CompanyConfig::Config, nil] ver
      #   `read_issuer_config`.
      def serialize(company, issuer_config)
        {
          Name:                   company.name,
          Active:                 company.is_active,
          SendRejectedDocuments:  company.send_rejected_documents,
          ConnectionId:           company.connection_id,
          EmailConfigId:          company.email_config_id,
          ReceptionMailboxId:     company.reception_mailbox_id,
          SapDb:                  company.sap_db,
          EmailSenderType:        company.email_sender_type,
          FreightType:            company.freight_type,
          EmsrNombre:             issuer_config&.legal_name,
          EmsrIdeTipo:            issuer_config&.id_type,
          EmsrIdeNumero:          company.issuer_id_number,
          CodigoActividad:        issuer_config&.economic_activity_code,
          EmsrRegistroFiscal8707: issuer_config&.tax_registry_8707
        }
      end

      def render_invalid
        render_error(@company.errors.full_messages.to_sentence)
      end

      def render_error(message)
        render json: ApiResponse.error(message).to_h, status: :unprocessable_content
      end
    end
  end
end

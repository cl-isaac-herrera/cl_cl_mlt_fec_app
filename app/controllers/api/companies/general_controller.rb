# frozen_string_literal: true

module Api
  module Companies
    # Sección "Datos Generales" del formulario de compañías.
    #
    # Es un endpoint por sección, a propósito: en la pantalla cada sección tiene
    # su propio botón "Actualizar" y su propio loader, así que a nivel de
    # proceso también son independientes — de LECTURA y de escritura. El `show`
    # y el `update` exponen/escriben **solo** los ocho campos de "Datos
    # Generales" (todos columna de `companies`) — no puede tocar el
    # certificado, el token de Hacienda, los adjuntos ni el bloque del emisor
    # ante Hacienda ni siquiera si vinieran en el cuerpo.
    #
    # El bloque del emisor (razón social, tipo y número de identificación,
    # actividad económica, registro fiscal 8707 — la UDT `@CL_FEC_ISSUERCONFIG`,
    # `Sap::CompanyConfig`) se partió a su propia sección el 2026-09-25: ver
    # `Api::Companies::LegalDataController`. Antes de ese cambio este endpoint
    # también hablaba con SAP, así que guardar la conexión o la bandeja de correo
    # dependía de que el Service Layer respondiera.
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
      # El `show` y el `update` comparten el mismo alcance (`load_company` es el
      # único punto de entrada al registro): si no resolvieran el mismo
      # conjunto, el formulario podría leer una compañía que después el
      # guardado rechaza (`CLAUDE.md` §28).
      include VisibleCompanies

      # El permiso se resuelve ANTES de buscar el registro: si se hiciera al
      # revés, un 404 le confirmaría a quien no tiene permiso qué ids existen.
      before_action :authorize_action
      before_action :load_company

      # GET /api/companies/:company_id/general
      #
      # Alimenta SOLO esta sección del formulario — el `GET /api/companies/:id`
      # de `Api::CompaniesController` sigue existiendo para otras pantallas,
      # pero el formulario de compañías ya no lo llama para esta parte.
      def show
        render json: ApiResponse.success(serialize(@company)).to_h
      end

      # PATCH /api/companies/:company_id/general
      def update
        @company.assign_attributes(general_params)
        return render_invalid unless @company.save

        render json: ApiResponse.success(serialize(@company),
                                         message: 'Datos generales actualizados con éxito.').to_h
      end

      private

      def authorize_action
        require_any_permission!('Configurations_Companies_Update',
                                'Configurations_Companies_UpdateInAllCompanies')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end

      # Los ocho campos de la sección, y nada más. Lo que venga de otras secciones
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
        attrs[:sap_db]                  = text(:SapDb)                  if params.key?(:SapDb)
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
      # ⚠️ Estas ocho claves tienen que ser las mismas que devuelve
      # `Api::CompaniesController#serialize_detail` para esta sección. Si una se
      # agrega en un lado y no en el otro, el formulario muestra un campo que este
      # PATCH ignora: el usuario lo edita, guarda, y no pasa nada — sin error.
      # `spec/requests/api/company_general_spec.rb` compara las dos listas.
      def serialize(company)
        {
          Active:                company.is_active,
          SendRejectedDocuments: company.send_rejected_documents,
          ConnectionId:          company.connection_id,
          EmailConfigId:         company.email_config_id,
          ReceptionMailboxId:    company.reception_mailbox_id,
          SapDb:                 company.sap_db,
          EmailSenderType:       company.email_sender_type,
          FreightType:           company.freight_type
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

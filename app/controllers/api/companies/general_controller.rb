# frozen_string_literal: true

module Api
  module Companies
    # Sección "Datos Generales" del formulario de compañías.
    #
    # Es un endpoint por sección, a propósito: en la pantalla cada sección tiene
    # su propio botón "Actualizar" y su propio loader, así que a nivel de proceso
    # también son independientes. Este PATCH escribe **solo** los once campos que
    # nombra `general_params` y no puede tocar el certificado, el token de
    # Hacienda ni los adjuntos ni siquiera si vinieran en el cuerpo.
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
      def update
        return render_invalid unless @company.update(general_params)

        render json: ApiResponse.success(serialize(@company),
                                         message: 'Datos generales actualizados con éxito.').to_h
      end

      private

      def authorize_action
        require_permission!('Configurations_Companies_Update')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end

      # Los once campos de la sección, y nada más. Lo que venga de otras secciones
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
      def general_params
        attrs = {}
        attrs[:name]                   = text(:Name)                   if params.key?(:Name)
        attrs[:sap_db]                 = text(:SapDb)                  if params.key?(:SapDb)
        attrs[:issuer_legal_name]      = text(:EmsrNombre)             if params.key?(:EmsrNombre)
        attrs[:issuer_id_type]         = text(:EmsrIdeTipo)            if params.key?(:EmsrIdeTipo)
        attrs[:issuer_id_number]       = text(:EmsrIdeNumero)          if params.key?(:EmsrIdeNumero)
        attrs[:economic_activity_code] = text(:CodigoActividad)        if params.key?(:CodigoActividad)
        attrs[:tax_registry_8707]      = text(:EmsrRegistroFiscal8707) if params.key?(:EmsrRegistroFiscal8707)
        attrs[:connection_id]          = number(:ConnectionId)         if params.key?(:ConnectionId)
        attrs[:email_sender_type]      = number(:EmailSenderType)      if params.key?(:EmailSenderType)
        attrs[:freight_type]           = number(:FreightType)          if params.key?(:FreightType)
        attrs[:is_active]              = boolean(:Active)              if params.key?(:Active)
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
      # ⚠️ Estas once claves tienen que ser las mismas que devuelve
      # `Api::CompaniesController#serialize_detail` para esta sección. Si una se
      # agrega en un lado y no en el otro, el formulario muestra un campo que este
      # PATCH ignora: el usuario lo edita, guarda, y no pasa nada — sin error.
      # `spec/requests/api/company_general_spec.rb` compara las dos listas.
      def serialize(company)
        {
          Name:                   company.name,
          Active:                 company.is_active,
          ConnectionId:           company.connection_id,
          SapDb:                  company.sap_db,
          EmailSenderType:        company.email_sender_type,
          FreightType:            company.freight_type,
          EmsrNombre:             company.issuer_legal_name,
          EmsrIdeTipo:            company.issuer_id_type,
          EmsrIdeNumero:          company.issuer_id_number,
          CodigoActividad:        company.economic_activity_code,
          EmsrRegistroFiscal8707: company.tax_registry_8707
        }
      end

      def render_invalid
        render json: ApiResponse.error(@company.errors.full_messages.to_sentence).to_h,
               status: :unprocessable_content
      end
    end
  end
end

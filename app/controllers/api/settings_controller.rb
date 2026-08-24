# frozen_string_literal: true

module Api
  # Ajustes de la instalación (pantalla /configurations/general).
  #
  # Reemplaza `GET /api/settings` y `PATCH /api/settings` del .NET, que mandaba
  # el `Code` en el cuerpo. Acá el `code` es la llave natural del recurso y va en
  # el path (`CLAUDE.md` §28); el cuerpo lleva únicamente el valor.
  #
  # **Lo único que se escribe es `value`.** `code`, `group_code`, `description` e
  # `is_visible` son metadatos del catálogo, los declara `db/seeds.rb` y ningún
  # parámetro de este controller los toca: un ajuste que la instalación no
  # declaró no se puede crear desde la pantalla, y uno declarado no se puede
  # renombrar ni volver visible.
  #
  # El permiso es `Configurations_General_Access`, el mismo que abre la pantalla.
  # Es una decisión tomada a conciencia y anotada en `TODOS.md`: editar
  # credenciales de base de datos merecería un permiso de escritura propio, pero
  # hoy no existe y no se inventa uno de paso.
  class SettingsController < AuthorizedController
    before_action -> { require_permission!(PERMISSION) }
    before_action :load_setting, only: [:update]

    PERMISSION = 'Configurations_General_Access'

    # GET /api/settings?group=DOCS_DB_ODBC
    #
    # Sin filtro devuelve el catálogo completo: la pantalla arma sus tres
    # secciones de una sola lectura en vez de una por grupo.
    def index
      scope = Setting.all
      scope = scope.in_group(params[:group]) if params[:group].present?

      render json: ApiResponse.success(
        scope.order(:group_code, :code).map { |setting| serialize(setting) }
      ).to_h
    end

    # PATCH /api/settings/:code
    #
    # Cuerpo: `{ "Value": "…" }`. Un `Value` vacío deja el ajuste sin configurar
    # (`update_value!` normaliza con `presence`), que es distinto de no mandar la
    # llave: sin `Value` en el cuerpo la petición no dice qué hacer y se rechaza,
    # en vez de borrar en silencio lo que había.
    def update
      unless params.key?(:Value)
        return render json: ApiResponse.error('No se envió el valor del ajuste.').to_h,
                      status: :unprocessable_content
      end

      begin
        @setting.update_value!(params[:Value].to_s)
      rescue ActiveRecord::RecordInvalid
        return render json: ApiResponse.error(@setting.errors.full_messages.to_sentence).to_h,
                      status: :unprocessable_content
      end

      render json: ApiResponse.success(serialize(@setting),
                                       message: 'Ajuste actualizado con éxito.').to_h
    end

    private

    # `unscoped`: la pantalla administra el catálogo, así que también tiene que
    # poder reconfigurar un ajuste dado de baja (`CLAUDE.md` §28).
    def load_setting
      @setting = Setting.unscoped.find_by(code: params[:code])
      return if @setting

      render json: ApiResponse.not_found('El ajuste no existe.').to_h, status: :not_found
    end

    # `Value` sale de `visible_value`: un ajuste oculto devuelve `nil` SIEMPRE.
    # `HasValue` es lo que la pantalla necesita para distinguir "no configurado"
    # de "configurado y no se muestra" — sin él, un campo de contraseña vacío no
    # le dice al operador si tiene que volver a escribirla.
    #
    # Es el arreglo de una fuga real: el .NET mandaba `CrystalPassword` en claro
    # al browser y la UI la enmascaraba con un `type="password"` que tenía botón
    # para revelarla.
    def serialize(setting)
      {
        Code:        setting.code,
        GroupCode:   setting.group_code,
        Description: setting.description,
        IsVisible:   setting.is_visible,
        Value:       setting.visible_value,
        HasValue:    setting.value?,
        UpdatedAt:   setting.updated_at,
        UpdatedBy:   setting.updated_by
      }
    end
  end
end

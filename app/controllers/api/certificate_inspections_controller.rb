# frozen_string_literal: true

module Api
  # Abre un certificado `.p12` / `.pfx` con su PIN y devuelve cuándo vence, antes
  # de guardarlo. Lo usa la sección "Hacienda (ATV)" del formulario de compañías:
  # al elegir el archivo y escribir el PIN, el campo "Fecha de Expiración" se
  # llena con lo que dice el certificado.
  #
  # Reemplaza `POST /api/Companies/CheckCertExpireDate?CertPin=…`. Dos cosas
  # cambian además del nombre:
  #
  # 1. **El PIN viaja en el cuerpo, no en la query string.** Un secreto en la URL
  #    queda en el historial del navegador, en el log de accesos del servidor web
  #    y en cualquier proxy del camino, donde `filter_parameters` no llega.
  # 2. **Es `create` de un recurso, no un verbo en el path** (`CLAUDE.md` §28):
  #    cada llamado produce una inspección nueva. No cuelga de
  #    `/api/companies/:id` porque el certificado todavía no es de ninguna
  #    compañía — el alta lo usa igual, y ahí no hay id.
  #
  # ⚠️ **El archivo no se guarda.** Se abre en memoria y se descarta con el
  # request. Persistir el `.p12` es otra tarea y necesita decidir antes dónde vive
  # el binario (`TODOS.md` → Compañías).
  class CertificateInspectionsController < AuthorizedController
    # POST /api/certificate_inspections
    #
    # Cuerpo multipart: `file` (el .p12/.pfx) y `CertPin`.
    def create
      # Sirve a las dos pantallas que cargan un certificado —el alta y la
      # edición— y cada permiso por separado ya autoriza esta lectura.
      require_any_permission!('Configurations_Companies_Create',
                              'Configurations_Companies_Update')
      return if performed?

      result = Certificates::ExpirationReader.new(file: params[:file], pin: params[:CertPin]).call

      # Un PIN equivocado o un archivo que no es un certificado son un problema
      # de la petición, no del servidor: 422 con el motivo. El .NET respondía 200
      # con el mensaje adentro y la pantalla tenía que adivinar si había fallado.
      return render json: ApiResponse.error(result.error).to_h, status: :unprocessable_content unless result.ok?

      # Las llaves van entre `{}`: `success(data, code:, message:)` toma keywords,
      # y un hash suelto se le colaría como `code`/`message` en vez de como dato.
      render json: ApiResponse.success({ CertExpireDate: result.expires_at }).to_h
    end
  end
end

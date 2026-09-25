# frozen_string_literal: true

module Api
  # Alarma de vencimiento del certificado digital de la compañía activa.
  #
  # Reemplaza `GET /api/Companies/GetCertExpireDateAlarm?companyId=N` del API
  # .NET, que resolvía la alarma con el stored procedure `spCertExpireDateAlarm`.
  # Acá el dato sale de `companies.cert_expires_at` (`CLAUDE.md` §28).
  #
  # Dos cosas cambian respecto del .NET:
  #
  #   * **El `companyId` no viaja.** La compañía activa vive en la session cookie
  #     y la lee el servidor (§28, regla 5). Que el cliente pudiera elegirla era
  #     justamente el portillo: permitía preguntar por el certificado de una
  #     compañía ajena.
  #   * **`Data` es un objeto, no un arreglo.** El SP devolvía un `IEnumerable`
  #     de un solo elemento, y por eso el Angular leía `data.Data.ShowAlarm`
  #     sobre un arreglo y siempre obtenía `undefined`. La alarma es una sola:
  #     recurso singular, respuesta singular.
  class CertificateAlarmsController < AuthorizedController
    # No lleva permiso propio: es el certificado de la compañía que el usuario
    # ya tiene activa, y el aviso lo necesita cualquiera que emita. El filtro de
    # acceso es la asignación misma, que valida `RequiresActiveCompany` — el
    # skip va ANTES para que el safety net no reviente si `require_company!`
    # corta la respuesta antes de llegar a `show`.
    before_action :skip_permission_check!
    include RequiresActiveCompany

    # GET /api/certificate_alarm
    def show
      render json: ApiResponse.success(company.certificate_alarm).to_h
    end
  end
end

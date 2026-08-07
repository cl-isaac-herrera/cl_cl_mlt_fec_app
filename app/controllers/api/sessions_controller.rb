# frozen_string_literal: true

module Api
  # Estado de la sesión del usuario: hoy, la compañía activa.
  #
  # La compañía dejó de vivir en sessionStorage del browser y pasó a la session
  # cookie (§2.4: "company_id vive en la session cookie, no en header"). Eso es lo
  # que permite que require_permission! y require_view_permission! evalúen algo:
  # ambos leen la compañía de la sesión, no de un parámetro que el cliente elija.
  class SessionsController < AuthorizedController
    # PUT /api/session/company
    def update_company
      # skip_permission_check! — elegir entre las compañías propias no es una acción
      # permisada; la autorización es la asignación, que se valida acá abajo.
      skip_permission_check!

      company = Company.assigned_to(Current.user.id).find_by(id: params[:company_id])

      unless company
        return render json: ApiResponse.forbidden('La compañía no está asignada a este usuario').to_h,
                      status: :forbidden
      end

      session[:company_id] = company.id
      Current.company_id   = company.id

      render json: ApiResponse.success({ Id: company.id, Uuid: company.uuid, Name: company.name }).to_h
    end
  end
end

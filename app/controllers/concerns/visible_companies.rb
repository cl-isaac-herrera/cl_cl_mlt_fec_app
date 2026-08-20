# frozen_string_literal: true

# Alcance de las compañías que el usuario de la sesión puede ADMINISTRAR.
#
# Lo comparten la lectura (`GET /api/companies` y `GET /api/companies/:id`) y la
# escritura de cada sección (`PATCH /api/companies/:id/general`, …). Si
# los dos no resolvieran exactamente el mismo conjunto, el formulario abriría una
# compañía que el guardado después rechaza — o peor, dejaría escribir una que no
# se puede ver (`CLAUDE.md` §28, "El catálogo y la escritura resuelven el MISMO
# alcance").
#
# No confundir con `AssignableCompanies`, que es el alcance de las compañías que
# se le pueden ASIGNAR a otro usuario y responde a otro permiso.
module VisibleCompanies
  extend ActiveSupport::Concern

  # Permite administrar todas las compañías de la instalación, no solo las
  # asignadas al usuario. No es un permiso de acción sino de alcance: se consulta
  # con `permission?`, que no corta la respuesta ni marca la acción como
  # verificada.
  SEE_ALL_COMPANIES = 'Configurations_Companies_ViewAllApplicationCompanies'

  private

  # `unscoped` a propósito: el default_scope de SoftDeletable esconde a las
  # inactivas, y estas pantallas existen justamente para poder verlas y
  # reactivarlas.
  def visible_companies
    return Company.unscoped if permission?(SEE_ALL_COMPANIES)

    Company.unscoped.assigned_to(Current.user.id)
  end

  # Responde 404 —y no 403— cuando la compañía existe pero está fuera de alcance:
  # para este usuario no existe, y distinguir los dos casos le confirmaría qué
  # ids hay.
  #
  # @return [Company, nil] nil cuando ya se renderizó el 404.
  def find_visible_company(id)
    company = visible_companies.find_by(id: id)
    return company if company

    render json: ApiResponse.not_found('La compañía no existe.').to_h, status: :not_found
    nil
  end
end

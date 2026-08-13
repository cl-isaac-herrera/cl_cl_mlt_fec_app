# frozen_string_literal: true

# Alcance de las compañías que el usuario de la sesión puede ASIGNARLE a otro.
#
# Lo comparten el catálogo (`GET /api/companies/assignable`) y la escritura
# (`PUT /api/users/:id/companies`): si los dos no resolvieran exactamente el mismo
# conjunto, el panel mostraría una compañía que el guardado después rechaza.
#
# Por defecto son las propias, igual que ya validaba `POST /api/users`: nadie
# reparte accesos a compañías donde él mismo no llega.
module AssignableCompanies
  extend ActiveSupport::Concern

  # Vía de escape para poder asignarle su primera compañía a alguien en una
  # sociedad donde el administrador no opera. Bajo `CLAUDE.md` §31 "las compañías
  # del grupo" son literalmente las de la instalación, así que este permiso del
  # catálogo hace de "ver todas" sin inventar uno nuevo.
  SEE_ALL_COMPANIES = 'Configurations_Companies_ViewGroupCompanies'

  private

  # No marca la acción como verificada: la acción exige su propio permiso aparte.
  # Esto solo decide el ALCANCE (`CLAUDE.md` §28, `permission?`).
  def assignable_companies
    return Company.all if permission?(SEE_ALL_COMPANIES)

    Company.assigned_to(Current.user.id)
  end
end

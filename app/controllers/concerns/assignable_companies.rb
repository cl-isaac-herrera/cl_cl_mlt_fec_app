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
  # sociedad donde el administrador no opera.
  #
  # Antes era `Configurations_Companies_ViewGroupCompanies` ("las compañías del
  # grupo"), pero bajo `CLAUDE.md` §31 no hay grupos: "el grupo" siempre fue
  # literalmente la instalación entera, así que se reemplaza por el permiso que
  # ya dice eso sin depender de un concepto inexistente
  # (docs/PLAN-ROLES-POR-ALCANCE.md, Fase 0 decisión 5).
  SEE_ALL_COMPANIES = 'Configurations_Companies_ViewAllApplicationCompanies'

  private

  # No marca la acción como verificada: la acción exige su propio permiso aparte.
  # Esto solo decide el ALCANCE (`CLAUDE.md` §28, `permission?`).
  def assignable_companies
    return Company.all if permission?(SEE_ALL_COMPANIES)

    Company.assigned_to(Current.user.id)
  end
end

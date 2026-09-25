# frozen_string_literal: true

# Exige una compañía activa asignada al usuario, antes de operar sobre "la
# compañía activa" (docs/PLAN-ROLES-POR-ALCANCE.md).
#
# Con roles de instalación, entrar a la aplicación ya NO obliga a elegir una
# compañía primero (`Api::PermissionsController#index` se pide siempre, haya o
# no una activa). Cualquier acción que sí dependa de una — documentos,
# sucursales, el certificado… — tiene que pedirla explícitamente en vez de
# asumir que `Current.company_id` viene lleno.
#
# Dos causas posibles, dos respuestas distintas:
#   - no hay ninguna compañía activa en la sesión → 422, el cliente puede
#     resolverlo solo con que el usuario elija una;
#   - hay una, pero no es de las asignadas a este usuario (sesión manipulada,
#     o la asignación se revocó después de abrir sesión) → 403, no hay nada
#     que el cliente pueda ofrecer para arreglarlo por su cuenta.
module RequiresActiveCompany
  extend ActiveSupport::Concern

  included do
    before_action :require_company!
  end

  private

  def require_company!
    if Current.company_id.nil?
      return render json: ApiResponse.error('Seleccione una compañía').to_h,
                    status: :unprocessable_content
    end

    return if company

    render json: ApiResponse.forbidden('La compañía activa no está asignada a este usuario.').to_h,
           status: :forbidden
  end

  # La compañía activa, validada contra las asignadas al usuario (§28 regla 5):
  # el id sale de la sesión, nunca de un parámetro.
  def company
    @company ||= Company.assigned_to(Current.user.id).find_by(id: Current.company_id)
  end
end

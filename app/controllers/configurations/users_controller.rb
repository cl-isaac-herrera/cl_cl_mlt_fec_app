# frozen_string_literal: true

module Configurations
  class UsersController < ApplicationController
    layout 'protected'

    # Pantalla única. `register` y `edit` se eliminaron: eran las páginas de alta y
    # edición que reemplazaron los paneles laterales del listado, y habían quedado
    # huérfanas (nada las enlazaba) y rotas (llamaban endpoints del .NET ya
    # migrados). El alta de cuentas la resuelve el IdP; acá solo se provisiona la
    # fila del usuario y sus accesos.
    #
    # GET /configurations/users
    def index; end
  end
end

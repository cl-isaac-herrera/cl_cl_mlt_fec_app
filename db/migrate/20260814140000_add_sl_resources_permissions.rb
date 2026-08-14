# frozen_string_literal: true

# Agrega al catálogo los dos permisos de la pantalla de recursos de Service Layer.
#
# Hace falta porque `db/seeds.rb` **borra y recrea el catálogo entero**: sirve
# para levantar un ambiente de cero, no para una base con datos reales, donde
# borrar los permisos se lleva puestas las asignaciones de `role_permissions` y
# `user_permissions`. Un cambio de catálogo en una base viva es una migración
# (`CLAUDE.md` §28).
#
# Tiene que dejar el MISMO estado final que `CODE_ONLY_GLOBAL` de `db/seeds.rb`:
# mismos Id, mismos nombres, mismo tipo, y concedidos al rol Administrador — que
# es lo que hace el seed al asignarle el catálogo completo. Sin esa concesión el
# permiso existiría pero nadie podría entrar a la pantalla nueva.
#
# Son `global` porque `sl_resources` no lleva `company_id`: las consultas son de
# la instalación, no de una compañía, igual que las conexiones.
class AddSlResourcesPermissions < ActiveRecord::Migration[8.1]
  ADD = [
    [1013, 'Configurations_SlResources_Access', 'Acceso a la vista de recursos de Service Layer'],
    [1014, 'Configurations_SlResources_Update', 'Permite modificar consultas de Service Layer']
  ].freeze

  ADMIN_ROLE_NAME = 'Administrador'

  # Clases mínimas y locales: la migración no debe depender de los modelos de la
  # app, que cambian con el tiempo (y cuyos `default_scope` esconderían justo las
  # filas que hay que tocar). `inheritance_column = nil` porque `type` en
  # `permissions` es el tipo de permiso del negocio, no STI.
  class MigrationPermission < ActiveRecord::Base
    self.table_name = 'permissions'
    self.inheritance_column = nil
  end

  # Solo se lee, para ubicar al rol Administrador por nombre.
  class MigrationRole < ActiveRecord::Base
    self.table_name = 'roles'
  end

  # Tabla puente rol↔permiso: es donde vive la concesión.
  class MigrationRolePermission < ActiveRecord::Base
    self.table_name = 'role_permissions'
  end

  def up
    now = Time.current

    ADD.each do |id, name, description|
      # Idempotente: en una base sembrada de cero el permiso ya existe con este
      # nombre, y volver a insertarlo dejaría dos filas iguales.
      next if MigrationPermission.exists?(name: name)

      MigrationPermission.create!(
        id: id, name: name, description: description, type: 'global',
        is_active: true, created_by: 'system', created_at: now, updated_at: now
      )
    end

    grant_to_admin(now)
  end

  def down
    permissions = MigrationPermission.where(name: ADD.map { |_id, name, _d| name })

    # Primero la concesión: la FK desde `role_permissions` no deja borrar el
    # permiso mientras la fila puente exista. Acá sí es DELETE y no baja lógica —
    # se está revirtiendo una fila que esta misma migración creó, no revocándole
    # un permiso a un rol.
    MigrationRolePermission.where(permission_id: permissions.select(:id)).delete_all
    permissions.delete_all
  end

  private

  # El rol Administrador tiene el catálogo completo (lo hace el seed). Si la base
  # no lo tiene todavía, no hay nada que conceder: el seed lo va a crear con el
  # catálogo ya completo.
  def grant_to_admin(now)
    admin = MigrationRole.find_by(name: ADMIN_ROLE_NAME)
    return if admin.nil?

    MigrationPermission.where(name: ADD.map { |_id, name, _d| name }).find_each do |permission|
      existing = MigrationRolePermission.find_by(role_id: admin.id, permission_id: permission.id)

      # Reactivar la fila revocada en vez de insertar otra al lado: es el mismo
      # criterio que la reasignación de permisos por rol (`CLAUDE.md` §28).
      if existing
        existing.update!(is_active: true, updated_at: now) unless existing.is_active
        next
      end

      MigrationRolePermission.create!(
        role_id: admin.id, permission_id: permission.id, is_active: true,
        created_by: 'system', created_at: now, updated_at: now
      )
    end
  end
end

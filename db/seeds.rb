# frozen_string_literal: true

# Catálogo de permisos y rol Administrador.
#
# Los permisos dejaron de venir del API .NET: `GET /api/permissions` los resuelve
# contra las tablas propias (user_roles → role_permissions → permissions), así que
# este catálogo tiene que existir en la base o el menú queda vacío y todas las
# acciones se muestran deshabilitadas (CLAUDE.md §26).
#
# Idempotente: se puede correr varias veces (`bin/rails db:seed`).
#
# ⚠️ Los `id` se fijan explícitamente para conservar los del origen. Eso permite
# importar después `PermissionByRol` copiando `PermissionId` tal cual, sin mapear
# por nombre. Como forzar un id sobre una fila existente implica reemplazarla, el
# seed vacía `permissions` y `role_permissions` antes de insertar; son tablas que
# hoy solo escribe este archivo. `roles` y `user_roles` no se tocan.

# ---------------------------------------------------------------------------
# 1. Permisos NORMALES — export de la tabla `Permission` del .NET (54 filas).
#    Se conceden por compañía: `user_roles` lleva `company_id`, así que el mismo
#    usuario puede tener el permiso en una compañía y no en otra.
#
#    Id, nombre y descripción tal como vienen del origen, huecos de Id incluidos.
#    No editar a mano: reemplazar por un export nuevo cuando cambie el origen.
# ---------------------------------------------------------------------------
CATALOG = [
  [1,  'M_Documents',                       'Acceso a Menu Documentos'],
  [2,  'M_Config',                          'Acceso a Menu Configuraciones'],
  [3,  'Documents_Issued_ViewDocuments',    'Permite visualizar documentos emitidos'],
  [4,  'Documents_Reception_ViewDocuments',  'Permite visualizar documentos recepcionados'],
  [5,  'S_ReceptDocs',                      'Acceso a SubMenu Recepción de Documentos'],
  [6,  'S_Company',                         'Acceso a SubMenu de Compañías'],
  [7,  'S_RegUser',                         'Acceso a SubMenu Registro de Usuarios'],
  # Huérfano: su pantalla ("Completar registro") se eliminó y nadie lo evalúa. Se
  # sigue sembrando porque el catálogo replica el del origen tal cual. Ver
  # `db/permission_name_map.yml` → orphaned.
  [8,  'S_CompUser',                        'Acceso a SubMenu Completar Registro de Usuarios'],
  # Renombrado desde `S_AsigUser` (§4.4). La equivalencia con el nombre de origen
  # vive en `db/permission_name_map.yml` y la importación tiene que traducirla.
  [9,  'Configurations_Users_CompanyAssignment',
       'Permite asignarle compañías a un usuario'],
  [10, 'S_Groups',                          'Acceso a SubMenu de  Grupos'],
  [11, 'S_Numbering',                       'Acceso a SubMenu de Numeración'],
  [12, 'S_PermsByRol',                      'Acceso a SubMenu de Roles por Usuarios'],
  [13, 'S_Rols',                            'Acceso a SubMenu de Roles'],
  [14, 'S_RolByUser',                       'Acceso a SubMenu de Rol por Usuario'],
  [15, 'S_CreateDocs',                      'Acceso a SubMenu Creación de documentos'],
  [16, 'F_CreateCompany',                   'Permiso para la Creación de Compañías'],
  [17, 'F_ModifyCompany',                   'Permiso para la Modificación de Compañías'],
  [18, 'Configurations_Groups_Update',      'Permiso para la Actualización de Grupos'],
  [19, 'F_AddOwner',                        'Permiso para Agregar un Owner'],
  [20, 'F_RemoveOwner',                     'Permiso para Eliminar un Owner'],
  [21, 'S_ReceptNumbering',                 'Acceso a SubMenu de Numeración de Recepción'],
  [23, 'S_CreateDocsND',                    'Acceso a SubMenu Creación de Documentos ND'],
  [25, 'S_CreateDocsNC',                    'Acceso a SubMenu Creación de Documentos NC'],
  [27, 'S_CreateDocsTE',                    'Acceso a SubMenu Creación de Documentos TE'],
  [28, 'S_CreateDocsFEC',                   'Acceso a SubMenu Creación de Documentos FEC'],
  [29, 'S_CreateDocsFEE',                   'Acceso a SubMenu Creación de Documentos FEE'],
  [30, 'S_CreateDocsFE',                    'Acceso a SubMenu Creación de Documentos FE'],
  [31, 'M_Reports',                         'Acceso a Menu Reportes'],
  [32, 'S_DocumentReport',                  'Acceso a SubMenu de Reporte de Documentos'],
  [33, 'S_DocumentReceptionReport',         'Acceso a SubMenu de Reporte de Recepcion de Documentos'],
  [35, 'F_CreateAPInvoice',                 'Permiso para la Creación de Facturas a Proveedor'],
  [36, 'F_ResetCompanyFormat',              'Permiso para restablecer el formato de impresión de la compañía'],
  [38, 'S_UpdateUserInfo',                  'Acceso a SubMenu Actualizacion de Usuarios'],
  [39, 'S_MailParserLogs',                  'Acceso a SubMenu de Logs de Recepcion'],
  [40, 'F_CreateBulkDownloadOfDocuments',   'Permiso para la Creación de Solicitud de Descarga Masiva de Documentos'],
  [41, 'S_Sucursal',                        'Acceso a SubMenu de Sucursales'],
  [42, 'S_Udfs',                            'Acceso a seleccion de udfs'],
  [43, 'Configurations_MailParser_ViewConfigurations',
       'Permiso para acceder a la configuración de bandejas de correos'],
  [47, 'S_AcceptDocsGT',                    'Acceso a SubMenu Aceptación de Documentos GT'],
  [49, 'S_EmailReport',                     'Acceso a SubMenu de Reporte de correos'],
  [50, 'S_CreateDocsREP',                   'Acceso a SubMenu Creación de Documentos REP'],
  [51, 'Documents_Acceptance_Reprocess',    'Permitir reprocesar documentos de recepción'],
  [54, 'Maintenance_EmailInbox_Access',     'Acceso a vista de asignación de bandejas'],
  [56, 'Documents_Emission_Reprocess',      'Permitir reprocesar documentos de emisión'],
  [63, 'Configurations_Users_Access',       'Permite acceder a al modulo de administración de usuarios'],
  [64, 'Configurations_Users_Create',       'Permite crear usuarios'],
  [65, 'Configurations_Users_ListAccess',   'Permite acceder a la vista de lista de usuarios'],
  [68, 'Configurations_Users_Update',       'Permite actualizar un usuario'],
  [70, 'Configurations_Permissions_Access', 'Permite acceder a la vista de asignacion de permisos por rol'],
  [73, 'Configurations_Companies_DownloadFEPrintFormat',
       'Permiso para descargar el formato de impresión FE de la compañía'],
  [78, 'Configurations_Groups_DownloadFEPrintFormat',
       'Permiso para descargar el formato de impresión del grupo'],
  [82, 'Configurations_Companies_DownloadCertificate',
       'Permiso para descargar el certificado de la compañía'],
  [84, 'Configurations_Companies_DownloadLogo',
       'Permiso para descargar el logo de la compañía'],
  [89, 'Configurations_MailParser_UpdateProcessingTenantStatus',
       'Permiso para actualizar el estado de las compañías emisoras de las bandejas mail parser de la compañía actual']
].freeze

# ---------------------------------------------------------------------------
# 2. Permisos GLOBALES — export de las filas de tipo global (25 filas).
#    Aplican a nivel de aplicación: no dependen de la compañía activa, y por eso
#    los nombres suelen decir "…InAllCompanies" / "…AllApplication…".
#
#    Sus Id llenan los huecos que dejaba el export normal (52, 53, 57-62, 66, 67,
#    71-90), así que los dos archivos son subconjuntos disjuntos de la misma tabla.
#    Descripciones textuales del origen, erratas incluidas ("Permitr", "conexiónes",
#    "pertenese"): son datos, no texto a corregir acá.
# ---------------------------------------------------------------------------
GLOBAL_CATALOG = [
  [52, 'Configurations_General_Access',      'Acceso a las configuraciones generales'],
  [53, 'Logs_Access',                        'Acceso a vista de visualizacion de logs de texto'],
  [57, 'Configurations_WizardSetup_Access',  'Acceso a la vista de asistente de configuración'],
  [58, 'Configurations_WizardSetup_CompleteSteps',
       'Permitr completar pasos de configuración en asistente de configuración'],
  [59, 'Configurations_UserHelp_Access',     'Acceso a la vista de configuración de ayuda de usuario'],
  [60, 'Configurations_Connections_Access',  'Acceso a la vista de configuración de conexiónes'],
  [61, 'Configurations_Connections_Create',  'Permite crear una conexión de SAP'],
  [62, 'Configurations_Connections_Update',  'Permite actualizar una conexion de SAP'],
  [66, 'Configurations_Users_ViewGroupUsers',
       'Permite ver la lista de usuarios de todo el grupo de compañías al que pertenese el usuario'],
  [67, 'Configurations_Users_ViewAllApplicationUsers',
       'Permite ver la lista de todos los usuarios de la aplicación'],
  [71, 'Configurations_Permissions_GlobalAccess',
       'Permiso para acceder a la vista de asignacion de permisos globales'],
  [72, 'Configurations_Groups_ViewAllApplicationGroups',
       'Permiso para visualizar todos los grupos de la aplicacion'],
  [74, 'Configurations_General_DownloadDefaultPrintFormat',
       'Permiso para descargar el formato de impresion predeterminado'],
  [75, 'Configurations_General_UploadDefaultPrintFormat',
       'Permiso para cargar el formato de impresión predeterminado'],
  [76, 'Configurations_Companies_DownloadFEPrintFormatInAllCompanies',
       'Permiso para descargar los formatos de impresión de todas las compañías'],
  [77, 'Configurations_Groups_DownloadFEPrintFormatInAllGroups',
       'Permiso para descargar el formato de impresión de cualquier grupo'],
  [79, 'Configurations_Groups_Create',       'Permiso para crear grupos'],
  [80, 'Configurations_Groups_UpdateAllInApplication',
       'Permiso para actualización de los grupos de la aplicación'],
  [81, 'Configurations_Companies_DownloadCertificateInAllCompanies',
       'Permiso para descargar certificado de todas las compañías'],
  [83, 'Configurations_Companies_DownloadLogoInAllCompanies',
       'Permiso para descargar el logo de todas las compañías'],
  [85, 'Configurations_MailParser_ViewAllConfigurationsInApplication',
       'Permiso para visualizar todas las configuraciones de mail parser existentes en la aplicación'],
  [86, 'Configurations_Companies_ViewGroupCompanies',
       'Permiso para ver todas las compañías del grupo'],
  [87, 'Configurations_Companies_ViewAllApplicationCompanies',
       'Permiso para ver todas las compañías de la aplicación'],
  [88, 'Configurations_MailParser_UpdateAllProcessingTenantStatus',
       'Permiso para actualizar el estado de las compañías emisoras de todas las bandejas de mail parser'],
  [90, 'Configurations_Companies_ChangeGroup',
       'Permiso para cambiar el grupo de las compañías']
].freeze

# ---------------------------------------------------------------------------
# 3. Permisos que la UI evalúa pero que NO están en ninguno de los dos exports.
#
#    Sin estas filas los nodos de menú y las acciones que dependen de ellos
#    quedan invisibles/deshabilitados para siempre: `AuthorizationService` solo
#    concede lo que existe en `permissions`.
#
#    Se marcan `normal` porque son accesos y acciones por compañía. Sus Id
#    arrancan en 1000 para no chocar con los Id reales que todavía faltan del
#    origen (22, 24, 26, 34, 37, 44-46, 48, 55, 69): si alguno de estos nombres
#    resulta ser uno de esos, su fila se puede insertar en su Id real sin tocar
#    las de acá.
#
#    Ver TODOS.md → "El catálogo de permisos está incompleto".
# ---------------------------------------------------------------------------
CODE_ONLY = [
  [1000, 'Configurations_Security_Access',   'Acceso a Seguridad'],
  [1001, 'Configurations_Users_ManageAccess', 'Administrar accesos de usuarios'],
  [1002, 'Configurations_Numbering_Create',  'Crear numeraciones de emisión'],
  [1003, 'Configurations_Numbering_Update',  'Modificar numeraciones de emisión'],
  [1004, 'Configurations_Numbering_CreateReception', 'Crear numeraciones de recepción'],
  [1005, 'Configurations_Numbering_UpdateReception', 'Modificar numeraciones de recepción'],
  [1006, 'Configurations_Branches_Create',   'Crear sucursales'],
  [1007, 'Configurations_Branches_Update',   'Modificar sucursales'],
  [1008, 'Configurations_EmailInbox_Access', 'Acceso a Bandejas de emisión'],
  [1009, 'Configurations_EmailInbox_Create', 'Crear bandejas de emisión'],
  [1010, 'Configurations_EmailInbox_Update', 'Modificar bandejas de emisión'],
  [1011, 'Configurations_MailParser_Create', 'Crear bandejas de recepción'],
  [1012, 'Configurations_MailParser_Update', 'Modificar bandejas de recepción']
].freeze

# ---------------------------------------------------------------------------
# 4. DADOS DE BAJA — se siembran INACTIVOS.
#
#    Se siguen sembrando (y con su Id de origen) porque el catálogo replica el
#    del .NET: si se omitieran, una importación posterior de `PermissionByRol`
#    que los referencie no encontraría la fila. Pero nacen `is_active: false`
#    porque su pantalla ya no existe y nadie los evalúa.
#
#    Tiene que coincidir con `DEACTIVATE` de
#    `db/migrate/20260812130000_apply_permission_catalog_changes.rb`: esta lista
#    es para la base que se crea de cero, la migración es para la que ya existe,
#    y las dos deben dejar el mismo estado final.
#
#    Ver `db/permission_name_map.yml` → orphaned.
# ---------------------------------------------------------------------------
DEACTIVATED = %w[
  S_CompUser
  Configurations_Users_ViewGroupUsers
  Configurations_Companies_ChangeGroup
  Configurations_Groups_ViewAllApplicationGroups
].to_set.freeze

ADMIN_ROLE_NAME = 'Administrador'

ActiveRecord::Base.transaction do
  # 1. Catálogo. Se reemplaza completo para poder fijar los Id del origen.
  #
  # Hay que vaciar ANTES las dos tablas que referencian `permissions`, o el
  # `delete_all` choca contra sus llaves foráneas. `user_permissions` es la vía de
  # concesión directa (permisos globales por usuario): hoy nace vacía, pero apenas
  # alguien asigne uno, un `db:seed` sin esta línea revienta.
  #
  # ⚠️ `unscoped` obligatorio: los tres modelos tienen `SoftDeletable`, y su
  # `default_scope` hace que un `delete_all` pelado borre SOLO las filas activas.
  # Las revocadas sobreviven, siguen apuntando a `permissions` y la FK falla — que
  # es exactamente lo que pasaba apenas alguien revocaba un permiso de un rol.
  RolePermission.unscoped.delete_all
  UserPermission.unscoped.delete_all
  Permission.unscoped.delete_all

  rows = CATALOG.map        { |id, name, desc| [id, name, desc, 'normal'] } +
         GLOBAL_CATALOG.map { |id, name, desc| [id, name, desc, 'global'] } +
         CODE_ONLY.map      { |id, name, desc| [id, name, desc, 'normal'] }

  rows.each do |id, name, description, type|
    Permission.create!(id: id, name: name, description: description, type: type,
                       is_active: !DEACTIVATED.include?(name))
  end
  puts "Permisos: #{Permission.count} activos " \
       "(#{Permission.normal.count} normal / #{Permission.global.count} global; " \
       "#{CODE_ONLY.size} sin Id de origen) " \
       "+ #{DEACTIVATED.size} dados de baja"

  # 2. Rol Administrador con el catálogo completo.
  admin = Role.find_or_initialize_by(name: ADMIN_ROLE_NAME)
  admin.is_active = true
  admin.save!

  # Sin `unscoped` a propósito: el default_scope de SoftDeletable deja fuera a los
  # de `DEACTIVATED`, que es justo lo que se quiere — no tiene sentido concederle
  # a nadie un permiso dado de baja.
  Permission.find_each do |permission|
    RolePermission.create!(role_id: admin.id, permission_id: permission.id, is_active: true)
  end
  puts "Permisos del rol #{ADMIN_ROLE_NAME}: #{RolePermission.where(role_id: admin.id).count}"

  # 3. El rol se asigna en cada compañía que el usuario ya tenga asignada. Sin esta
  #    fila (user_roles) AuthorizationService devuelve [] aunque el rol exista: los
  #    permisos son por compañía, no globales.
  UsersByCompany.active.find_each do |assignment|
    user_role = UserRole.find_or_initialize_by(
      user_id: assignment.user_id, company_id: assignment.company_id, role_id: admin.id
    )
    user_role.is_active = true
    user_role.save!
  end
  puts "Asignaciones usuario-rol-compañía: #{UserRole.count}"
end

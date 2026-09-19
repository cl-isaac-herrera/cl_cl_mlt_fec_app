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
  # Renombrado desde `S_Company` (§4.4), al migrar los endpoints de la pantalla.
  # La equivalencia vive en `db/permission_name_map.yml`.
  [6,  'Configurations_Companies_ListAccess',
       'Permite acceder a la vista de lista de compañías'],
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
  # Renombrados desde `F_CreateCompany` / `F_ModifyCompany` (§4.4). Ver el map.
  [16, 'Configurations_Companies_Create',   'Permite crear compañías'],
  [17, 'Configurations_Companies_Update',   'Permite actualizar una compañía'],
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
  # Huérfano: gateaba "Aceptación documentos GT", una personalización para un
  # cliente puntual que se eliminó (no es la vista de recepciones original). Ver
  # `db/permission_name_map.yml` → orphaned.
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
# 3b. Permisos GLOBALES nuevos de este producto (no vienen de ningún export).
#
#     Son `global` por el mismo motivo que los `Configurations_Connections_*`:
#     `sl_resources` no lleva `company_id` — las consultas son de la
#     instalación, no de una compañía —, así que el permiso no puede depender de
#     la compañía activa.
#
#     Sus Id siguen la serie de CODE_ONLY (1000+) porque tampoco tienen Id de
#     origen. Tienen que coincidir con `ADD` de
#     `db/migrate/20260814140000_add_sl_resources_permissions.rb`: esta lista es
#     para la base que se crea de cero, la migración para la que ya existe, y las
#     dos deben dejar el mismo estado final.
# ---------------------------------------------------------------------------
CODE_ONLY_GLOBAL = [
  [1013, 'Configurations_SlResources_Access', 'Acceso a la vista de recursos de Service Layer'],
  [1014, 'Configurations_SlResources_Update', 'Permite modificar consultas de Service Layer']
].freeze

# ---------------------------------------------------------------------------
# 4. DADOS DE BAJA — se siembran INACTIVOS.
#
#    Se siguen sembrando (y con su Id de origen) porque el catálogo replica el
#    del .NET: si se omitieran, una importación posterior de `PermissionByRol`
#    que los referencie no encontraría la fila. Pero nacen `is_active: false`
#    porque su pantalla ya no existe y nadie los evalúa.
#
#    Tiene que coincidir con el `DEACTIVATE` de las migraciones que dan de baja
#    permisos (`20260812130000_apply_permission_catalog_changes.rb` y
#    `20260913150000_deactivate_group_permissions.rb`): esta lista es para la base
#    que se crea de cero, las migraciones para la que ya existe, y las dos vías
#    deben dejar el mismo estado final.
#
#    Ver `db/permission_name_map.yml` → orphaned.
# ---------------------------------------------------------------------------
DEACTIVATED = %w[
  S_CompUser
  Configurations_Users_ViewGroupUsers
  Configurations_Companies_ChangeGroup
  S_AcceptDocsGT
  Configurations_Groups_ViewAllApplicationGroups
  S_Groups
  Configurations_Groups_Create
  Configurations_Groups_Update
  Configurations_Groups_UpdateAllInApplication
  Configurations_Groups_DownloadFEPrintFormat
  Configurations_Groups_DownloadFEPrintFormatInAllGroups
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

  rows = CATALOG.map          { |id, name, desc| [id, name, desc, 'normal'] } +
         GLOBAL_CATALOG.map   { |id, name, desc| [id, name, desc, 'global'] } +
         CODE_ONLY.map        { |id, name, desc| [id, name, desc, 'normal'] } +
         CODE_ONLY_GLOBAL.map { |id, name, desc| [id, name, desc, 'global'] }

  rows.each do |id, name, description, type|
    Permission.create!(id: id, name: name, description: description, type: type,
                       is_active: !DEACTIVATED.include?(name))
  end
  puts "Permisos: #{Permission.count} activos " \
       "(#{Permission.normal.count} normal / #{Permission.global.count} global; " \
       "#{CODE_ONLY.size + CODE_ONLY_GLOBAL.size} sin Id de origen) " \
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

# ---------------------------------------------------------------------------
# 5. Consultas al Service Layer (`sl_resources`).
#
#    Cada fila es una lectura a SAP definida como dato: recurso, query OData y
#    tamaño de página. Ver `SlResource`.
#
#    El `resource` de una VISTA (calculation/semantic view) no es el mismo texto
#    en los dos motores, así que no se puede sembrar literal: el prefijo y —en
#    HANA— la caja del nombre dependen de `SERVER_TYPE`. Eso lo resuelve
#    `SlResourceSeed.qualify`; las entidades estándar de SAP (`Orders`,
#    `BusinessPartners`) se siembran tal cual.
# ---------------------------------------------------------------------------

# Calificador del `resource` según el motor de la base. Es el único lugar del
# seed que conoce la diferencia entre HANA y SQL.
module SlResourceSeed
  # El prefijo va SIEMPRE en minúsculas, incluso cuando el nombre de la vista se
  # pasa a mayúsculas por HANA. Es parte del path del Service Layer, no del
  # nombre del objeto de base.
  PREFIXES = { 'HANA' => 'sml.svc/', 'SQL' => 'view.svc/' }.freeze

  module_function

  # Motor de la instalación. Levanta si no está definido o no es uno de los dos
  # válidos: sembrar con el prefijo equivocado deja las consultas apuntando a un
  # path que no existe, y el error recién aparecería al primer request a SAP.
  def server_type
    raw   = ENV['SERVER_TYPE'].to_s.strip
    value = raw.upcase # tolera 'hana'/'sql'; cualquier otra cosa no pasa
    return value if PREFIXES.key?(value)

    detail = raw.empty? ? 'no está definida' : "tiene el valor #{raw.inspect}"
    raise "SERVER_TYPE #{detail}. Valores válidos: #{PREFIXES.keys.join(' | ')}. " \
          'Definila antes de correr bin/rails db:seed — sin ella no se puede ' \
          'saber si las vistas van bajo sml.svc/ (HANA) o view.svc/ (SQL).'
  end

  # Devuelve el `resource` listo para guardar.
  #
  # ⚠️ El orden importa: primero se pasa el NOMBRE a mayúsculas (solo HANA) y
  # recién después se concatena el prefijo. Al revés, el `upcase` se llevaría
  # puesto el prefijo y quedaría 'SML.SVC/…', que no resuelve.
  def qualify(resource, server_type)
    return resource unless resource.to_s.match?(/#{Regexp.escape(SlResource::VIEW_MARKER)}/i)

    name = server_type == 'HANA' ? resource.upcase : resource
    "#{PREFIXES.fetch(server_type)}#{name}"
  end
end

# Export de la tabla de consultas del .NET (32 filas), en el orden del origen.
# Columnas: code, description, resource, query_params, page_size.
#
# Las 32 son `is_standard` (el export las trae todas en 1), así que la bandera se
# aplica en el loop en vez de repetirla por fila — mismo criterio que
# `CATALOG`/`GLOBAL_CATALOG` con `type`. Una consulta propia del cliente iría en
# una constante aparte con `is_standard: false`.
#
# Cuatro cosas que son DATOS del origen y no se corrigen acá:
#   - `resource` va SIN prefijo y con la caja original: los agrega
#     `SlResourceSeed.qualify` según el motor.
#   - `page_size` en 0 significa "sin paginación" (ver `SlResource#paginated?`).
#   - `nil` en `query_params` es el `NULL` del export: la consulta no lleva query.
#   - Los `@Param` y los `#DocumentEntry#` son marcadores que el consumidor
#     sustituye en tiempo de ejecución. No son parte del path.
#
# ⚠️ El `Id` del origen NO se preserva: nada referencia esta tabla por id —la app
# pide las consultas por `code`, que es la llave funcional y tiene índice único.
# Si alguna importación posterior necesitara los ids, hay que fijarlos acá.
SL_RESOURCES = [
  ['GetSuppliers', 'Obtiene los proveedores de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_SUPPLIERS_B1SLQuery',
   '$select=*', 0],
  ['GetTaxes', 'Obtiene un listado de impuestos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_TAXCODES_B1SLQuery',
   '$select=*', 0],
  ['GetUdfs', 'Obtiene la informacion de los UDFS en SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_UDFS_B1SLQuery',
   '$filter=(TableID eq @TableID)', 0],
  ['GetItems', 'Obtiene la informacion de los items desde SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_ITEMS_B1SLQuery',
   '$select=*', 0],
  ['GetDimAndCenterCost', 'Obtiene la informacion de dimensiones y centros de costo de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_DIMENSIONS_AND_CNTERCOST_B1SLQuery',
   '$select=*', 0],
  ['GetAdditionalFreights', 'Obtiene un listado de cargos adicionales de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_ADDITIONALFREIGHTS_B1SLQuery',
   '$select=*', 0],
  ['GetDocTypeBase', 'Obtiene los tipos de bases de los documentos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_DOCTYPEBASE_B1SLQuery',
   '$select=*', 0],
  ['GetAccounts', 'Obtiene todas las cuentas de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_ACCOUNTS_B1SLQuery',
   '$select=*', 0],
  ['GetWarehouses', 'Obtiene un listado de almacenes de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_WAREHOUSES_B1SLQuery',
   '$select=*', 0],
  ['CheckIfExistApInvoice', 'Revisa si ya existe el ApInvoice',
   'CL_D_CL_MLT_FEC_APP_SLT_CHECKIFEXISTAPINVOICE_B1SLQuery',
   '$filter=(U_FeNumProvRef eq @Clave)', 0],
  ['GetUdfsValues', 'Obtiene los valores de los Udfs',
   'CL_D_CL_MLT_FEC_APP_SLT_UDFSVALUES_B1SLQuery',
   '$select=*', 0],
  ['GetTaxesForAutomatic', 'Obtiene los impuestos para la creacion automatica',
   'CL_D_CL_MLT_FEC_APP_SLT_TAXCODEBYAMOUNT_B1SLQuery',
   '$filter=(contains(TaxCode, @TaxCodeVm) and contains(TaxCode,@TaxCodeContains))', 0],
  ['Drafts', 'Crea un documento borrador en SAP',
   'Drafts',
   nil, 0],
  ['PurchaseInvoices', 'Crea un ApInvoice en SAP',
   'PurchaseInvoices',
   nil, 0],
  ['GetMatchAutomaticOne',
   'Obtiene match automaticos, se utiliza este para el filtrado del case 1 en el flujo',
   'CL_D_CL_MLT_FEC_APP_SLT_MATCHAUTOMATIC_B1SLQuery',
   '$filter=(CardCode eq @CardCode and XmlCode eq @XmlCode)', 0],
  ['GetMatchAutomaticTwo', 'Obtiene match automaticos con los filtrados del case 1',
   'CL_D_CL_MLT_FEC_APP_SLT_MATCHAUTOMATIC_B1SLQuery',
   '$filter=(XmlCode eq @XmlCode)', 0],
  ['GetMatchAutomaticUdt', 'Obtiene match automaticos desde UDF',
   'CL_D_CL_MLT_FEC_APP_SLT_MATCHAUTOMATICUDT_B1SLQuery',
   '$filter=(CardCode eq @CardCode and XmlCode eq @XmlCode)', 0],
  ['CheckIfFileExist', 'Verifica si ya existe el archivo en SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_CHECKIFATTACHMENTEXIST_B1SLQuery',
   '$filter=(FileName eq @FileName)', 0],
  ['GetExchangeRate', 'Obtiene el tipo de cambio',
   'CL_D_CL_MLT_FEC_APP_SLT_EXCHANGERATE_B1SLQuery',
   nil, 0],
  ['Attachments2', 'Guarda adjuntos en SAP',
   'Attachments2',
   nil, 0],
  ['GetMatchAutomaticOthersOne', 'Obtiene match automatico con datos de otro receptor',
   'CL_CL_MLT_FEC_SLT_MATCHAUTOMATICORDER_B1SLQuery',
   '$filter=(CardCode eq @CardCode and XmlCode eq @XmlCode and DocNum eq @DocNum ' \
   'and TableName eq @TableName)', 0],
  ['GetMatchAutomaticOthersTwo', 'Obtiene match automatico con datos de otro receptor',
   'CL_CL_MLT_FEC_SLT_MATCHAUTOMATICORDER_B1SLQuery',
   '$filter=(XmlCode eq @XmlCode and DocNum eq @DocNum and TableName eq @TableName)', 0],
  ['GetProjects', 'Obtiene la lista de projyectos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_PROJECTS_B1SLQuery',
   nil, 0],
  ['CheckIfExistApInvoiceByNumAtCard', 'Revisa si ya existe el ApInvoice por NumAtCard',
   'CL_D_CL_MLT_FEC_APP_SLT_CHECKIFEXISTAPINVOICE_B1SLQuery',
   '$filter=(NumAtCard eq @Clave)', 0],
  ['swUploadAttachment2', 'Carga adjuntos en el servidor remoto mediante service layer',
   'Attachments2',
   nil, 0],
  ['GetSapDocuments', 'Obtiene los documentos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_DOCUMENTS_B1SLQuery',
   '$filter=DocType eq @DocType and contains(SearchCriteria, @SearchCriteria)', 0],
  ['ClosePurchaseOrders', 'Endpoint para cerrar documentos de referencia de ordenes de compra',
   'PurchaseOrders(#DocumentEntry#)/Close',
   nil, 0],
  ['ClosePurchaseDeliveryNotes',
   'Endpoint para cerrar documentos de referencia de entradas de mercancias de compra',
   'PurchaseDeliveryNotes(#DocumentEntry#)/Close',
   nil, 0],
  ['ClosePurchaseQuotations',
   'Endpoint para cerrar documentos de referencia de solicitudes de compra',
   'PurchaseQuotations(#DocumentEntry#)/Close',
   nil, 0],
  ['qsGetCurrencies', 'Obtiene las monedas de la compañía mediante service layer',
   'Currencies',
   '$select=Code,Name', 0],
  # Descripción en inglés en el origen. Se deja verbatim, como las erratas del
  # catálogo de permisos: es dato importado, no texto redactado en este repo.
  ['qsGetCompanyLocalCurrency', 'Retrieve the code of the local currency of the company',
   'CompanyService_GetAdminInfo',
   nil, 0],
  # ⚠️ ÚNICA fila que NO se siembra como venía en el export. El origen apuntaba a
  # `Users?$top=1&$select=UserCode`; se cambió a `BusinessPartners` por experiencia
  # de campo: casi todo usuario de SAP tiene permiso para consultar socios de
  # negocio, pero varios NO lo tienen sobre `Users`, y entonces el sondeo fallaba
  # con un error de permisos que se leía como "credenciales inválidas" aunque el
  # `/Login` hubiera funcionado.
  #
  # El recurso da igual para lo que se está probando —el `/Login` que el Client
  # hace antes, ver `Sap::CredentialValidator`—, así que conviene el que menos
  # permisos exige.
  ['qsValidateSapCredentials', 'Valida las credenciales de licencia de SAP',
   'BusinessPartners',
   '$top=1&$select=CardCode', 0]
].freeze

# Consultas que NO vienen del export del .NET: las agregaría este producto. Se
# sembrarían igual que las de arriba (`is_standard: true` — las trae el producto,
# no las escribió el cliente), pero van en una constante aparte para que
# `SL_RESOURCES` siga siendo el export verbatim y se pueda comparar contra el
# origen.
#
# Mismas convenciones: `resource` sin prefijo (lo agrega `SlResourceSeed.qualify`
# según el motor) y `page_size` en 0 cuando no pagina.
#
# La única que hubo antes (`GetCompanyInfo`, que leía la configuración de FE de
# la compañía desde una vista sobre `OADM`) se eliminó cuando esos datos pasaron
# a vivir en la tabla `companies` de la base de la aplicación.
#
# ── Las seis consultas de detalle del documento a emitir ─────────────────────
# Son las que `Sap::DocumentDetails` ejecuta por cada documento que la cola
# devuelve como pendiente. Cada una es una vista (`_B1SLQuery`), así que el
# prefijo lo pone `SlResourceSeed.qualify` según el motor.
#
# ⚠️ TODAS filtran por `@DocEntry` y `@DocType`, que son los dos datos que trae
# el procedimiento `CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS` y lo único que
# identifica un documento dentro de una compañía. `DocEntry` solo es único por
# tabla de SAP: la factura 25 y la nota de crédito 25 comparten número, así que
# filtrar únicamente por `DocEntry` traería líneas de otro documento. Verificar
# que las vistas expongan las dos columnas al crearlas — el esquema documentado
# en `docs/sync-documents-flow.md` lista lo que la vista *devuelve*, no
# necesariamente todo lo que expone para filtrar.
#
# `page_size` en 0 en las seis: la cabecera es una sola fila y no pagina, y las
# listas necesitan TODAS sus filas de un tirón — el header
# `Prefer: odata.maxpagesize` (`Sap::ResourceQuery#headers`) es lo que evita
# que el Service Layer las corte en 20 (`TODOS.md` → SAP, "deuda del acceso a
# Service Layer" — resuelto). Antes de ese header estas cinco llevaban `999`,
# una apuesta a que ningún documento tuviera más líneas que eso; el submódulo
# TODAVÍA no sigue `odata.nextLink`, así que un número positivo que no
# alcanzara se quedaría a medias sin ningún aviso — `0` es el único valor
# honesto mientras eso no exista.
SL_RESOURCES_OWN = [
  ['qsGetDocumentHeaderInfo',
   'Cabecera del documento a emitir, para el envio a Hacienda',
   'CL_D_CL_MLT_FEC_SLT_DOCHEADERINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0],
  ['qsGetDocumentLinesInfo',
   'Lineas de detalle del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCLINESINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0],
  ['qsGetDocumentOtherChargesInfo',
   'Otros cargos del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCOTHERCHARGESINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0],
  ['qsGetDocumentPaymentMethodsInfo',
   'Medios de pago del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCPAYMENTMETHODSINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0],
  ['qsGetDocumentReferenceInfo',
   'Informacion de referencia del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCREFERENCEINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0],
  # Solo se ejecuta cuando la compañía tiene `use_additional_fields` en true
  # (`docs/sync-documents-flow.md` punto 8). La fila se siembra igual: el
  # catálogo describe lo que se puede consultar, no lo que se consulta siempre.
  ['qsGetDocumentOthersInfo',
   'Bloque Otros del documento a emitir (campos adicionales)',
   'CL_D_CL_MLT_FEC_SLT_DOCOTHERSINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0]
].freeze

# ── Actualizar en SAP el resultado del envío a Hacienda ──────────────────────
# Una fila por tipo de documento (los siete que `DocType` conoce que NO son
# mensaje de receptor — `DocType::RECEIVER_MESSAGES` queda fuera: esos no son
# comprobantes que este flujo sincronice). Se PATCHea el objeto de SAP por
# `DocEntry` en cuanto Hacienda responde algo —aceptado, rechazado, o ni
# siquiera eso—, con el body:
#
#   U_CL_FEC_Status, U_CL_FEC_ErrorDetails, U_CL_FEC_Clave,
#   U_CL_FEC_NumConsecutivo, U_CL_FEC_XmlSentUrl, U_CL_FEC_XmlResponseUrl
#
# Son entidades ESTÁNDAR de SAP, no vistas: `resource` no lleva el marcador
# `_B1SLQuery`, así que `SlResourceSeed.qualify` no le agrega prefijo — el
# mismo `code` sirve en SQL Server y en HANA. `#DocumentEntry#` es un marcador
# de PATH (`Sap::ResourceQuery`, no de query), igual que en `ClosePurchaseOrders`
# más arriba: se resuelve a `Invoices(25)` y no a un `$filter`.
#
# `page_size: 0` porque es una escritura, no una lectura paginada — mismo
# criterio que `Drafts`/`PurchaseInvoices` en `SL_RESOURCES`.
#
# ── Qué objeto de SAP le corresponde a cada tipo de documento ────────────────
# El objeto lo determina el tipo de comprobante, no una elección libre:
#
#   FE, ND, TE, FEE → Invoices          (factura de venta, tiquete, nota de
#                                         débito y factura de exportación son,
#                                         los cuatro, el mismo objeto AR Invoice
#                                         de SAP — SAP B1 no tiene un objeto de
#                                         "nota de débito" separado)
#   NC              → CreditNotes       (AR Credit Memo)
#   REP             → IncomingPayments  (el recibo de pago SÍ es un objeto propio)
#   FEC             → PurchaseInvoices  (AP Invoice — factura de compra)
#
# Los seis `U_CL_FEC_*` de arriba son UDFs y su schema (`CLAUDE.md` §32) está
# declarado en DOS archivos, no en cuatro: `OINV` en
# `config/sap_schemas/marketing_documents.json` y `ORCT` en `payments.json`.
#
# `ORIN` (AR Credit Memo, el objeto de `updateDocument03`) y `OPCH` (AP Invoice,
# el de `updateDocument08`) NO necesitan schema propio: son de la misma
# categoría "Marketing Documents" que `OINV`, y SAP B1 replica solo un UDF
# creado en cualquier tabla de esa categoría a todas las demás. `ORCT` sí lo
# necesita porque es "Banking", otra categoría. Confirmado en `TODOS.md` →
# Emisión de documentos (2026-09-07).
#
# El `code` lleva el CÓDIGO NUMÉRICO de Hacienda (`DocType::FE` = '01', no la
# mnemotecnia) — es el mismo valor que trae `Documents::PendingQueue::Entry#doc_type`
# y el que va a usar el llamador para elegir la fila, así que resolverla por el
# código evita traducir de un lado a otro.
SL_RESOURCES_STATUS_UPDATES = [
  ['updateDocument01', 'Actualiza en SAP el resultado del envío a Hacienda de una factura electrónica',
   'Invoices(#DocumentEntry#)', nil, 0],
  ['updateDocument02', 'Actualiza en SAP el resultado del envío a Hacienda de una nota de débito',
   'Invoices(#DocumentEntry#)', nil, 0],
  ['updateDocument03', 'Actualiza en SAP el resultado del envío a Hacienda de una nota de crédito',
   'CreditNotes(#DocumentEntry#)', nil, 0],
  ['updateDocument04', 'Actualiza en SAP el resultado del envío a Hacienda de un tiquete electrónico',
   'Invoices(#DocumentEntry#)', nil, 0],
  ['updateDocument09',
   'Actualiza en SAP el resultado del envío a Hacienda de una factura electrónica de exportación',
   'Invoices(#DocumentEntry#)', nil, 0],
  ['updateDocument08',
   'Actualiza en SAP el resultado del envío a Hacienda de una factura electrónica de compra',
   'PurchaseInvoices(#DocumentEntry#)', nil, 0],
  ['updateDocument10', 'Actualiza en SAP el resultado del envío a Hacienda de un recibo electrónico de pago',
   'IncomingPayments(#DocumentEntry#)', nil, 0]
].freeze

# ── Consulta paginada de documentos, para el listado de documentos emitidos ──
# Una fila por tipo de comprobante que SÍ es un documento (los mensajes de
# receptor — `05`/`06`/`07` — no son comprobantes con `DocEntry` propio en SAP,
# así que quedan fuera, mismo criterio que `SL_RESOURCES_STATUS_UPDATES`).
#
# El `code` lleva el CÓDIGO NUMÉRICO de Hacienda (`getDocuments01`, no
# `getDocumentsFE`) — mismo criterio que `updateDocument01`..`10` de arriba.
#
# ── Las siete apuntan a la MISMA vista, filtradas por `DocType` ─────────────
# `resource` es la vista `CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery`
# (`_B1SLQuery`: `SlResourceSeed.qualify` le agrega el prefijo `sml.svc/`/
# `view.svc/` según el motor) — NO la entidad estándar por tipo que usa
# `SL_RESOURCES_STATUS_UPDATES` (Invoices/CreditNotes/PurchaseInvoices/
# IncomingPayments): esa entidad sigue siendo el destino de las ESCRITURAS
# (`updateDocument01`..`10`, arriba), que no cambian. Solo la LECTURA/listado se
# movió a la vista.
#
# La vista une los cuatro objetos de SAP que sincronizan documentos
# (OINV/ORIN/OPCH/ORCT) y calcula `DocType` con la misma función que arma la
# cola de sincronización, `dbo.CL_D_CL_MLT_FEC_SLT_FEDOCUMENTTYPE`
# (`db/external/sql_server/fe_doc_type_function.sql`) — así que lo único que
# distingue una fila de otra acá es el `$filter=DocType eq '<tipo>'`, horneado
# en el catálogo (no un ajuste por instalación, ver más abajo).
#
# `query_params` lleva el `$filter` y un `$orderby=DocEntry desc` fijo —los
# documentos más recientes primero, sea cual sea la página— para que la
# paginación (`$top`/`$skip`) sea estable entre requests: sin un orden
# explícito, SAP no garantiza devolver las filas siempre en el mismo orden, y
# la página 2 podría repetir o saltarse filas de la página 1. El `$top`/`$skip`
# en sí los agrega el llamador con `Sap::ResourceQuery#merge` en cada página —no
# se hornean acá porque cambian en cada request, no son parte del catálogo.
# Mismo criterio que `GetSapDocuments` (arriba, en `SL_RESOURCES`).
#
# ── Sin `$select`: la vista ya devuelve justo lo que el listado necesita ────
# A diferencia de la entidad estándar (que trae todas las columnas de SAP si no
# se acota), la vista `DOCDISPLAYINFO` se diseñó para este listado: solo expone
# las columnas que hacen falta, así que no hay nada que acotar ni riesgo de que
# un `$select` personalizado omita por accidente una que el listado necesita
# (como pasaba con `U_CL_FEC_XmlSentUrl`/`U_CL_FEC_XmlResponseUrl` contra la
# entidad estándar).
#
# ⚠️ La vista RENOMBRA algunos UDFs al exponerlos — el JSON que devuelve NO usa
# los mismos nombres que la entidad estándar (`Sap::IssuedDocumentsSearch` y
# `documents_issued_controller.js#mapDocument` ya están al tanto, pero
# cualquier consumidor nuevo tiene que usar el nombre de la VISTA, no el UDF):
#
#   UDF (entidad estándar)      → columna de la vista
#   U_CL_FEC_Status             → FEDocumentStatus
#   U_CL_FEC_ErrorDetails       → ErrorMessage
#   U_CL_FEC_XmlSentUrl         → XmlSentUrl
#   U_CL_FEC_XmlResponseUrl     → XmlResponseUrl
#   U_CL_FEC_Clave              → Clave
#   U_CL_FEC_NumConsecutivo     → NumeroConsecutivo
#   U_CL_FEC_FechaEmision       → FechaEmision
#
# ⚠️ Corregido: esta nota decía antes que `U_CL_FEC_Clave`/
# `U_CL_FEC_NumConsecutivo` SÍ conservaban su nombre de UDF. Es falso contra la
# vista real — pedirle esos dos nombres devuelve `nil` sin ningún error, y eso
# dejaba la columna "N° FE" y la Clave del panel de información siempre vacías.
# El mismo error se repitió con `U_CL_FEC_FechaEmision` (corregido 2026-09-19,
# `documents_issued_controller.js#mapDocument`): la fecha de emisión del panel
# "Información del documento" quedaba siempre vacía por la misma razón.
#
# `DocEntry`, `DocDate`, `CardCode`, `CardName`, `DocCurrency` y `DocNum` SÍ
# conservan su nombre. La vista además expone `PdfUrl`, que no existe en la
# entidad estándar — pendiente de aprovechar para la acción "Ver/Descargar
# comprobante" (`TODOS.md` → Emisión de documentos, hoy bloqueada porque el
# PDF salía de un Crystal Report sin URL accesible).
#
# ⚠️ `page_size: 0` a propósito, y NO un valor alto tipo 999: aunque
# `Sap::ResourceQuery#headers` ya manda `Prefer: odata.maxpagesize` (resuelto
# en `TODOS.md` → SAP, "deuda del acceso a Service Layer"), el submódulo
# (`Clavisco::ServiceLayer::Client`) TODAVÍA no sigue `odata.nextLink`. Un
# `page_size` positivo pide páginas de ese tamaño; si SAP tuviera más filas
# coincidentes que esa página, la respuesta se quedaría a medias sin que nadie
# lo note. `0` es el único valor que pide TODO en una sola respuesta, así que
# es el único honesto mientras el submódulo no siga `nextLink`.
#
# Esto no cambia cómo pagina `Sap::IssuedDocumentsSearch`: sigue armando su
# propio `$top`/`$skip` por request (`Sap::ResourceQuery#merge`), acotado a
# `MAX_PAGE_SIZE` para no pasarse de una sola página — el listado sigue sin
# `Total` hasta que el submódulo siga `nextLink`.
#
# ── Ya NO hace falta el `$filter` de Series por instalación ────────────────
# Antes de la vista, `Invoices` (compartida por FE/ND/TE/FEE dentro de SAP) no
# tenía columna `DocType`: lo único que distinguía un subtipo de otro era la
# `Series` de numeración, configurada por instalación, así que ese `$filter` se
# agregaba a mano en la fila `sl_resources` de cada cliente (pantalla de
# mantenimiento, `Configurations_SlResources_Update`). La vista SÍ tiene
# `DocType`, así que ese ajuste por instalación deja de hacer falta — el
# `$filter=DocType eq '<tipo>'` de acá alcanza solo, igual en todas las
# instalaciones. `Sap::IssuedDocumentsSearch` (el consumidor) sigue sin conocer
# ninguno de los dos: solo agrega los filtros que varían por request (fechas,
# receptor, etc.) al `$filter` que la fila ya trae.
SL_RESOURCES_DOCUMENT_QUERIES = [
  ['getDocuments01', 'Obtiene el listado paginado de facturas electrónicas desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '01'&$orderby=DocEntry desc", 0],
  ['getDocuments02', 'Obtiene el listado paginado de notas de débito electrónicas desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '02'&$orderby=DocEntry desc", 0],
  ['getDocuments03', 'Obtiene el listado paginado de notas de crédito electrónicas desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '03'&$orderby=DocEntry desc", 0],
  ['getDocuments04', 'Obtiene el listado paginado de tiquetes electrónicos desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '04'&$orderby=DocEntry desc", 0],
  ['getDocuments08', 'Obtiene el listado paginado de facturas electrónicas de compra desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '08'&$orderby=DocEntry desc", 0],
  ['getDocuments09', 'Obtiene el listado paginado de facturas electrónicas de exportación desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '09'&$orderby=DocEntry desc", 0],
  ['getDocuments10', 'Obtiene el listado paginado de recibos electrónicos de pago desde SAP',
   'CL_D_CL_MLT_FEC_SLT_DOCDISPLAYINFO_B1SLQuery',
   "$filter=DocType eq '10'&$orderby=DocEntry desc", 0]
].freeze

# ── Cola de correos de recepción electrónica (UDT `@CL_FEC_MAILSDETAILS`) ───
# Las cinco consultas que `Sap::MailQueue` necesita para leer/crear/actualizar
# filas de la UDT declarada en `config/sap_schemas/outgoing_mails_udt.json`
# (ver `SyncIssuedDocumentsJob#queue_receipt_mail` y `SendElectronicReceiptJob`).
#
# Las DOS lecturas de una sola fila no son redundantes, resuelven preguntas
# distintas: `getDocumentMailByCode` lee por llave y la usa el ENVÍO, que ya sabe
# cuál correo manda (el `Code` viaja en la fila de la cola);
# `getPendingDocumentMail` busca por documento y la usa el ENCOLADO, que todavía
# no lo sabe. Ver el comentario de cada una más abajo.
#
# ── La UDT tiene DOS nombres, y acá va el de OData ───────────────────────────
# `@CL_FEC_MAILSDETAILS` es el nombre SQL/DI-API: el que declara el schema y el
# que usa `UserTablesMD` (la metadata, `vendor/clavisco/sap_udfs`). Los DATOS
# de una UDT los expone el Service Layer como un entity set aparte, con el
# prefijo `U_` — `U_CL_FEC_MAILSDETAILS` —, igual que a los UDFs de un documento
# los expone como `U_CL_FEC_Clave`. Mandar el nombre con `@` devuelve
# `SL error: Service Not Found`, que es lo que dejó sin fila en la UDT a los
# documentos emitidos el 2026-09-10 (`db/migrate/20260910123000_*`).
#
# `SlResourceSeed.qualify` NO interviene: no es una vista (`_B1SLQuery`), así
# que no lleva el prefijo `view.svc/`/`sml.svc/` y el mismo `resource` sirve en
# SQL Server y en HANA (mismo criterio que `SL_RESOURCES_STATUS_UPDATES`).
#
# ⚠️ La llave del update va SIN comillas (`(#Code#)` y no `('#Code#')`): la
# tabla es `bott_NoObjectAutoIncrement`, así que su `Code` es numérico y
# citarlo hace fallar la petición. Una UDT de las otras categorías, con `Code`
# alfanumérico, sí las necesitaría.
#
# El `$filter` de `getPendingDocumentMail` excluye `U_Status = 4` (Enviado) y
# `= 5` (Omitido, ver `Documents::MailQueue::STATUS_SKIPPED`): filtrar en SAP
# evita traer filas ya resueltas y decidir acá cuál es "la vigente".
#
# ⚠️ Su `$orderby=Code desc` NO es decorativo. Desde que existe el botón
# "Reenviar" (`Api::Documents::MailsController#create`) un documento puede tener
# DOS filas sin terminar: el envío que quedó en Error y el reenvío que alguien
# acaba de pedir. `Sap::MailQueue#find` se queda con la primera, y tiene que ser
# la NUEVA — la que trae los destinatarios recién elegidos. Sin el orden, el
# reintento le mandaba el correo al destinatario viejo y dejaba el reenvío
# pendiente para siempre. Lo agrega `20260912140000` en una instalación ya
# sembrada.
#
# ── `getDocumentMails` es lo contrario, y por eso es una fila aparte ─────────
# Alimenta el panel "Correos" del listado de emitidos
# (`documents_issued_controller.js`), que muestra el HISTORIAL: ahí las filas
# que más importan son justamente las ya enviadas, las que
# `getPendingDocumentMail` deja fuera. Reemplaza a `spGetOutgoingMails` del .NET,
# que leía la tabla `OutgoingMails` de la base propia — ese detalle ahora vive en
# la UDT, junto al documento, igual que el historial de intentos
# (`SL_RESOURCES_DOC_SYNC_ATTEMPTS`).
#
# Ordena por `Code` —la llave que SAP autoincrementa en la UDT— y no por
# `U_CreatedAt`, que es texto (`db_Alpha(25)`); `desc` deja arriba el correo más
# reciente, como el `ORDER BY Om.CreateDate desc` del SP que reemplaza.
#
# `page_size: 0` en las cuatro: las dos lecturas devuelven el puñado de filas de
# un solo documento y las otras dos son escrituras — mismo criterio que
# `SL_RESOURCES_STATUS_UPDATES`.
#
# ── Ni la UDT ni estos `code` dicen ya "cola" ───────────────────────────────
# La UDT se llamaba `@CL_FEC_MAILSQUEUE` y pasó a `@CL_FEC_MAILSDETAILS` porque
# lo que guarda es el DETALLE del correo (destinatarios, remitente, estado
# visible en SAP) y no la cola: cuándo reintentar lo decide la cola externa
# (`Documents::MailQueue`, `CLAUDE.md` §37). Los `code` arrastraron el nombre
# viejo un tiempo más —`getMailInformation`, `createMailQueue`,
# `updateMailQueue`— y también se corrigieron.
#
# Acá quedan los nombres nuevos; las tres migraciones corrigen una instalación
# ya sembrada, porque el seed NO alcanza: se saltea las consultas que el cliente
# personalizó desde la pantalla de mantenimiento (`is_standard = false`), y ahí
# la fila se quedaría con el nombre viejo — el `resource` respondería
# `Service Not Found` y el `code` levantaría `UnknownResource`.
#
#   20260907162000  qsGetMailQueueByDocument → getMailInformation
#   20260911150000  el `resource`: MAILSQUEUE → MAILSDETAILS
#   20260912110000  los `code`: → getPendingDocumentMail / create… / update…
#
# Las tres renombran EN EL LUGAR (mismo `id`) para no perder una personalización
# de `query_params`. Un delete + insert la borraría sin avisar.
SL_RESOURCES_MAIL_QUEUE = [
  ['getPendingDocumentMail',
   'Correo de recepción electrónica pendiente de envío de un documento (UDT)',
   'U_CL_FEC_MAILSDETAILS',
   '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType and U_Status ne 4 and U_Status ne 5)' \
   '&$orderby=Code desc', 0],
  ['createDocumentMail',
   'Registra el correo de recepción electrónica de un documento (UDT)',
   'U_CL_FEC_MAILSDETAILS', nil, 0],
  ['updateDocumentMail',
   'Actualiza el estado del correo de recepción electrónica de un documento (UDT)',
   'U_CL_FEC_MAILSDETAILS(#Code#)', nil, 0],
  ['getDocumentMails',
   'Historial de correos de recepción electrónica de un documento (UDT)',
   'U_CL_FEC_MAILSDETAILS',
   '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=Code desc', 0],
  ['getDocumentMailByCode',
   'Correo de recepción electrónica de un documento, por su Code (UDT)',
   'U_CL_FEC_MAILSDETAILS(#Code#)', nil, 0]
].freeze

# ── Datos del comprobante para el correo de recepción electrónica ───────────
# UNA sola fila, no una por tipo: apunta a la vista
# `CL_D_CL_MLT_FEC_SLT_DOCMAILINFO_B1SLQuery` (`SlResourceSeed.qualify` le
# agrega el prefijo `sml.svc/`/`view.svc/` según el motor) y filtra por
# `DocType` con un binding DINÁMICO (`@DocType`), no con un literal horneado
# en el catálogo — a diferencia de `SL_RESOURCES_DOCUMENT_QUERIES`
# (`getDocuments01`..`10`), que sí necesita una fila por tipo porque el
# `$filter` alimenta un listado que el usuario elige por tipo desde la
# pantalla. Acá `Sap::MailDocumentInfo` ya recibe el tipo como parámetro
# (`doc_type`), así que no hay ninguna razón para hornear un literal por fila:
# el mismo binding que ya resuelve `@DocEntry` resuelve `@DocType`.
#
# La consume `Sap::MailDocumentInfo` (`SendElectronicReceiptJob`) para armar
# el cuerpo del correo: consecutivo, receptor, clave, fecha de emisión, monto,
# moneda, estado y las URLs de Azure de los XML a adjuntar. NO la entidad
# estándar por tipo (`Invoices`/`CreditNotes`/`PurchaseInvoices`/
# `IncomingPayments`) que siguen usando `SL_RESOURCES_STATUS_UPDATES`/
# `SL_RESOURCES_DOCUMENT_QUERIES` para las escrituras y el listado.
#
# ── Sin `$select`: la vista ya devuelve justo lo que el correo necesita ─────
# Mismo criterio que `DOCDISPLAYINFO`: la vista se diseñó para este consumidor
# y solo expone las columnas que hacen falta, así que no hay nada que acotar.
# La vista además resuelve el monto en la moneda correcta: `DocTotal` ya viene
# en la moneda que dice `DocCurrency` (antes había que elegir entre `DocTotal`
# y `DocTotalFc` según la moneda del documento; la vista se encarga).
#
# ── La vista RENOMBRA los mismos UDFs que `DOCDISPLAYINFO` ──────────────────
#   UDF (entidad estándar)      → columna de la vista
#   U_CL_FEC_Status             → Status
#   U_CL_FEC_XmlSentUrl         → XmlSentUrl
#   U_CL_FEC_XmlResponseUrl     → XmlResponseUrl
#   U_CL_FEC_Clave              → Clave
#   U_CL_FEC_NumConsecutivo     → NumeroConsecutivo
#   U_CL_FEC_FechaEmision       → FechaEmision
# `DocEntry`, `DocType`, `CardName`, `DocCurrency` y `DocTotal` conservan su
# nombre. `Sap::MailDocumentInfo`/`Documents::ReceiptMailBody`/
# `SendElectronicReceiptJob` ya están al tanto — cualquier consumidor nuevo
# tiene que usar el nombre de la VISTA, no el UDF.
#
# ── Validar el tipo ya NO es "¿existe la fila?" ─────────────────────────────
# Con una fila por tipo, un `doc_type` no soportado (un mensaje de receptor,
# o un código que `DocType` no reconoce) levantaba `UnsupportedDocType` porque
# `Sap::ResourceQuery` no encontraba la fila (`UnknownResource`). Con una sola
# fila para los siete tipos, esa señal desaparece: `Sap::MailDocumentInfo`
# valida el tipo ANTES de tocar SAP (`DocType.valid? && !receiver_message?`).
#
# ── Por qué sigue siendo una consulta de COLECCIÓN (`$filter=…`) y no una
# entidad puntual (`Invoices(#DocumentEntry#)`) ─────────────────────────────
# `Sap::MailDocumentInfo` le suma al `$filter` `Status eq 6` cuando
# `company.send_rejected_documents?` es `false` (mismo patrón que
# `Sap::IssuedDocumentsSearch#extra_filter`, combinando con `Sap::ResourceQuery
# #merge`) — una entidad puntual no admite esa composición, y un documento
# Rechazado con la compañía en `false` tiene que devolver CERO filas (la señal
# que el job usa para marcar `Omitido` en vez de enviar el correo).
SL_RESOURCES_MAIL_DOCUMENT_INFO = [
  ['getMailDocumentInfo', 'Datos del comprobante para el correo de recepción electrónica',
   'CL_D_CL_MLT_FEC_SLT_DOCMAILINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0]
].freeze

# ── Estado y detalle de error ACTUALES de un documento ──────────────────────
# Las consume `Api::DocumentsController#show`, que es lo que el panel
# "Información del documento" del listado pide cada vez que se abre
# (`documents_issued_controller.js` → `#loadErrorDetails`). El listado NO
# arrastra estos dos campos a propósito: la sincronización los pisa
# constantemente (reprocesos, `CheckSentDocumentsJob`), así que el valor que
# trajo la búsqueda puede estar viejo frente al del documento.
#
# ── Por qué la ENTIDAD y no la vista de cabecera ────────────────────────────
# Antes esto salía de `qsGetDocumentHeaderInfo`, reutilizando la consulta que
# ya usa `Sap::DocumentDetails`. No sirve: esa es una SQL Query view y devuelve
# sus propios alias (`Status`, `ErrDetails`), no los nombres de los UDFs, así
# que había que leerla con nombres que no se parecen a los del campo real —y
# además trae la cabecera completa (67 columnas) para usar dos.
#
# Contra la entidad (`Invoices(#DocEntry#)`) el `$select` SÍ es confiable: la
# advertencia de `CheckSentDocumentsJob#header_for` sobre `$select` aplica a
# las vistas (`view.svc`/`sml.svc`), que no son entidades OData nativas.
#
# Una entidad puntual por llave —no un `$filter`— porque acá no hay nada que
# componer: es un documento, por `DocEntry`. Ese es justo el caso que
# `SL_RESOURCES_MAIL_DOCUMENT_INFO` NO podía usar (le suma un filtro de estado
# según la compañía).
#
# Mismo universo y mismo mapeo tipo→entidad que las otras tres familias:
# `Invoices` para FE/ND/TE/FEE, `CreditNotes` para NC, `PurchaseInvoices` para
# FEC, `IncomingPayments` para REP. Los mensajes de receptor (05/06/07) no
# tienen fila: no son comprobantes de este flujo y `#show` los rechaza antes
# de llegar al catálogo.
SL_RESOURCES_DOCUMENT_ERROR_DETAILS = [
  ['getDocumentErrorDetails01', 'Estado y detalle de error actuales de una factura electrónica',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0],
  ['getDocumentErrorDetails02', 'Estado y detalle de error actuales de una nota de débito electrónica',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0],
  ['getDocumentErrorDetails03', 'Estado y detalle de error actuales de una nota de crédito electrónica',
   'CreditNotes(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0],
  ['getDocumentErrorDetails04', 'Estado y detalle de error actuales de un tiquete electrónico',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0],
  ['getDocumentErrorDetails08', 'Estado y detalle de error actuales de una factura electrónica de compra',
   'PurchaseInvoices(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0],
  ['getDocumentErrorDetails09', 'Estado y detalle de error actuales de una factura electrónica de exportación',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0],
  ['getDocumentErrorDetails10', 'Estado y detalle de error actuales de un recibo electrónico de pago',
   'IncomingPayments(#DocEntry#)', '$select=U_CL_FEC_Status,U_CL_FEC_ErrorDetails', 0]
].freeze

# ── URLs de los XML archivados de un documento ──────────────────────────────
# Las dos direcciones de Azure que escribió `Sap::DocumentStatus` cuando el
# documento se sincronizó: `U_CL_FEC_XmlSentUrl` (el comprobante firmado que se
# envió) y `U_CL_FEC_XmlResponseUrl` (lo que devolvió Hacienda). Las consume
# `Api::Documents::XmlFilesController`, que baja el blob con
# `Documents::XmlArchive.fetch` — el XML no está en SAP, solo su dirección.
#
# ── Por qué el servidor las vuelve a pedir si el listado ya las trajo ────────
# Porque una URL que llega del cliente es una URL que el cliente eligió:
# bastaría cambiarle la carpeta (`<contenedor>/<cédula>/…`) para bajar el XML de
# otro contribuyente con las credenciales de Azure de la instalación. La URL que
# trae el listado decide si la acción se OFRECE; la que se baja la resuelve el
# servidor por `DocEntry` contra la compañía activa.
#
# ── Por qué una familia aparte y no dos campos más en `getDocumentErrorDetails` ──
# Mismo criterio que esa familia frente a `qsGetDocumentHeaderInfo`: el `code`
# dice qué devuelve la consulta. Sumarle dos campos que no son ni el estado ni
# el detalle de error dejaría un nombre que miente, y el panel de información
# pagaría el `$select` más ancho sin usarlo.
#
# Mismo universo, mismo mapeo tipo→entidad y misma consulta por llave que
# `SL_RESOURCES_DOCUMENT_ERROR_DETAILS`.
SL_RESOURCES_DOCUMENT_XML_URLS = [
  ['getDocumentXmlUrls01', 'URLs de los XML archivados de una factura electrónica',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0],
  ['getDocumentXmlUrls02', 'URLs de los XML archivados de una nota de débito electrónica',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0],
  ['getDocumentXmlUrls03', 'URLs de los XML archivados de una nota de crédito electrónica',
   'CreditNotes(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0],
  ['getDocumentXmlUrls04', 'URLs de los XML archivados de un tiquete electrónico',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0],
  ['getDocumentXmlUrls08', 'URLs de los XML archivados de una factura electrónica de compra',
   'PurchaseInvoices(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0],
  ['getDocumentXmlUrls09', 'URLs de los XML archivados de una factura electrónica de exportación',
   'Invoices(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0],
  ['getDocumentXmlUrls10', 'URLs de los XML archivados de un recibo electrónico de pago',
   'IncomingPayments(#DocEntry#)', '$select=U_CL_FEC_XmlSentUrl,U_CL_FEC_XmlResponseUrl', 0]
].freeze

# ── Historial de intentos de sincronización de un documento (UDT) ───────────
# La UDT `@CL_FEC_DOCSYNCATTMP` (`config/sap_schemas/doc_sync_attempts_udt.json`),
# que reemplazó a la tabla `DocumentAttemptDetails` de la base de la cola: el
# detalle de cada intento vive en SAP, junto al documento, y la cola externa se
# queda solo con cuándo reintentar. Las consume `Sap::DocSyncAttempts`.
#
# Dos filas, no tres (a diferencia de `SL_RESOURCES_MAIL_QUEUE`): un intento se
# escribe una vez y no se vuelve a tocar, así que no hay `update`.
#
# `page_size: 0` en las dos: la escritura no pagina y el historial de un
# documento son unos pocos intentos — el mismo criterio que la cola de correos.
#
# El `$orderby` va en el catálogo y no en el código: el orden es parte de la
# consulta (`Sap::DocSyncAttempts#list` devuelve lo que SAP le dé), y así se
# puede ajustar desde la pantalla de mantenimiento como cualquier otra.
SL_RESOURCES_DOC_SYNC_ATTEMPTS = [
  ['createDocSyncAttempt',
   'Registra un intento de sincronización de un documento (UDT)',
   'U_CL_FEC_DOCSYNCATTMP', nil, 0],
  ['getDocSyncAttempts',
   'Historial de intentos de sincronización de un documento (UDT)',
   'U_CL_FEC_DOCSYNCATTMP',
   '$filter=(U_DocEntry eq @DocEntry and U_DocType eq @DocType)&$orderby=U_CreatedAt desc', 0]
].freeze

# ── Sucursales del emisor (UDT) ─────────────────────────────────────────────
# La UDT `@CL_FEC_SUCURSALES` (`config/sap_schemas/sucursales_udt.json`), que
# reemplaza a la tabla `Sucursal` de la base del .NET y sus tres SP
# (`spGetSucursalByCompany`, `spCreateSucursal`, `spUpdateSucursal`). Las
# consume `Sap::Branches` desde la pantalla /configurations/branches; la
# emisión ya las leía desde acá (`Documents::UnifiedBuilder#emisor`).
#
# `CompanyId` no aparece por ningún lado, a diferencia de la tabla del .NET: la
# compañía ES la base de SAP contra la que se consulta.
#
# ── El `$filter` de la lista lo arma el request, no el catálogo ─────────────
# `getBranches` viene SIN `$filter`: la pantalla filtra por alias, ubicación y
# estado, y esas condiciones cambian en cada búsqueda. `Sap::Branches` se las
# suma con `and` al que traiga la fila (`Sap::ResourceQuery#merge`), así que una
# instalación que quiera acotar la consulta desde la pantalla de mantenimiento
# puede agregarle el suyo sin que el código lo pise — mismo patrón que
# `getDocuments<tipo>` con la `Series`.
#
# ⚠️ El `$orderby` SÍ va acá, y no es decorativo: sin un orden explícito SAP no
# garantiza devolver las filas siempre igual, y `$top`/`$skip` empezarían a
# repetir o saltarse sucursales entre una página y la siguiente. Mismo motivo
# que el `$orderby=DocEntry desc` de `SL_RESOURCES_DOCUMENT_QUERIES`.
#
# ⚠️ La llave del `get`/`update` va SIN comillas (`(#Code#)` y no `('#Code#')`):
# la UDT es `bott_NoObjectAutoIncrement`, así que su `Code` es numérico y
# citarlo hace fallar la petición — igual que en `SL_RESOURCES_MAIL_QUEUE`.
#
# `page_size: 0` en las cuatro: la paginación real la manda el request
# (`$top`/`$skip`, acotada por `Sap::Branches::MAX_PAGE_SIZE`) y las otras tres
# son una entidad por llave o una escritura.
SL_RESOURCES_BRANCHES = [
  ['getBranches',
   'Sucursales del emisor de la compañía (UDT)',
   'U_CL_FEC_SUCURSALES',
   '$orderby=U_SucursalNum asc', 0],
  ['getBranchByCode',
   'Sucursal del emisor por su Code (UDT)',
   'U_CL_FEC_SUCURSALES(#Code#)', nil, 0],
  ['createBranch',
   'Registra una sucursal del emisor (UDT)',
   'U_CL_FEC_SUCURSALES', nil, 0],
  ['updateBranch',
   'Actualiza una sucursal del emisor (UDT)',
   'U_CL_FEC_SUCURSALES(#Code#)', nil, 0]
].freeze

# Códigos de actividad económica de la compañía, en la UDT
# `@CL_FEC_ACTIVITYCODE` (`config/sap_schemas/activity_codes_udt.json`).
# Reemplazan la tabla `ActivityCode` de la base del .NET
# (`spGetActivityCodesByCompany`, `spSaveCompanyActivityCodes` — este último
# reemplazaba la lista ENTERA en cada guardado). Los consume
# `Sap::ActivityCodes` desde la sección "Códigos de actividad" del formulario
# de compañías; sin `destroy`, un código se inactiva con `Active: N`.
#
# Mismo criterio que `SL_RESOURCES_BRANCHES` en todo lo demás: sin
# `CompanyId` (la compañía ES la base de SAP), `$filter` lo arma el request y
# no el catálogo, `$orderby` explícito para que `$top`/`$skip` no repita ni
# salte filas entre páginas, y la llave del `get`/`update` SIN comillas
# (`Code` es numérico, autoincremental).
SL_RESOURCES_ACTIVITY_CODES = [
  ['getActivityCodes',
   'Códigos de actividad económica de la compañía (UDT)',
   'U_CL_FEC_ACTIVITYCODE',
   '$orderby=U_ActivityCode asc', 0],
  ['getActivityCodeByCode',
   'Código de actividad por su Code (UDT)',
   'U_CL_FEC_ACTIVITYCODE(#Code#)', nil, 0],
  ['createActivityCode',
   'Registra un código de actividad económica (UDT)',
   'U_CL_FEC_ACTIVITYCODE', nil, 0],
  ['updateActivityCode',
   'Actualiza un código de actividad económica (UDT)',
   'U_CL_FEC_ACTIVITYCODE(#Code#)', nil, 0]
].freeze

# ── Mensaje receptor de un documento recibido de un proveedor (UDTs) ────────
# Las siete UDTs de `config/sap_schemas/reception_messages_udt.json` y sus
# seis hijas (`config/sap_schemas/README.md` §6) — cabecera + líneas +
# surtido + medios de pago + otros cargos + otros + referencias. Las escribe
# `Sap::ReceptionMessages`, llamado desde `MailReceptionJob` al identificar
# un XML de comprobante (FE/ND/NC — únicos tipos que se recepcionan,
# `MailReception::IncomingDocument::SUPPORTED_DOC_TYPES`) entre los adjuntos
# de un correo de recepción.
#
# Solo `create*`: todavía no hay pantalla que LEA estas UDTs — la decisión
# manual de aceptar/rechazar (Prioridad 3, CLAUDE.md §41) sigue sin
# implementar. Agregar `get*`/`update*` cuando esa pantalla exista, no antes.
#
# Sin `CompanyId` ni `DocEntry`/`DocType` como llave (a diferencia de
# `SL_RESOURCES_DOC_SYNC_ATTEMPTS`): la compañía ES la base de SAP, y el
# documento recibido no tiene `DocEntry` propio hasta crear la factura de
# compra. La llave entre cabecera e hijas es el `Code` autonumérico que
# devuelve cada `POST`, que `Sap::ReceptionMessages` pasa a mano en el cuerpo
# de la hija (`U_MensajeReceptorCode`/`U_MensajeReceptorLineaCode`).
SL_RESOURCES_RECEPTION_MESSAGES = [
  ['createReceptionMessage',
   'Registra la cabecera de un mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTORMSG', nil, 0],
  ['createReceptionMessageLine',
   'Registra una línea de detalle de un mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTORLIN', nil, 0],
  ['createReceptionMessageLineDetail',
   'Registra un detalle de surtido de una línea de mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTORSURT', nil, 0],
  ['createReceptionMessagePayment',
   'Registra un medio de pago de un mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTORPAGO', nil, 0],
  ['createReceptionMessageOtherCharge',
   'Registra un otro cargo de un mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTORCARG', nil, 0],
  ['createReceptionMessageOther',
   'Registra un dato "otros" de un mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTOROTRO', nil, 0],
  ['createReceptionMessageReference',
   'Registra una referencia de un mensaje receptor (UDT)',
   'U_CL_FEC_RECEPTORREF', nil, 0]
].freeze

ActiveRecord::Base.transaction do
  # Se resuelve ANTES de tocar la base: si `SERVER_TYPE` está mal, el seed corta
  # sin haber escrito ninguna fila.
  server_type = SlResourceSeed.server_type

  preserved = 0

  all_sl_resources = SL_RESOURCES + SL_RESOURCES_OWN + SL_RESOURCES_STATUS_UPDATES +
                     SL_RESOURCES_DOCUMENT_QUERIES + SL_RESOURCES_MAIL_QUEUE +
                     SL_RESOURCES_MAIL_DOCUMENT_INFO + SL_RESOURCES_DOCUMENT_ERROR_DETAILS +
                     SL_RESOURCES_DOCUMENT_XML_URLS + SL_RESOURCES_DOC_SYNC_ATTEMPTS +
                     SL_RESOURCES_BRANCHES + SL_RESOURCES_ACTIVITY_CODES + SL_RESOURCES_RECEPTION_MESSAGES
  all_sl_resources.each do |code, description, resource, query_params, page_size|
    # `unscoped`: una consulta dada de baja tiene que reactivarse, no duplicarse.
    # El índice único de `code` no excluye a las inactivas, así que sin esto el
    # `find_or_initialize_by` no la encontraría e intentaría insertar otra igual.
    record = SlResource.unscoped.find_or_initialize_by(code: code)

    # ⚠️ Una consulta que el cliente editó (`is_standard = false`, lo marca
    # `PATCH /api/sl_resources/:id`) NO se vuelve a escribir: el seed le pisaría
    # el ajuste y encima la devolvería a "Estándar". Es la razón de ser de la
    # bandera. Efecto secundario asumido: si se cambia `SERVER_TYPE`, estas filas
    # se quedan con el prefijo del motor anterior y hay que corregirlas desde la
    # pantalla — preservar el trabajo del cliente pesa más que recalificarlas.
    if record.persisted? && !record.is_standard
      preserved += 1
      next
    end

    record.description  = description
    record.resource     = SlResourceSeed.qualify(resource, server_type)
    record.query_params = query_params
    record.page_size    = page_size
    record.is_standard  = true
    record.is_active    = true
    record.save!
  end

  puts "Consultas de Service Layer (#{server_type}): #{SlResource.count} " \
       "(#{SlResource.views.count} vistas" \
       "#{preserved.positive? ? "; #{preserved} personalizadas, sin tocar" : ''})"
end

# ---------------------------------------------------------------------------
# 6. Ajustes de la instalación (`settings`).
#
#    Cada fila se declara ACÁ y sin valor: el catálogo es del producto, el valor
#    lo pone el operador desde Configuraciones → Generales. `code`, `group_code`,
#    `description` e `is_visible` son metadatos y la interfaz no los edita.
#
#    ⚠️ ESTE SEED NO BORRA. Es la diferencia con el de `permissions`, que hace
#    `delete_all` para poder forzar los Id del origen. Acá los valores son
#    secretos que escribió el operador —credenciales de base de datos, la
#    contraseña de Crystal—: un `delete_all` los borraría y la instalación
#    quedaría muda hasta que alguien los volviera a escribir a mano, sin ningún
#    error que dijera qué pasó. El seed hace upsert por `code` y **nunca asigna
#    `value`** — con UNA excepción: `HACIENDA_XADES_SETTINGS`, más abajo, donde
#    el valor es un dato del producto (la política de firma de Hacienda) y no
#    algo que el operador configure; ese grupo SÍ se reafirma en cada corrida.
#
#    Ver `db/setting_code_map.yml` para la equivalencia con los `code` del .NET.
# ---------------------------------------------------------------------------

# Grupo de conexión a la base externa de documentos.
#
# El grupo describe el destino COMPLETO, pero los campos no significan lo mismo
# en los dos motores. Lo resuelve el dialecto (`ExternalDb::Dialect::*`); acá se
# documenta para que quien llene la pantalla sepa qué escribir:
#
#   SQL Server │ Server=CLSQL01;Database=CL_DOCS      → PORT casi nunca hace
#              │                                        falta (1433 implícito)
#   HANA       │ SERVERNODE=clhna721:30015            → PORT OBLIGATORIO, y
#              │                                        DATABASE no va en el DSN:
#              │                                        califica cada consulta
#              │                                        (CALL <db>.SP1)
DOCS_DB_SETTINGS = [
  # code                          description                                              is_visible
  ['DOCS_DB_ODBC_ENGINE',         'Motor de la base de documentos (SQL o HANA)',            true],
  ['DOCS_DB_ODBC_DRIVER',         'Driver ODBC instalado en el servidor',                   true],
  ['DOCS_DB_ODBC_SERVER',         'Nombre DNS del servidor de base de datos',               true],
  ['DOCS_DB_ODBC_PORT',           'Puerto del servidor (obligatorio en HANA)',              true],
  ['DOCS_DB_ODBC_DATABASE',       'Código de la base de datos o catálogo',                  true],
  ['DOCS_DB_ODBC_SCHEMA',         'Esquema de los objetos (dbo en SQL Server)',             true],
  # Autenticación integrada de Windows. Solo SQL Server: con esto en `true`, la
  # conexión va con la identidad de la cuenta que corre el proceso y USER y
  # PASSWORD dejan de ser obligatorios (el driver los ignora).
  ['DOCS_DB_ODBC_TRUSTED',        'Autenticación integrada de Windows (solo SQL Server)',   true],
  ['DOCS_DB_ODBC_USER',           'Usuario de la base de datos (solo lectura)',              true],
  # La única del grupo que no se devuelve: es la razón de ser de `is_visible`.
  ['DOCS_DB_ODBC_PASSWORD',       'Contraseña del usuario de la base de datos',             false],
  ['DOCS_DB_ODBC_QUERY_TIMEOUT',  'Tiempo máximo de una consulta, en segundos',             true],
  ['DOCS_DB_ODBC_EXTRA_PARAMS',   'Parámetros extra de la cadena ODBC (clave=valor;…)',     true]
].freeze

# Ajustes heredados del .NET. Los `code` cambiaron de PascalCase a la convención
# de este producto; la equivalencia está en `db/setting_code_map.yml` y la
# importación tiene que traducir o deja el ajuste duplicado.
LEGACY_SETTINGS = [
  ['GENERAL_PROVIDER_ID', 'Identificación del proveedor de sistemas',   true],
  ['CRYSTAL_USER',        'Usuario del servidor de Crystal Reports',    true],
  # `is_visible: false` es el arreglo de la fuga: hoy el .NET manda esta
  # contraseña en claro al browser (`general_configs_controller.js:137`).
  ['CRYSTAL_PASSWORD',    'Contraseña del servidor de Crystal Reports', false]
].freeze

# El ambiente de Hacienda contra el que emite la instalación. Era la tabla
# `environments` (una fila por ambiente, `companies.environment_id` apuntaba a
# ella); se movió a `settings` porque el despliegue es una instancia por
# cliente (`CLAUDE.md` §31) y un ambiente entero es configuración de la
# instalación, no una entidad con muchas filas. `is_prod` no se migró: se
# perdió a propósito, ver `20260905120000_move_environment_config_to_settings.rb`.
HACIENDA_FE_SETTINGS = [
  ['HACIENDA_FE_URI_TOKEN',         'URL de Hacienda para obtener el token de autenticación', true],
  ['HACIENDA_FE_URI_SEND',          'URL de Hacienda para enviar el documento electrónico',   true],
  ['HACIENDA_FE_URI_CHECK',         'URL de Hacienda para consultar el estado del documento', true],
  ['HACIENDA_FE_RESOLUTION_NUMBER', 'Número de resolución de facturación electrónica',        true],
  ['HACIENDA_FE_RESOLUTION_DATE',   'Fecha de la resolución de facturación electrónica',      true],
  # Antes `companies.client_id` / `companies.grant_type` — sin campo en el
  # formulario, congeladas en lo que trajera la importación. Son del AMBIENTE
  # de Hacienda (`"api-stag"` en pruebas, `"api-prod"` en producción), no de
  # la compañía — ver
  # `20260906120000_move_hacienda_client_credentials_to_settings.rb`.
  # `client_id` SÍ lo escribe el operador (varía por ambiente) y nace en
  # blanco; `grant_type` no es una elección suya — Hacienda solo acepta la
  # variante `"password"` del OAuth Resource Owner Password Credentials
  # Grant— y por eso lleva `fixed_value`, igual que `HACIENDA_XADES_SETTINGS`
  # más abajo.
  ['HACIENDA_FE_CLIENT_ID',         'Client ID de Hacienda para el token OAuth (api-stag / api-prod)', true],
  ['HACIENDA_FE_GRANT_TYPE',        'Grant type de Hacienda para el token OAuth (password)',           true,
   'password']
].freeze

# Política de firma XAdES-EPES que exige Hacienda (DGT-R-48-2016) para todo
# comprobante (`Hacienda::XmlSigner`). A diferencia de TODO el resto de esta
# sección, acá el operador no configura nada: es la MISMA política para
# cualquier instalación, publicada por el Ministerio de Hacienda. Se movió de
# una constante del código a `settings` únicamente para poder corregirla desde
# la UI sin esperar un deploy si Hacienda la cambia. El valor VIGENTE sigue
# siendo el de este archivo — por eso estas dos filas llevan un cuarto elemento
# (`fixed_value`) que el loop de abajo usa para SOBRESCRIBIR `value` en cada
# corrida de `db:seeds`. Es el mismo mecanismo de `HACIENDA_FE_GRANT_TYPE`, más
# arriba, y por la misma razón: un valor que dicta Hacienda, no el operador.
# Si Hacienda cambia la política: actualizar el valor ACÁ y correr
# `db:seeds` de nuevo. Un cambio manual desde la UI es solo un parche de
# emergencia — el próximo `db:seeds` lo revierte a lo que diga este archivo.
HACIENDA_XADES_SETTINGS = [
  # code                                description                                            is_visible  fixed_value
  ['HACIENDA_XADES_POLICY_IDENTIFIER', 'URL del documento de política de firma XAdES (DGT-R-48-2016)', true,
   'https://tribunet.hacienda.go.cr/docs/esquemas/2016/v4.1/Resolucion_Comprobantes_Electronicos_DGT-R-48-2016.pdf'],
  ['HACIENDA_XADES_POLICY_HASH', 'SHA-1 (Base64) del documento de política de firma XAdES', true,
   'Ohixl6upD6av8N7pEvDABhEL6hM=']
].freeze

# Cuenta de Azure Storage donde `Documents::XmlArchive` guarda el XML firmado
# que se envía a Hacienda y el XML de respuesta que Hacienda devuelve. Nombre y
# clave de la cuenta SÍ varían por instalación —y potencialmente por ambiente
# (dev/staging/prod usan cuentas distintas)—, con el mismo criterio que
# `HACIENDA_FE_CLIENT_ID`.
#
# El CONTENEDOR, en cambio, es el mismo "appfiles" en cualquier instalación:
# no lo elige el operador, así que lleva `fixed_value` y se reafirma en cada
# corrida — igual que `HACIENDA_FE_GRANT_TYPE` y `HACIENDA_XADES_SETTINGS` de
# más arriba. Vive en `settings` (no en una constante) solo para poder
# corregirlo desde la UI sin deploy si Hacienda alguna vez pidiera otro
# contenedor.
# El WORKSPACE es la carpeta de PRIMER nivel dentro del contenedor: la cuenta es
# compartida entre productos de Clavisco y "fec" es la de este. Va con
# `default_value` y NO con `fixed_value`: el nombre por defecto es del producto,
# pero una instalación puede necesitar otro (un ambiente de QA conviviendo con
# producción en la misma cuenta), y ese cambio no se puede perder en el próximo
# deploy. Ver `Azure::BlobStorage.workspace` y `Documents::XmlArchive`.
AZURE_STORAGE_SETTINGS = [
  # code                          description                                             is_visible  fixed  default
  ['AZURE_STORAGE_ACCOUNT_NAME', 'Nombre de la cuenta de Azure Storage', true],
  ['AZURE_STORAGE_ACCOUNT_KEY',  'Clave de acceso de la cuenta de Azure Storage', false],
  ['AZURE_STORAGE_CONTAINER',    'Contenedor de Azure Storage donde se guardan los XML', true, 'appfiles'],
  ['AZURE_STORAGE_WORKSPACE',    'Carpeta del producto dentro del contenedor', true, nil, 'fec']
].freeze

# Límites de `MailReceptionJob` (lectura de bandejas de recepción cada 5
# minutos, `config/recurring.yml`). Reemplazan las constantes fijas
# `MaxEmailsToReadPerInbox`/`MaxEmailsToReadPerExecution` del conector .NET
# legacy (`legacy/reception/clvsfemailsconector`), pensadas para un scheduler
# externo cada 15 minutos (20 y 350 respectivamente) — acá se recalculan para
# el intervalo de 5 minutos de este job (un tercio) y quedan editables desde
# Configuraciones → Generales, en vez de fijas en el código.
#
# `default_value` y no `fixed_value`: son un punto de partida razonable, no un
# dato del producto — una instalación con buzones muy activos puede necesitar
# subirlos, y ese cambio no se puede perder en el próximo `db:seed`.
MAIL_RECEPTION_SETTINGS = [
  # code                                          description                                                                            is_visible  fixed  default
  ['MAIL_RECEPTION_MAX_MESSAGES_PER_MAILBOX',
   'Límite blando: tope de correos sin leer que se procesan de UNA bandeja en cada corrida', true, nil,
   MailReceptionJob::DEFAULT_MAX_MESSAGES_PER_MAILBOX.to_s],
  ['MAIL_RECEPTION_MAX_MESSAGES_PER_EXECUTION',
   'Límite duro: tope total de correos que se procesan en TODA la corrida, sumando todas las bandejas', true, nil,
   MailReceptionJob::DEFAULT_MAX_MESSAGES_PER_EXECUTION.to_s]
].freeze

# Los esquemas XSD con los que se valida cada comprobante antes de mandarlo a
# Hacienda. Reemplazan los nueve `appSettings` del .NET
# (`CLVS_FE.API/Web.config`: `FEXSDPath`, `NCXSDPath`, … `ACCEPTXSDMailParser`),
# que eran rutas absolutas al disco de aquel servidor.
#
# ⚠️ **Estos nueve NO van en `db/setting_code_map.yml`.** Ese archivo traduce los
# `code` de la tabla `Setting` de SQL Server, y estos no salen de ahí: vivían en
# el `Web.config`, que la importación no lee. La equivalencia con la llave vieja
# está en `Hacienda::SchemaStore::SCHEMAS` (`legacy_key`), que es lo que le dice
# a quien migra una instalación qué archivo del servidor viejo va en cada campo.
#
# El VALOR no es el XSD ni una ruta del disco: es la ruta del blob en Azure
# (`xsd/{CODE}/{digest}/{nombre}.xsd`), que escribe `Hacienda::SchemaUpload`
# cuando el operador sube el archivo. Por eso nacen vacíos y `is_visible: true`
# —la ruta no es un secreto— y por eso NINGUNO lleva `fixed_value`: el archivo
# lo publica Hacienda y cambia con cada versión del esquema, así que no hay un
# valor del producto que reafirmar.
#
# El catálogo se deriva de `Hacienda::SchemaStore::SCHEMAS` en vez de repetirse
# acá: esa lista ya tiene que existir en el código —es la que resuelve qué
# esquema le toca a cada tipo de comprobante— y dos listas paralelas se separan
# sin que nadie lo note.
HACIENDA_XSD_SETTINGS = Hacienda::SchemaStore::SCHEMAS.map do |schema|
  [schema[:code], "Esquema XSD de Hacienda para #{schema[:label].downcase}", true]
end.freeze

# El grupo es el prefijo del `code` sin el campo, y se declara junto a las filas
# en vez de derivarlo: `DOCS_DB_ODBC_QUERY_TIMEOUT` partido por el último `_`
# daría el grupo equivocado (ver el encabezado de la migración).
SETTING_GROUPS = {
  'DOCS_DB_ODBC' => DOCS_DB_SETTINGS,
  'GENERAL' => LEGACY_SETTINGS.select { |code, _, _| code.start_with?('GENERAL_') },
  'CRYSTAL' => LEGACY_SETTINGS.select { |code, _, _| code.start_with?('CRYSTAL_') },
  'HACIENDA_FE' => HACIENDA_FE_SETTINGS,
  'HACIENDA_XADES' => HACIENDA_XADES_SETTINGS,
  'HACIENDA_XSD' => HACIENDA_XSD_SETTINGS,
  'AZURE_STORAGE' => AZURE_STORAGE_SETTINGS,
  'MAIL_RECEPTION' => MAIL_RECEPTION_SETTINGS
}.freeze

ActiveRecord::Base.transaction do
  created = 0

  SETTING_GROUPS.each do |group_code, rows|
    rows.each do |code, description, is_visible, fixed_value, default_value|
      # `unscoped`: un ajuste dado de baja tiene que reactivarse, no duplicarse.
      # El índice único de `code` no excluye a las inactivas, así que sin esto el
      # `find_or_initialize_by` no la encontraría e intentaría insertar otra
      # igual — y el que se perdería es el que TIENE el valor configurado.
      record = Setting.unscoped.find_or_initialize_by(code: code)
      created += 1 unless record.persisted?

      record.group_code  = group_code
      record.description = description
      record.is_visible  = is_visible
      record.is_active   = true

      # `value` NO se asigna, salvo por las dos excepciones de abajo. En
      # cualquier otra fila de este archivo es lo único que escribe el operador.
      #
      #   - `fixed_value` — un dato del PRODUCTO, no de la instalación
      #     (`HACIENDA_XADES_SETTINGS`, documentado arriba). El seed lo reafirma
      #     en CADA corrida, así que pisa lo que haya: si el operador lo cambió
      #     desde la pantalla, el cambio se revierte.
      #   - `default_value` — un valor con el que el ajuste ARRANCA y que el
      #     operador puede cambiar (`AZURE_STORAGE_WORKSPACE`). Solo se escribe
      #     cuando no hay ninguno guardado, precisamente para no revertirlo.
      #     `value.blank?` y no `record.persisted?`: una fila que quedó sin valor
      #     —creada por una migración anterior, o vaciada— también lo necesita.
      record.value = fixed_value   if fixed_value
      record.value = default_value if default_value && record.value.blank?

      record.save!
    end
  end

  configured = Setting.unscoped.where.not(value: nil).count
  total      = Setting.unscoped.count

  puts "Ajustes: #{total} (#{created} nuevos, #{configured} con valor configurado, " \
       "#{Setting.unscoped.where(is_visible: false).count} ocultos)"
end

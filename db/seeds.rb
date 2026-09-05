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
   '$select=*', 999],
  ['GetTaxes', 'Obtiene un listado de impuestos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_TAXCODES_B1SLQuery',
   '$select=*', 999],
  ['GetUdfs', 'Obtiene la informacion de los UDFS en SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_UDFS_B1SLQuery',
   '$filter=(TableID eq @TableID)', 0],
  ['GetItems', 'Obtiene la informacion de los items desde SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_ITEMS_B1SLQuery',
   '$select=*', 0],
  ['GetDimAndCenterCost', 'Obtiene la informacion de dimensiones y centros de costo de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_DIMENSIONS_AND_CNTERCOST_B1SLQuery',
   '$select=*', 999],
  ['GetAdditionalFreights', 'Obtiene un listado de cargos adicionales de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_ADDITIONALFREIGHTS_B1SLQuery',
   '$select=*', 999],
  ['GetDocTypeBase', 'Obtiene los tipos de bases de los documentos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_DOCTYPEBASE_B1SLQuery',
   '$select=*', 999],
  ['GetAccounts', 'Obtiene todas las cuentas de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_ACCOUNTS_B1SLQuery',
   '$select=*', 999],
  ['GetWarehouses', 'Obtiene un listado de almacenes de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_WAREHOUSES_B1SLQuery',
   '$select=*', 999],
  ['CheckIfExistApInvoice', 'Revisa si ya existe el ApInvoice',
   'CL_D_CL_MLT_FEC_APP_SLT_CHECKIFEXISTAPINVOICE_B1SLQuery',
   '$filter=(U_FeNumProvRef eq @Clave)', 999],
  ['GetUdfsValues', 'Obtiene los valores de los Udfs',
   'CL_D_CL_MLT_FEC_APP_SLT_UDFSVALUES_B1SLQuery',
   '$select=*', 999],
  ['GetTaxesForAutomatic', 'Obtiene los impuestos para la creacion automatica',
   'CL_D_CL_MLT_FEC_APP_SLT_TAXCODEBYAMOUNT_B1SLQuery',
   '$filter=(contains(TaxCode, @TaxCodeVm) and contains(TaxCode,@TaxCodeContains))', 999],
  ['Drafts', 'Crea un documento borrador en SAP',
   'Drafts',
   nil, 0],
  ['PurchaseInvoices', 'Crea un ApInvoice en SAP',
   'PurchaseInvoices',
   nil, 0],
  ['GetMatchAutomaticOne',
   'Obtiene match automaticos, se utiliza este para el filtrado del case 1 en el flujo',
   'CL_D_CL_MLT_FEC_APP_SLT_MATCHAUTOMATIC_B1SLQuery',
   '$filter=(CardCode eq @CardCode and XmlCode eq @XmlCode)', 999],
  ['GetMatchAutomaticTwo', 'Obtiene match automaticos con los filtrados del case 1',
   'CL_D_CL_MLT_FEC_APP_SLT_MATCHAUTOMATIC_B1SLQuery',
   '$filter=(XmlCode eq @XmlCode)', 999],
  ['GetMatchAutomaticUdt', 'Obtiene match automaticos desde UDF',
   'CL_D_CL_MLT_FEC_APP_SLT_MATCHAUTOMATICUDT_B1SLQuery',
   '$filter=(CardCode eq @CardCode and XmlCode eq @XmlCode)', 999],
  ['CheckIfFileExist', 'Verifica si ya existe el archivo en SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_CHECKIFATTACHMENTEXIST_B1SLQuery',
   '$filter=(FileName eq @FileName)', 999],
  ['GetExchangeRate', 'Obtiene el tipo de cambio',
   'CL_D_CL_MLT_FEC_APP_SLT_EXCHANGERATE_B1SLQuery',
   nil, 0],
  ['Attachments2', 'Guarda adjuntos en SAP',
   'Attachments2',
   nil, 0],
  ['GetMatchAutomaticOthersOne', 'Obtiene match automatico con datos de otro receptor',
   'CL_CL_MLT_FEC_SLT_MATCHAUTOMATICORDER_B1SLQuery',
   '$filter=(CardCode eq @CardCode and XmlCode eq @XmlCode and DocNum eq @DocNum ' \
   'and TableName eq @TableName)', 2],
  ['GetMatchAutomaticOthersTwo', 'Obtiene match automatico con datos de otro receptor',
   'CL_CL_MLT_FEC_SLT_MATCHAUTOMATICORDER_B1SLQuery',
   '$filter=(XmlCode eq @XmlCode and DocNum eq @DocNum and TableName eq @TableName)', 2],
  ['GetProjects', 'Obtiene la lista de projyectos de SAP',
   'CL_D_CL_MLT_FEC_APP_SLT_PROJECTS_B1SLQuery',
   nil, 0],
  ['CheckIfExistApInvoiceByNumAtCard', 'Revisa si ya existe el ApInvoice por NumAtCard',
   'CL_D_CL_MLT_FEC_APP_SLT_CHECKIFEXISTAPINVOICE_B1SLQuery',
   '$filter=(NumAtCard eq @Clave)', 999],
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
# `page_size`: la cabecera es una sola fila; el resto son listas y llevan el
# mismo 999 que usa el catálogo importado para no quedarse en las 20 filas que
# el Service Layer devuelve por defecto.
SL_RESOURCES_OWN = [
  ['qsGetDocumentHeaderInfo',
   'Cabecera del documento a emitir, para el envio a Hacienda',
   'CL_D_CL_MLT_FEC_SLT_DOCHEADERINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 0],
  ['qsGetDocumentLinesInfo',
   'Lineas de detalle del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCLINESINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 999],
  ['qsGetDocumentOtherChargesInfo',
   'Otros cargos del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCOTHERCHARGESINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 999],
  ['qsGetDocumentPaymentMethodsInfo',
   'Medios de pago del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCPAYMENTMETHODSINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 999],
  ['qsGetDocumentReferenceInfo',
   'Informacion de referencia del documento a emitir',
   'CL_D_CL_MLT_FEC_SLT_DOCREFERENCEINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 999],
  # Solo se ejecuta cuando la compañía tiene `use_additional_fields` en true
  # (`docs/sync-documents-flow.md` punto 8). La fila se siembra igual: el
  # catálogo describe lo que se puede consultar, no lo que se consulta siempre.
  ['qsGetDocumentOthersInfo',
   'Bloque Otros del documento a emitir (campos adicionales)',
   'CL_D_CL_MLT_FEC_SLT_DOCOTHERSINFO_B1SLQuery',
   '$filter=(DocEntry eq @DocEntry and DocType eq @DocType)', 999]
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
# ⚠️ Los seis `U_CL_FEC_*` de arriba son UDFs y TODAVÍA no tienen su schema en
# `config/sap_schemas/` (`CLAUDE.md` §32): sin eso, una instalación nueva no los
# va a tener y el PATCH va a fallar con "campo inválido" la primera vez que se
# use. Anotado en `TODOS.md` → Emisión de documentos.
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
# `resource` es la entidad ESTÁNDAR de SAP completa, sin `(#DocumentEntry#)`:
# es un listado, no un documento puntual. Mismo mapeo tipo→objeto que
# `SL_RESOURCES_STATUS_UPDATES` (Invoices para FE/ND/TE/FEE, CreditNotes para
# NC, PurchaseInvoices para FEC, IncomingPayments para REP) — no son vistas, no
# llevan prefijo, y el mismo `code` sirve en SQL Server y en HANA.
#
# `query_params` solo lleva el `$select`: el `$top`/`$skip` de la paginación
# real los agrega el llamador con `Sap::ResourceQuery#merge` en cada página —no
# se hornean acá porque cambian en cada request, no son parte del catálogo.
# Mismo criterio que `GetSapDocuments` (arriba, en `SL_RESOURCES`).
#
# ⚠️ `page_size: 0` a propósito, y NO un valor alto tipo 999: el Service Layer
# nunca devuelve más de 20 filas por respuesta si no se manda el header
# `Prefer: odata.maxpagesize`, y el submódulo (`Clavisco::ServiceLayer::Client`)
# todavía no lo soporta —tampoco sigue `odata.nextLink`— (`TODOS.md` → SAP,
# sección "deuda del acceso a Service Layer"). Un `page_size` mayor acá sería
# mentira: por más que el llamador pida `$top=999`, SAP corta en 20 igual.
# Quien construya el listado tiene que paginar de a 20 filas o menos por
# request hasta que el submódulo agregue el header.
SL_RESOURCES_DOCUMENT_QUERIES = [
  ['getDocuments01', 'Obtiene el listado paginado de facturas electrónicas desde SAP',
   'Invoices',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0],
  ['getDocuments02', 'Obtiene el listado paginado de notas de débito electrónicas desde SAP',
   'Invoices',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0],
  ['getDocuments03', 'Obtiene el listado paginado de notas de crédito electrónicas desde SAP',
   'CreditNotes',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0],
  ['getDocuments04', 'Obtiene el listado paginado de tiquetes electrónicos desde SAP',
   'Invoices',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0],
  ['getDocuments08', 'Obtiene el listado paginado de facturas electrónicas de compra desde SAP',
   'PurchaseInvoices',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0],
  ['getDocuments09', 'Obtiene el listado paginado de facturas electrónicas de exportación desde SAP',
   'Invoices',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0],
  ['getDocuments10', 'Obtiene el listado paginado de recibos electrónicos de pago desde SAP',
   'IncomingPayments',
   '$select=DocEntry,CardCode,CardName,DocCurrency,U_CL_FEC_Clave,U_CL_FEC_NumConsecutivo,' \
   'U_CL_FEC_Status,U_CL_FEC_FechaEmision', 0]
].freeze

ActiveRecord::Base.transaction do
  # Se resuelve ANTES de tocar la base: si `SERVER_TYPE` está mal, el seed corta
  # sin haber escrito ninguna fila.
  server_type = SlResourceSeed.server_type

  preserved = 0

  all_sl_resources = SL_RESOURCES + SL_RESOURCES_OWN + SL_RESOURCES_STATUS_UPDATES +
                     SL_RESOURCES_DOCUMENT_QUERIES
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
  ['HACIENDA_FE_RESOLUTION_DATE',   'Fecha de la resolución de facturación electrónica',      true]
].freeze

# Política de firma XAdES-EPES que exige Hacienda (DGT-R-48-2016) para todo
# comprobante (`Hacienda::XmlSigner`). A diferencia de TODO el resto de esta
# sección, acá el operador no configura nada: es la MISMA política para
# cualquier instalación, publicada por el Ministerio de Hacienda. Se movió de
# una constante del código a `settings` únicamente para poder corregirla desde
# la UI sin esperar un deploy si Hacienda la cambia. El valor VIGENTE sigue
# siendo el de este archivo — por eso estas dos filas llevan un cuarto elemento
# (`fixed_value`) que el loop de abajo usa para SOBRESCRIBIR `value` en cada
# corrida de `db:seeds`, algo que ninguna otra fila de `SETTING_GROUPS` hace.
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

# El grupo es el prefijo del `code` sin el campo, y se declara junto a las filas
# en vez de derivarlo: `DOCS_DB_ODBC_QUERY_TIMEOUT` partido por el último `_`
# daría el grupo equivocado (ver el encabezado de la migración).
SETTING_GROUPS = {
  'DOCS_DB_ODBC' => DOCS_DB_SETTINGS,
  'GENERAL' => LEGACY_SETTINGS.select { |code, _, _| code.start_with?('GENERAL_') },
  'CRYSTAL' => LEGACY_SETTINGS.select { |code, _, _| code.start_with?('CRYSTAL_') },
  'HACIENDA_FE' => HACIENDA_FE_SETTINGS,
  'HACIENDA_XADES' => HACIENDA_XADES_SETTINGS
}.freeze

ActiveRecord::Base.transaction do
  created = 0

  SETTING_GROUPS.each do |group_code, rows|
    rows.each do |code, description, is_visible, fixed_value|
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

      # `value` NO se asigna, salvo `fixed_value`: es la excepción de
      # `HACIENDA_XADES_SETTINGS` documentada arriba — un dato del PRODUCTO, no
      # de la instalación, que el seed reafirma en cada corrida. En cualquier
      # otra fila de este archivo `value` es lo único que escribe el operador.
      record.value = fixed_value if fixed_value

      record.save!
    end
  end

  configured = Setting.unscoped.where.not(value: nil).count
  total      = Setting.unscoped.count

  puts "Ajustes: #{total} (#{created} nuevos, #{configured} con valor configurado, " \
       "#{Setting.unscoped.where(is_visible: false).count} ocultos)"
end

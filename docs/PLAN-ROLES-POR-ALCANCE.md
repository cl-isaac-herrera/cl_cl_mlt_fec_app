# Plan — roles por alcance (instalación / compañía) y compañía activa opcional

> **Estado (2026-09-24): IMPLEMENTADO.** Las seis fases de este documento están en el
> código: schema (`permissions.scope`, `roles.scope`, `users_by_companies.role_id`,
> `users.installation_role_id`), modelos, seeds, autorización
> (`Api::AuthorizedController#permission?`), rutas/endpoints
> (`/api/users/:id/installation_role`, `/api/users/:id/companies` con `Assignments`,
> `?scope=` en roles y en el catálogo de permisos), frontend (paneles de
> "Gestionar accesos" y de Seguridad) y la limpieza de Fase 6 (`user_roles`/
> `user_permissions` y la Template Company eliminados). Las decisiones de la Fase 0 se
> resolvieron como estaban propuestas en el texto de cada una. Este documento queda como
> referencia histórica del diseño; para el estado vivo del código, `CLAUDE.md` §28.

## Problema

- Para usar la aplicación hace falta tener una compañía activa. En una instalación nueva no
  hay ninguna, y por eso `db/seeds.rb` crea una "Template Company" solo para poder entrar.
- El rol del usuario se asigna por compañía (`user_roles.company_id NOT NULL`). Como
  `permission?` filtra los roles por `Current.company_id`, sin compañía activa no se concede
  ningún permiso normal.
- Los datos de la instalación (bandejas, buzones de recepción, roles, usuarios) quedan
  protegidos con permisos por compañía: para administrar algo de toda la instalación hay que
  tener un rol en *alguna* compañía.
- El menú (`menu_controller.js:134`) y el auth guard ni siquiera piden `/api/permissions`
  sin compañía, así que tampoco se ven las pantallas que el API sí permite (Generales,
  Conexiones).

Contexto: hay **una instancia por cliente**, y cada cliente tiene N compañías (§31).

## Alternativa descartada: `user_company_permissions`

Se descartó armar una lista de permisos por usuario y por compañía:

- No se reutiliza nada: con 20 usuarios en 5 compañías son 100 listas armadas a mano.
- Cuando el catálogo suma un permiso nuevo, nadie lo tiene hasta que alguien recorra cada
  lista.
- No se puede auditar: "¿por qué este usuario puede anular?" no tiene otra respuesta que
  "alguien marcó el check".

Si algún día hace falta una excepción puntual, se agrega después como override, no como
mecanismo principal.

## Modelo final

| Concepto | Dónde vive |
|---|---|
| Alcance del permiso | `permissions.scope`: `installation` o `company` (reemplaza `type`: `global`/`normal`) |
| Alcance del rol | `roles.scope`: `installation` o `company`. Un rol solo contiene permisos de su alcance |
| Rol de instalación | `users.installation_role_id` (nullable) |
| Acceso a una compañía y su rol | `users_by_companies.role_id` (NOT NULL): una fila da el acceso y el rol a la vez |
| `user_roles`, `user_permissions` | Se eliminan |

**Permisos efectivos:**

- Sin compañía activa: los del rol de instalación.
- Con compañía activa: los del rol de instalación más los del rol de esa compañía.

`Clavisco::Auth::AuthorizationService` (submódulo, no se toca, §27) sigue sirviendo: filtra
por `user_id`, `company_id` e `is_active`, y lee `role_id`. `users_by_companies` va a tener
esas cuatro columnas, así que se le pasa `UsersByCompany` como `roles_by_user`.

---

## Fase 0 — decisiones pendientes

1. **¿Hay alguna instalación con datos reales?** No existe un importador desde SQL Server
   (solo hay comentarios que lo describen), así que se asume que no.
   - Si no hay: la migración de datos puede ser simple y `development` se vuelve a sembrar.
   - Si hay: hace falta mapear los roles actuales a roles de instalación (ver Fase 2).
2. **Rol del creador de una compañía nueva.** Hoy `companies_controller.rb:204` crea el
   acceso pero **ningún rol**, así que el creador no puede hacer nada en la compañía que
   acaba de crear. Propuesta: asignarle el rol de compañía "Administrador".
3. **Qué usuarios ve cada uno.** Hoy la lista se filtra por la compañía activa, salvo con
   `ViewAllApplicationUsers`. Si administrar usuarios pasa a ser de instalación, la
   propuesta es que la lista muestre a todos y dar de baja ese permiso.
4. **Permisos que solo amplían el alcance:** `ViewAllApplicationCompanies`,
   `Download*InAllCompanies` y `ViewAllConfigurationsInApplication`. Pasan a ser de
   instalación y se conservan.
5. **`Configurations_Companies_ViewGroupCompanies`** todavía se evalúa en
   `concerns/assignable_companies.rb:18`, aunque según §31 los grupos no existen. Propuesta:
   reemplazarlo por `ViewAllApplicationCompanies`.

## Fase 1 — alcance en el catálogo de permisos y en los roles

**Esquema**

- `permissions.scope` (string, NOT NULL). Se llena a partir de `type` y después se borra
  `type`.
- `roles.scope` (NOT NULL, default `company`).

**Reclasificación del catálogo** (`db/seeds.rb`): las constantes `CATALOG`,
`GLOBAL_CATALOG` y `CODE_ONLY` pasan a agruparse por alcance.

- **De instalación:**
  - `Configurations_Users_*` (incluido `ManageAccess`).
  - `Configurations_Security_Access` y `Configurations_Permissions_*`.
  - `Configurations_Companies_ListAccess`, `_Create`, `_ViewAll*` y `_Download*InAllCompanies`.
  - `Configurations_Connections_*`, `Configurations_EmailInbox_*`,
    `Configurations_MailParser_*`, `Configurations_General_*` y `Configurations_SlResources_*`.
  - `S_Udfs` y `Configurations_UserHelp_Access`.
- **De compañía:**
  - `Documents_*`, `S_CreateDocs*`, `S_ReceptDocs`, `S_DocumentReport` y `S_MailParserLogs`.
  - `F_*`.
  - `Configurations_Companies_Update`, `_DownloadLogo` y `_DownloadFEPrintFormat` (sobre la
    compañía activa).
  - `Configurations_Branches_*`, `S_Numbering*` y `S_Sucursal`.
- **Casos a revisar:** `email_configs_controller.rb:107` y
  `reception_mailboxes_controller.rb:92` aceptan `Companies_Update` para alimentar los
  selectores del formulario de compañías. Probablemente siga siendo válido, porque esos
  selectores se usan al editar una compañía, pero hay que confirmarlo.

**Modelo**

`RolePermission` valida que el alcance del permiso coincida con el del rol. Esto cierra un
agujero que existe hoy: `roles/permissions_controller.rb:36-41` acepta cualquier permiso, y
un permiso global puesto en un rol termina concediéndose por compañía.

**Specs:** `permission_spec`, `role_spec`, `role_permission_spec`.

## Fase 2 — tablas de asignación y migración de datos

**Esquema**

- `users_by_companies.role_id`: se agrega nullable, se llena y recién después pasa a
  NOT NULL, con FK a `roles`.
- `users.installation_role_id`: nullable, con FK a `roles`.

**Migración de datos** (con clases mínimas locales, sin los modelos de la app; ver §28):

1. Llenar `users_by_companies.role_id` desde los `user_roles` activos con el mismo
   `(user_id, company_id)`.
   - `user_roles` no tiene índice único, así que puede haber varios por par. En ese caso gana
     el más reciente y se registra en el log.
   - Un acceso sin rol recibe el rol de compañía "Administrador" solo si el usuario es sys.
     En cualquier otro caso el acceso se da de baja y se registra en el log.
2. Crear el rol de instalación "Administrador" con todos los permisos de instalación y
   asignárselo al usuario sys.
3. `user_permissions`:
   - Si no hay ninguna instalación con datos, no se migra: esos permisos se vuelven a
     asignar a mano.
   - Si la hay, se crea un rol de instalación por cada combinación distinta de permisos y se
     asigna a los usuarios que la tenían.
4. Los permisos que pasan de `normal` a instalación (`EmailInbox`, `MailParser`, `Users`,
   `Security`, …) se sacan de los roles de compañía con baja lógica en `role_permissions`.

**Seeds:** el usuario sys recibe el rol de instalación "Administrador", y se crea el rol de
compañía "Administrador" con todos los permisos de compañía. Todo con upsert, nunca
`delete_all`.

## Fase 3 — autorización en el backend

- **`authorized_controller.rb`:** `permission?` decide según el alcance del permiso.
  - `installation`: EXISTS contra `users.installation_role_id` → `role_permissions`.
  - `company`: EXISTS contra `users_by_companies` (usuario + `Current.company_id`) →
    `role_permissions`. Sin compañía activa devuelve false.
  - Desaparecen `UserPermission.granting?` y el join a `user_roles`.
- **`permissions_controller.rb#index`:** devuelve los permisos del rol de instalación más los
  de `AuthorizationService` con `UsersByCompany` (esto último solo si hay compañía activa).
- **Concern nuevo `RequiresActiveCompany`:** `before_action :require_company!`, que responde
  un 422 con el mensaje "Seleccione una compañía". Aplica a branches, certificate_alarms,
  documents, documents/mails, documents/xml_files y a los endpoints de la compañía activa.
- **`application_controller.rb`:** borrar `view_permission_granted?` y
  `require_view_permission!` (líneas 36-54). Nadie los llama y duplican la lógica.
- **`CompaniesController#create`:** el acceso del creador nace con el rol de compañía
  "Administrador" (decisión 2).
- **`UsersController`:** `create` deja de exigir `CompanyId` (debe poder existir un usuario
  solo de instalación). `visible_users` queda según la decisión 3.

## Fase 4 — endpoints de asignación (§28)

| Antes | Después |
|---|---|
| `GET` / `PUT /api/users/:id/role` (compañía activa) | Se elimina |
| `GET` / `PUT /api/users/:id/permissions` (globales) | Se elimina |
| — | `GET` / `PUT /api/users/:id/installation_role`: `resource` singular, cuerpo `{ RoleId }`, `null` lo quita |
| `PUT /api/users/:id/companies` con `{ CompanyIds }` | Cuerpo `{ Assignments: [{ CompanyId, RoleId }] }`. El `GET` devuelve el rol de cada compañía |
| `GET /api/roles` | Acepta `?scope=installation\|company`. La respuesta y el alta llevan `Scope` |
| `GET /api/permissions/catalog?type=global` | Pasa a `?scope=…`. Se da de baja `Configurations_Permissions_GlobalAccess` y se anota en `orphaned:` de `db/permission_name_map.yml` |

El `PUT` de compañías conserva lo que ya hace bien: solo revoca lo que está dentro del
alcance de quien asigna. Además tiene que validar que cada `RoleId` sea un rol de compañía
activo.

## Fase 5 — frontend

- **`menu_controller.js:134` y `auth_guard_controller.js:95`:**
  - Pedir `/api/permissions` siempre, haya compañía activa o no.
  - Marcar en `app/javascript/data/menu.js` los nodos que necesitan compañía (por ejemplo
    `requiresCompany: true`). Sin compañía activa se muestran deshabilitados y con tooltip
    (§26).
  - El guard deja de dejar pasar a cualquiera cuando no tiene permisos en caché.
- **`company_selector_controller.js:55`:** deja de abrir el selector a la fuerza. Al cambiar
  de compañía se sigue recargando la página (§19).
- **Panel "Gestionar accesos" (`users_controller.js` y `configurations/users/index.html.erb`):**
  pasa de tres sub-tabs (roles, global, compañías) a dos.
  - "Rol de instalación": un select.
  - "Compañías": por cada fila, un checkbox y un select con el rol de compañía. Guardar
    queda deshabilitado mientras haya una compañía marcada sin rol.
- **Seguridad (`roles_controller.js` y `configurations/roles/index.html.erb`):**
  - Tabs "Roles de instalación" y "Roles de compañía".
  - El panel de permisos carga el catálogo filtrado por el alcance del rol.
- **Arreglo de paso:** el menú pide `Configurations_Users_Access` y la pantalla
  `…ListAccess`. Hay que unificarlos.

## Fase 6 — limpieza

- `db/seeds.rb`: borrar la Template Company (líneas 1444-1502) y la siembra de
  `user_permissions` (1504-1517).
- Migración que elimina `user_roles` y `user_permissions`, junto con los modelos `UserRole`
  y `UserPermission`, sus factories y sus specs.
- `CLAUDE.md` §28: reescribir "Las DOS vías de concesión de permisos" y el ejemplo de
  `resource :role`.
- `spec/support/session_helpers.rb`: revisar `sign_in(user, company:)`.

## Specs

Unos 40 request specs conceden acceso creando `UserRole` o `UserPermission` a mano. Para no
tocarlos dos veces:

1. En la Fase 2, antes que nada, crear un helper central
   `grant_permissions(user, *names, company: nil)` que arme el rol del alcance que
   corresponda, y pasar esos specs a usarlo.
2. Después, cambiar la implementación de fondo toca un solo archivo.

Specs nuevos:

- `permission?` con y sin compañía activa, para cada alcance.
- Rechazo de un permiso de alcance cruzado en `RolePermission`.
- `PUT /api/users/:id/companies` con un rol inválido.
- El creador de una compañía recibe el rol "Administrador".

## Orden y commits

Un commit por fase, directo en `main` (§35), y cada uno deja la app funcionando. Los
endpoints viejos se eliminan en la Fase 4 en el mismo commit que la UI que los consume, o en
commits consecutivos sin un push de por medio.

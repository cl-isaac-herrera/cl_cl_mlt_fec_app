# TODOS — Deuda técnica pendiente de actualización del API

Este archivo registra los cambios de UI que **ya se aplicaron en las vistas** pero que
**NO se pueden completar todavía en el cliente del API** porque el backend aún no se ha
actualizado. Ver `CLAUDE.md` §24 para la convención completa.

**Regla:** al eliminar un campo visible de un formulario, se mantiene en la petición al API
enviando un **valor por defecto** desde el controller, y se anota aquí qué falta limpiar
cuando el endpoint deje de requerir ese campo.

Formato de cada entrada:

```markdown
## [Módulo / Formulario]

- [ ] Campo `NombreCampo` — eliminado de la vista en `ruta/vista.html.erb`.
      Aún se envía en el fetch de `controller_x.js` con valor por defecto `"..."`.
      **Pendiente API:** quitar `NombreCampo` del body/parámetros una vez el endpoint
      `/api/Endpoint` deje de requerirlo.
```

---

<!-- Las entradas de cambios pendientes van debajo de esta línea -->

## Bandejas de emisión — filtro de búsqueda (`/configurations/email-senders`)

- [ ] Campo `Host` — eliminado el filtro de la vista en
      `app/views/configurations/email_senders/index.html.erb` (select `filterHost`).
      Aún se envía en el payload del fetch de `email_senders_controller.js` (`#fetchPage`)
      con valor por defecto `''` (= todos), porque la búsqueda sigue siendo necesaria para
      la vista y `Host` es solo uno de sus parámetros.
      **Pendiente API:** quitar `Host` del body una vez el endpoint
      `POST /api/EmailConfig/SearchEmailConfig` deje de requerirlo.

> Nota: `GET /api/EmailConfig/GetHost` y `#loadHosts()` se eliminaron por completo en este
> mismo cambio — su único propósito era alimentar el dropdown de Host, así que no son deuda
> pendiente (ver criterio en CLAUDE.md §24).

## Bandejas de recepción — filtro de búsqueda (`/configurations/mail-parser`)

- [ ] Parámetro `mailServer` (filtro "Nombre del servidor") — eliminado el filtro de la vista
      en `app/views/configurations/mail_parser/index.html.erb` (input `filterServer`).
      Aún se envía en el query string del fetch de `mail_parser_controller.js` (`#fetchPage`)
      con valor por defecto `''`, porque la consulta `GET /api/mail-parser` alimenta la tabla
      y `mailServer` es solo uno de sus parámetros.
      **Pendiente API:** quitar `mailServer` del query string una vez el endpoint
      `GET /api/mail-parser` deje de requerirlo.

## Cutover de login a OIDC — deuda restante

El login propio se eliminó y la sesión (con el token) pasó a la cookie httpOnly de Rails;
`ProxyController` adjunta el `Authorization` desde `session[:access_token]` y descarta el
que manda el browser. Lo que queda pendiente:

- [ ] **BLOQUEANTE — los APIs .NET rechazan el token OIDC.** `cl_cl_mlt_fec_app_api`
      valida únicamente tokens que él mismo firmó con HS512 y su propia `Jwt:Key`/Issuer/
      Audience (`legacy/apis/cl_cl_mlt_fec_app_api/Api/Settings/AuthorizerFactory.cs`), y
      un token de Auth0/Keycloak es RS256 con otro issuer. Hasta que esos endpoints se
      migren a Rails (o acepten OIDC), las pantallas que consumen `/api/*` responderán 401
      aunque la sesión de Rails sea válida.
      **Pendiente API:** migrar los endpoints a Rails o hacer que el .NET valide el JWT del
      proveedor OIDC vía JWKS.

- [ ] **Lecturas muertas de `Storage.get('Session')` en 33 archivos JS.** Ya nada escribe
      esa llave (el único escritor era `vendor/clavisco/login`), así que devuelven
      `undefined` y el `Authorization` que arman lo descarta el proxy — son inofensivas pero
      son código muerto. Ejemplos: `documents_issued_controller.js`,
      `documents_receptions_controller.js`, `companies_controller.js`, `branches_controller.js`,
      y los `#apiFetch` copiados en cada controller.
      **Pendiente:** quitar el header `Authorization` y la lectura de `Session` de cada
      `#apiFetch`, dejando `getApiHeaders()` de `vendor/clavisco/core` como única fuente.

- [x] **Token FE en `sessionStorage.currentFEUser`** — resuelto: `#reloadFEToken` se eliminó
      del selector de compañías junto con su segundo login contra el servidor FE Sync.

- [x] **`session[:company_id]` no se puebla** — resuelto: `PUT /api/session/company` la guarda
      en la cookie tras validar que esté asignada al usuario.

## Migración del selector de compañías — pendiente de datos

Los endpoints del selector ya son nativos de Rails (`GET /api/companies`,
`GET /api/permissions`, `PUT /api/session/company`) y leen de las tablas propias.

- [ ] **Las tablas `companies` y `user_companies` están vacías.** Hasta que se importen los
      datos, el selector no mostrará ninguna compañía y no se podrá operar. La fuente es
      SQL Server `CLSQL03`, base `CL_CL_MLT_FEC_APP_44` (ver `ConnectionStrings:Main` en
      `legacy/apis/cl_cl_mlt_fec_app_api/Api/appsettings.json`), tablas `Company` y
      `CompanyByUser`.
      **Pendiente:** tarea de importación con el mapeo `EmsrNombreComercial → commercial_name`,
      `EmsrIdeNumero → identification`, `CodigoActividad → activity_code`,
      `UseFactProv → uses_supplier_invoice`, `SendReceptAndApinv → sends_reception_and_ap_invoice`,
      y `CompanyByUser.{UserId, CompanyId, Favorite, Status}` → `user_companies`.

- [x] **Los permisos de las pantallas siguen viniendo del .NET** — resuelto: `menu_controller.js`
      y `auth_guard_controller.js` ahora llaman `GET /api/permissions` (nativo, sin `companyId`:
      la compañía activa la toma de la session cookie). Ya no queda ninguna llamada a
      `/api/Permission/GetPermsByUser` en la app.

- [ ] **El catálogo de `permissions` está incompleto.** `db/seeds.rb` siembra 92 permisos en
      tres secciones: `CATALOG` (54 normales) y `GLOBAL_CATALOG` (25 globales), ambos con su
      `Id` de origen para que una importación posterior de `PermissionByRol` pueda copiar
      `PermissionId` tal cual, más `CODE_ONLY` (13 con `Id` desde 1000) que la UI evalúa pero
      que no vienen en ningún export.
      Los dos exports son subconjuntos disjuntos de la misma tabla y aun así quedan
      **11 Id sin cubrir: 22, 24, 26, 34, 37, 44, 45, 46, 48, 55, 69.**
      Los 13 de `CODE_ONLY` son: `Configurations_Security_Access`,
      `Configurations_Users_ManageAccess`, los cuatro `Configurations_Numbering_*`,
      los dos `Configurations_Branches_*`, los tres `Configurations_EmailInbox_*`,
      `Configurations_MailParser_Create` y `Configurations_MailParser_Update`.
      **Pendiente:** traer las 11 filas que faltan; si alguna corresponde a un nombre de
      `CODE_ONLY`, mover esa fila a su `Id` real. Para las que sigan sin existir en el origen,
      decidir entre crearlas en el .NET o cambiar el permiso que la UI evalúa — ojo que el
      export trae `Maintenance_EmailInbox_Access` y `Configurations_Permissions_Access`, que
      se parecen a `Configurations_EmailInbox_Access` y `Configurations_Permissions_GlobalAccess`
      del código y podrían ser el mismo permiso renombrado por error en la migración.

- [ ] **El campo `permissions.type` todavía no lo usa nadie.** Lo agregó
      `db/migrate/20260811120000_add_type_to_permissions.rb` (texto, `null: false`,
      default `'normal'`, valores válidos en `Permission::TYPES`) para poder distinguir
      permisos por compañía (`normal`) de permisos a nivel de aplicación (`global`).
      Hoy solo lo puebla el seed: ni `AuthorizationService` ni `GET /api/permissions` lo
      miran, así que un permiso global se sigue concediendo vía `user_roles` con
      `company_id` como cualquier otro.
      **Pendiente:** cuando se implemente la distinción, resolver los `global` sin pasar por
      la compañía activa y exponer el tipo en la respuesta del endpoint si el cliente lo
      necesita.

- [ ] **Los roles y sus asignaciones son de desarrollo, no los reales.** `db/seeds.rb` crea un
      único rol `Administrador` con los 80 permisos y lo asigna a cada fila activa de
      `users_by_companies`: **todo usuario sembrado queda administrador**. No sirve para
      producción ni para probar gating por permisos.
      **Pendiente:** importar de SQL Server `CLSQL03` / `CL_CL_MLT_FEC_APP_44` las tablas
      `Rol`, `PermissionByRol` y `RolByUser` → `roles`, `role_permissions`, `user_roles`;
      después quitar el rol `Administrador` sembrado.

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

- [x] **El campo `permissions.type` ya se usa** — resuelto al migrar los permisos globales
      por usuario: `user_permissions` solo acepta `type = 'global'` y esas concesiones se
      resuelven **sin** pasar por la compañía activa, tanto en `permission?` como en
      `GET /api/permissions`. Ver la sección *Usuarios* más abajo y `CLAUDE.md` §28.
      Queda en pie que un permiso `global` **también** se puede seguir concediendo por rol
      (y ahí sí queda atado a una compañía): las dos vías conviven a propósito, para no
      invalidar las asignaciones que ya existen en el origen.

- [ ] **Los roles y sus asignaciones son de desarrollo, no los reales.** `db/seeds.rb` crea un
      único rol `Administrador` con los 80 permisos y lo asigna a cada fila activa de
      `users_by_companies`: **todo usuario sembrado queda administrador**. No sirve para
      producción ni para probar gating por permisos.
      **Pendiente:** importar de SQL Server `CLSQL03` / `CL_CL_MLT_FEC_APP_44` las tablas
      `Rol`, `PermissionByRol` y `RolByUser` → `roles`, `role_permissions`, `user_roles`;
      después quitar el rol `Administrador` sembrado.

## Perfil de usuario — endpoints migrados a Rails (`/configurations/user-profile`)

La pantalla ya no toca el .NET: `GET /api/profile`, `PATCH /api/profile`,
`POST /api/sap_credential_validations` y `GET /api/companies` son nativos. Lo que quedó
pendiente:

- [x] **`POST /api/Connections/validate-user-credentials` seguía vivo en
      `users_controller.js`** — resuelto al migrar la lista de usuarios: ahora llama
      `POST /api/sap_credential_validations` con `UserId`. Ese parámetro es lo que separa
      los dos casos: sin él son las credenciales propias y no lleva permiso; con él son las
      de otro usuario, exige `Configurations_Users_Update` y la compañía se valida contra
      las asignaciones del **usuario objetivo**, no las del administrador.

- [ ] **`GET /api/Group/GetGroupsByUser` no se migró: se eliminó de las pantallas.** El
      Angular lo pedía en el perfil y descartaba la respuesta (ningún campo depende de los
      grupos), así que no era deuda sino código muerto — criterio de §24. En la lista de
      usuarios alimentaba el select "Cuenta" del panel de creación, que se eliminó junto con
      la consulta por la misma razón: no existe tabla `groups` en la base propia.
      Sigue en uso en `group_controller.js`; ahí se resuelve cuando se borre esa pantalla
      (`users_register_controller.js`, que era el otro consumidor, se eliminó con la página
      de alta).

- [ ] **`users.doc_number_preference` no se importó del origen.** La columna la agregó
      `db/migrate/20260811130000_add_doc_number_preference_to_users.rb` (texto, equivalente a
      `Users.DocNumberPreference varchar(2)` del .NET) y hoy nace en `NULL` para todos: quien
      tuviera un "Tipo de OC" configurado lo ve vacío hasta volver a guardarlo.
      **Pendiente:** incluir la columna en la importación de usuarios desde SQL Server
      `CLSQL03` / `CL_CL_MLT_FEC_APP_44`, junto con `SapUser` / `SapPass`.

- [ ] **Las contraseñas de SAP importadas vienen cifradas con el AES del .NET.** Rails las
      guarda con ActiveRecord Encryption (ver `config/application.rb`), que no las puede
      descifrar. Desde que `support_unencrypted_data = false`, una fila insertada así ya no
      se lee en silencio: **levanta al leerla**, que es lo correcto — antes habría mandado el
      ciphertext del .NET a SAP como si fuera la contraseña.
      **Pendiente:** en la tarea de importación, descifrar con la llave del .NET y escribir el
      valor por el modelo (para que Rails lo cifre), o dejar el campo vacío y pedir que cada
      usuario reingrese su contraseña.

> La contraseña de SAP viaja en el cuerpo de `POST /api/sap_credential_validations` y
> `PATCH /api/profile`. No es deuda: ya no queda en los logs
> (`config/initializers/filter_parameter_logging.rb`), está cifrada en reposo, y el
> transporte va forzado a HTTPS por `config.force_ssl = true`
> (`config/environments/production.rb:16`).

- [ ] **`.env.example` está ignorado por git (`/.env*` en `.gitignore`), así que no documenta
      nada para el equipo.** Las llaves `AR_ENCRYPTION_PRIMARY_KEY` /
      `AR_ENCRYPTION_DETERMINISTIC_KEY` / `AR_ENCRYPTION_KEY_DERIVATION_SALT` que hay que fijar
      en producción quedaron explicadas en `config/application.rb` (sí trackeado), pero el
      ejemplo de `.env` no llega al repo. `.env.example` no tiene secretos — solo placeholders
      y hostnames de dev.
      **Pendiente:** decidir si se agrega la excepción `!/.env.example` al `.gitignore`. Es
      política del repo, no de esta tarea.

- [ ] **La visibilidad del campo "Tipo de OC" sigue con compañías hardcodeadas.**
      `user_profile_controller.js` mantiene `COMPANIES_WITH_OC = [186, 1206]`, heredado del
      enum `CompanyWhitOC` del Angular. Son ids de la base del .NET, que no tienen por qué
      coincidir con `companies.id` de la base propia.
      **Pendiente:** convertirlo en un dato de la compañía (columna o UDF) y exponerlo en
      `GET /api/companies`, en vez de una lista de ids en el frontend.

---

## SAP — deuda del acceso a Service Layer

`vendor/clavisco/service_layer` (`ClavisCo/cl-sap-servicelayer-ruby`) ya está montado y es el
único camino a SAP, según CLAVISCO-PLATFORM-STANDARDS §2.7. Lo que quedó pendiente:

- [x] **`Sap::CredentialValidator` usaba Faraday a mano y abría una sesión por request** —
      resuelto: ahora pasa por `Clavisco::ServiceLayer::Client` y su pool singleton.

- [ ] **La validación fuerza el login con un GET de sondeo a `BusinessPartners`.** El Client
      no expone un `login` suelto: se autentica solo en el primer request. Funciona y está
      documentado en la clase, pero es un rodeo — la prueba real es el `/Login`, no el
      recurso.
      **Pendiente submódulo (`cl-sap-servicelayer-ruby`):** un método explícito
      (`Client#login` / `#authenticated?`) que fuerce la creación de la sesión y devuelva si
      funcionó. Con eso desaparecen `PROBE_RESOURCE`, `PROBE_PARAMS` y `#session_established?`.

- [ ] **`#session_established?` consulta el pool para desambiguar los errores.** Cuando el
      Client levanta un `ServiceLayerError` genérico no hay forma de saber si falló el login
      (red caída) o el recurso de sondeo (permisos del usuario en SAP) — la diferencia
      importa, porque lo primero NO prueba que las credenciales sean malas. Hoy se resuelve
      preguntándole al `LoadBalancer` si quedó sesión viva. Es API pública, pero se apoya en
      un detalle de implementación del gem.
      **Pendiente submódulo:** que el error de login y el error de recurso sean clases
      distintas, o el `Client#login` del punto anterior.

- [x] **`connections.service_layer_url` no se llamaba como el estándar** — resuelto:
      `db/migrate/20260812100000_rename_connection_columns_to_standard.rb` la renombró a
      `sl_url` (§8) y, por consistencia de prefijo, `service_layer_type` → `sl_type`.

- [ ] **`connections.sl_type` se escribe pero todavía no se lee.** Desde la migración de la
      pantalla de conexiones es el select "Motor de Base de Datos" del formulario (`CLAUDE.md`
      §22), así que ya se puebla; lo que sigue faltando es el consumidor. Se agregó para
      distinguir el motor sobre el que corre SAP (SQL Server / HANA) porque hay sintaxis de
      `SQLQueries` y funciones de fecha que difieren, pero ninguna consulta la mira aún.
      **Pendiente:** usarla cuando se escriba la primera consulta que dependa del motor, o
      borrarla si al final no aparece.

- [ ] **`roles` no tiene la columna `description`.** §4.1 la lista explícitamente
      (`roles (id, name, description, is_active)`) y `permissions` sí la tiene. No entró en
      el renombrado de `connections` porque es un `add_column`, no un rename.
      **Pendiente:** agregarla y decidir si se puebla al importar `Rol` desde SQL Server.

- [ ] **La tabla puente se llama `users_by_companies`; el estándar dice `company_memberships`.**
      Es un rename mecánico (modelo `UsersByCompany`, el scope `Company.assigned_to`, seeds y
      specs), pero se dejó junto al punto de `sap_licenses` de abajo porque esa misma tabla
      necesita ganar la columna `license_id` — conviene un solo cambio, no dos.

- [ ] **Las credenciales de SAP viven en `users`, no en `sap_licenses`.** §8 define
      `sap_licenses` (`sap_username`, `sap_password`) como catálogo de credenciales
      reutilizables, asignado a cada usuario por compañía vía la tabla puente
      (`company_memberships.license_id` en el estándar; acá el equivalente es
      `users_by_companies`). Este producto las tiene en `users.sap_user` /
      `users.sap_password`, que es lo que heredó del .NET y lo que consume hoy
      `PATCH /api/profile`.
      **Pendiente:** decidir si se migra al modelo del estándar. No es solo mover columnas:
      cambia la pantalla de perfil (una credencial por compañía, no una por usuario) y el
      payload del endpoint. Coordinar con la tarea de importación de usuarios.

---

## Conexiones SAP — endpoints migrados a Rails (`/configurations/connections`)

La pantalla ya no toca el .NET: `GET|POST /api/connections`, `GET|PATCH /api/connections/:id` y
`GET /api/connections/assignable` son nativos y leen/escriben la tabla propia `connections`.
El formulario se recortó a las tres columnas que existen (`name`, `sl_url`, `sl_type`) — ver
`CLAUDE.md` §22. Lo que quedó pendiente:

- [ ] **La tabla `connections` está vacía.** Igual que `companies` y `users_by_companies`: hasta
      que se importen los datos, el listado sale sin filas y el selector "Conexión de SAP" del
      formulario de compañías queda sin opciones. La fuente es SQL Server `CLSQL03`, base
      `CL_CL_MLT_FEC_APP_44`, tabla `SAPConnection`.
      **Pendiente:** incluirla en la tarea de importación con el mapeo `Server → name`,
      `APIUrl → sl_url`, `DBEngine → sl_type`. Ojo con `name`: es único entre las conexiones
      activas y `Server` del origen puede venir repetido — hay que decidir el desempate
      (sufijo con el `APIUrl`, o elegir un nombre a mano) antes de importar.

- [x] **Los parámetros de DI-API/ODBC se eliminan por completo — no son deuda.** `SAPConnection`
      del .NET tenía `LicenseServer`, `CrystalAPIUrl`, `ODBCType`, `ServerType`, `DBUser`,
      `DBPass`, `BoSuppLangs`, `DST` y `UseTrusted`. **Decisión de producto (2026-08-12):** el
      esquema de la tabla `connections` de Rails es el que manda; lo que no está ahí muere.
      Este producto llega a SAP únicamente por Service Layer (`CLAUDE.md` §29), así que esos
      campos no tienen consumidor vivo: los sistemas que se conectaban por DI-API quedan fuera
      de alcance, no hay que preservarlos ni volver a agregarlos.
      Con eso también queda cerrado el `DBPass` cifrado con el AES del .NET: no se importa ni
      se recrea la columna.

- [ ] **No hay forma de verificar que una conexión responde.** Al guardarla solo se valida el
      formato de la URL; nadie contacta el `sl_url`. La pantalla de perfil sí prueba
      credenciales (`POST /api/sap_credential_validations`), pero contra una compañía, no
      contra una conexión suelta.
      **Pendiente:** evaluar un botón "Probar conexión" que haga un GET de sondeo al `sl_url`
      reutilizando el `Client` del submódulo. No es bloqueante: un `sl_url` malo se detecta al
      primer uso real.

- [ ] **`connections/new` y `connections/:id/edit` siguen ruteadas pero nadie las abre.** El
      panel lateral del listado las reemplazó; se mantienen en sync (`CLAUDE.md` §22 #3) por si
      alguien llega por URL directa.
      **Pendiente:** decidir si se borran junto con `connection_form_controller.js`,
      `_form.html.erb`, `new.html.erb` y `edit.html.erb`, o si se conservan.

---

## Seguridad — endpoints migrados a Rails (`/configurations/security`)

La pantalla ya no toca el .NET: `GET|POST /api/roles`, `PATCH /api/roles/:id`,
`GET|PUT /api/roles/:id/permissions` y `GET /api/permissions/catalog` son nativos.
Lo que quedó pendiente:

- [ ] **⚠️ CAMBIO DE COMPORTAMIENTO: el listado de roles ya no se filtra por compañía.**
      El .NET pedía `GetRoles?companyId=N` y creaba el rol con `spCreateRole(RoleWithCompany)`:
      allá un rol pertenecía a una compañía. En el esquema propio `roles` **no tiene**
      `company_id` — la compañía vive en `user_roles` —, que es lo que manda
      CLAVISCO-PLATFORM-STANDARDS §4.1 (`roles (id, name, description, is_active)`).
      Consecuencia práctica: quien administra la seguridad de una compañía ahora **ve y
      puede renombrar los roles que usan las demás**. No hay forma de acotarlo sin agregar
      la columna, y agregarla contradice el estándar.
      **Pendiente:** confirmar con el negocio que el rol global es lo que se quiere. Si no
      lo es, hay que decidir entre `roles.company_id` (se aparta del estándar) o roles
      globales con nombres convenidos por compañía. Definirlo **antes** de importar `Rol`
      desde SQL Server: si allá hay roles homónimos en compañías distintas, la validación
      de unicidad de `name` los va a rechazar.

- [ ] **`GET /api/permissions` y `GET /api/permissions/catalog` están al revés.**
      El `index` de un recurso debería ser su colección — el catálogo —, pero ese path ya
      lo ocupaban los permisos **efectivos** del usuario de la sesión, que consumen
      `menu_controller.js`, `auth_guard_controller.js` y `company_selector_controller.js`.
      Renombrarlo en esta tarea significaba tocar las tres pantallas que sostienen el menú
      y el guard, así que se dejó el catálogo en una subcolección.
      **Pendiente:** cuando se toquen esas pantallas, intercambiar —
      `GET /api/permissions` = catálogo y `GET /api/session/permissions` = permisos
      efectivos (el namespace `session` ya existe por `PUT /api/session/company`).

- [ ] **La pantalla no inhabilita nada por permisos.** El servidor sí exige
      `Configurations_Security_Access` para los roles y `Configurations_Permissions_Access`
      para la asignación, pero `roles_controller.js` no lee `SStore.get('Permissions')`:
      los botones "Nuevo Rol", editar y permisos se ven habilitados siempre y el usuario
      sin permiso se entera recién con el 403.
      **Pendiente:** aplicar §26 — deshabilitar con tooltip explicativo, como ya hacen
      `connections_controller.js` y `numbering_controller.js`.

- [ ] **No se puede activar ni desactivar un rol.** La tabla muestra el badge Activo/Inactivo
      y `roles.is_active` existe, pero la pantalla solo crea y renombra: `PATCH /api/roles/:id`
      a propósito **solo toca el nombre**. Un rol creado por error queda para siempre.
      **Pendiente:** decidir si la pantalla gana la acción de baja (soft delete) y agregar
      `Active` al endpoint.

- [ ] **La protección del rol `OWNER` está dormida.** `Role::PROTECTED_NAMES` bloquea
      renombrarlo y reasignarle permisos (la UI ya lo hacía; el servidor lo hace de nuevo
      por §26), pero **ese rol no existe en la base propia**: `db/seeds.rb` crea
      `Administrador`. Viene del .NET y aparecería recién con la importación.
      **Pendiente:** al importar `Rol`, confirmar si `OWNER` llega con ese nombre exacto —
      la comparación es case-insensitive pero literal — o si el rol reservado pasa a ser
      `Administrador`.

- [ ] **`roles.description` sigue sin existir.** §4.1 la pide y el formulario no la ofrece,
      así que el endpoint tampoco la expone. Ya estaba anotada más arriba (sección SAP);
      se repite acá porque es esta pantalla la que tendría que capturarla.

- [ ] **`CompanyScoped` afloja la obligatoriedad de `company` en `UserRole`.** El concern
      declara `belongs_to :company, optional: true` dentro de su bloque `included do`, y
      `UserRole` no vuelve a declarar la asociación: el resultado es que
      `UserRole.new(user:, role:).valid?` devuelve **true** sin compañía y el guardado
      revienta abajo con `ActiveRecord::NotNullViolation` (la columna es `null: false`).
      Verificado en consola. **Ya hay un endpoint que crea `UserRole`**
      (`PUT /api/users/:id/role`): ahí no revienta porque un `before_action` exige compañía
      activa antes de tocar la base, pero esa es una guarda del controller, no del modelo —
      el próximo que escriba `user_roles` se lleva el 500.
      **Pendiente:** agregar `validates :company, presence: true` en `UserRole` (o
      redeclarar `belongs_to :company` después del `include`). Lo correcto de fondo es que
      el submódulo no imponga `optional: true` — anotarlo para `cl-data-access-ruby`.

---

## Usuarios — endpoints migrados a Rails (`/configurations/users`, tab "Lista de usuarios")

La pantalla quedó **sin tabs**: es la lista de usuarios. Todo lo que se le concede a un
usuario —rol, permisos globales y compañías— vive en los tres sub-tabs del panel
"Gestionar accesos", que es una acción de fila.

**Ya no toca el .NET en absoluto.** Son nativos `GET|POST /api/users`,
`GET|PATCH /api/users/:id`, `GET|PUT /api/users/:id/companies`,
`GET|PUT /api/users/:id/role`, `GET|PUT /api/users/:id/permissions`,
`GET /api/companies/assignable` y `GET /api/permissions/catalog?type=global`.
`users_controller.js` se quedó con un solo cliente HTTP (`#railsFetch`): el `#apiFetch`
que armaba el Bearer para el proxy se borró con el último tab que lo usaba.

- [x] **⚠️ CAMBIO DE UI: el tab "Completar registro" desapareció, y con él
      `/configurations/users/register`.** El tab activaba usuarios pendientes de
      confirmar su correo y reenviaba el correo de confirmación; la página era el alta
      que ya había reemplazado el panel lateral del listado (quedó huérfana: nada la
      enlazaba). Los dos dejaron de tener sentido con el IdP — no hay contraseña propia
      ni correo que confirmar, y el alta nace activa.
      Se eliminaron: el tab, la barra de tabs entera, `users#register` con su ruta y su
      vista, y `users_register_controller.js` con su registro en `index.js`.
      Dejaron de tener consumidor tres endpoints del .NET: `GET /api/User/GetInactiveUsers`,
      `PATCH /api/User/activate` y `POST /api/User/email-confirmations`.
      El permiso `S_CompUser`, que gateaba el tab, queda huérfano: se sigue sembrando
      porque el catálogo replica el del origen, pero ya nadie lo evalúa y **no tiene
      sucesor** — está registrado como tal en `db/permission_name_map.yml`.

- [x] **`/configurations/users/edit` se eliminó igual que `register`** — vista, acción,
      ruta y `users_edit_controller.js`. Estaba huérfana (la edición es el panel lateral)
      y rota: llamaba `GET /api/User/information`, `GET /api/User/companies`,
      `PATCH /api/User` y `POST /api/SapConnections/validate-credentials`, endpoints del
      .NET ya migrados que hoy caen al proxy y responden 401.
      `Configurations::UsersController` quedó con una sola acción, `index`.

- [x] **El rename y las bajas ya se aplican sobre la tabla, no solo en el seed** —
      `db/migrate/20260812130000_apply_permission_catalog_changes.rb`. Hacía falta porque
      `db:seed` **borra y recrea el catálogo entero**: sirve para levantar un ambiente de
      cero, no para una base con datos reales, donde eso se lleva puestas las asignaciones
      de `role_permissions` y `user_permissions`. Un cambio de catálogo en una base viva es
      una migración.
      La migración es reversible e idempotente (no renombra si el destino ya existe), y
      deja el mismo estado final que un seed desde cero: 88 activos + 4 de baja.

- [ ] **Renombrado de permisos: existe `db/permission_name_map.yml`.** Los nombres `S_*`
      del origen describen dónde estaba el botón en el menú Angular, no qué autorizan, así
      que se renombran a la convención §4.4. La equivalencia con el nombre de origen vive
      en ese archivo, y **la tarea de importación DEBE leerlo y traducir antes de
      insertar**: las filas de `PermissionByRol` siguen apuntando al nombre viejo, y sin
      traducir crearían un permiso huérfano y los roles reales perderían el acceso en
      silencio.
      **Pendiente:** agregar una entrada cada vez que se renombre otro, y resolver el caso
      anotado de `S_RegUser`, que **no** es un rename puro — los dos nombres existen en el
      catálogo de origen (Id 7 y 64), así que hay que decidir cuál sobrevive antes de
      importar.

- [x] **`db:seed` reventaba con `FOREIGN KEY constraint failed`** — encontrado al aplicar
      el rename. `RolePermission.delete_all` respeta el `default_scope` de `SoftDeletable`,
      así que borraba solo las filas activas: las revocadas sobrevivían apuntando a
      `permissions` y el `Permission.delete_all` siguiente chocaba contra la FK. Bastaba
      con haber revocado un permiso de un rol alguna vez. Resuelto con `unscoped` en los
      tres `delete_all`, y agregando `UserPermission` a la limpieza (faltaba desde que se
      creó la tabla).

- [x] **⚠️ CAMBIO DE UI: el tab "Asignación de compañías" desapareció.** Era un segundo
      buscador de usuarios —un autocomplete que solo matcheaba por correo y cortaba a 50
      resultados— compitiendo con la tabla de la Lista, que tiene búsqueda por nombre y
      correo, paginación y estado. Y dejaba la asignación de compañías separada del rol y
      de los permisos globales, que ya eran acción de fila.
      Ahora es el sub-tab "Compañías" del panel de accesos, con checkboxes en vez de la
      lista dual con drag & drop (en un panel de 512px el arrastre queda apretado, y de
      fondo esto es un multi-select).
      Se cayeron con el tab: `GET /api/users/assignable` (sin consumidor — el usuario sale
      de la tabla) y el `GET /api/User/for-assignments` que reemplazaba.

- [x] **⚠️ CAMBIO DE COMPORTAMIENTO: el alcance de la asignación es el del administrador.**
      `GET /api/companies/assignable` devuelve las compañías del solicitante, no todas las
      de la instalación; `PUT /api/users/:id/companies` rechaza con 403 lo que esté fuera
      de ese alcance. Cierra una incoherencia: `POST /api/users` ya validaba
      `Company.assigned_to(Current.user.id)`, así que crear un usuario en una compañía
      ajena estaba prohibido pero asignárselo después, permitido.
      La vía de escape es `Configurations_Companies_ViewGroupCompanies` (ya en el catálogo;
      bajo §31 "las compañías del grupo" son las de la instalación), necesaria para poder
      asignarle su primera compañía a alguien en una sociedad donde el administrador no
      opera.
      **El reemplazo completo NO revoca lo que está fuera de alcance** — sin ese filtro, el
      administrador de una sociedad le sacaría al usuario el acceso a otra sin enterarse.
      La UI las muestra marcadas y deshabilitadas con su motivo (§26).
      **Pendiente:** confirmar con el negocio quién debería tener
      `Configurations_Companies_ViewGroupCompanies`. Hoy el seed se lo da a todos.

- [ ] **El permiso de asignación se llama `S_AsigUser` y no sigue la convención §4.4.**
      Debería ser `Configurations_Users_AssignCompanies`, pero ese nombre **no existe en
      el catálogo** — a diferencia de `S_RegUser`, que sí tenía su equivalente moderno
      (`Configurations_Users_Create`) y por eso se pudo cambiar. Inventar un permiso que
      no está en el origen rompería la importación de `PermissionByRol`.
      **Pendiente:** al arreglar el catálogo (ver la entrada de permisos incompletos más
      arriba), renombrarlo junto con `S_CompUser`. Son los dos que quedan con el nombre
      viejo.

- [x] **Los permisos globales por usuario ya tienen dónde guardarse** — resuelto:
      `db/migrate/20260812120000_create_user_permissions.rb` crea la tabla puente
      usuario↔permiso, **sin `company_id`** (un permiso global aplica a nivel de
      aplicación; atarlo a una compañía obligaría a repetir la fila por cada una).
      Es la **segunda y última** vía de concesión del producto, y está acotada a los
      permisos `type = 'global'` por una validación del modelo, no del controller.
      La concesión **surte efecto de verdad**: `Api::AuthorizedController#permission?` la
      evalúa además de la vía por rol, y `GET /api/permissions` devuelve la unión de las
      dos. `AuthorizationService` solo conoce la vía por rol —vive en un submódulo y no
      se toca (§27)—, así que la unión se arma del lado de la app. Ver `CLAUDE.md` §28.
      CLAVISCO-PLATFORM-STANDARDS §4.1 no la lista porque describe el mínimo obligatorio
      (permisos por rol), no un tope.

- [ ] **`user_permissions` nace vacía: nadie tiene permisos globales todavía.** La tabla
      existe y los endpoints funcionan, pero las concesiones reales viven en
      `PermissionByUser` del .NET y no se importaron.
      **Pendiente:** incluirla en la tarea de importación desde SQL Server, junto con
      `Rol` / `PermissionByRol` / `RolByUser`. Ojo con dos cosas: (a) el origen puede
      tener concedidos permisos que acá son `type = 'normal'` —la validación los va a
      rechazar y hay que decidir caso por caso si el permiso estaba mal clasificado o la
      concesión estaba de más—, y (b) el índice único no excluye inactivos, así que
      importar duplicados con distinto `is_active` va a chocar.

- [ ] **`db/seeds.rb` no siembra ninguna concesión global.** El rol `Administrador`
      recibe los 92 permisos —incluidos los 25 `global`— por la vía del rol, así que en
      desarrollo el sub-tab se ve pero no cambia nada observable: el permiso ya venía
      concedido por otro lado.
      **Pendiente:** para probar la vía directa de verdad hay que sembrar un usuario sin
      esos permisos en su rol. Hoy se cubre solo en specs.

- [x] **⚠️ CAMBIO DE COMPORTAMIENTO: el usuario nuevo nace ACTIVO.** El .NET lo creaba con
      `Active: false` a la espera de que confirmara su correo, y el tab "Completar registro"
      lo activaba. Ese paso lo reemplazó el IdP: no hay contraseña propia ni correo que
      confirmar. Además, crear inactivo lo volvería **invisible** — el `default_scope` de
      `SoftDeletable` lo escondería del listado apenas se guarda.
      Confirmado: el tab se eliminó (ver la entrada de arriba). Dar de baja y reactivar
      sigue siendo posible desde el panel de edición, con el check "Activo".

- [ ] **⚠️ CAMBIO DE COMPORTAMIENTO: el botón "Nuevo Usuario" ahora exige
      `Configurations_Users_Create` y ya no `S_RegUser`.** Los dos permisos existen en el
      seed; se eligió el primero porque es el que sigue la convención §4.4 del estándar
      (`{Módulo}_{Recurso}_{Acción}`) y es el que exige `POST /api/users`. Hoy no rompe nada
      porque el seed le da los 80 permisos a todo el mundo.
      **Pendiente:** al importar `PermissionByRol` desde SQL Server, revisar si algún rol
      real tiene `S_RegUser` y no `Configurations_Users_Create` — ese rol perdería el botón.
      Anotado en `db/permission_name_map.yml`, que es de donde la importación tiene que
      leer las equivalencias.

- [ ] **Campos eliminados del formulario por no tener columna.** Siguiendo la regla de que
      manda la tabla: `Correo Confirmado` (columna de la tabla), `Identificación` (panel de
      edición), `Cédula` y `Cuenta` / grupo (panel de creación). Los tres primeros venían de
      ASP.NET Identity y no los reemplaza nada acá; el último dependía de una tabla `groups`
      que no existe.
      **Pendiente:** confirmar con el negocio que la cédula del usuario no hace falta en
      ningún reporte. Si hiciera falta, primero la migración que agrega `users.identification`
      y la razón, nunca un campo que se manda al API "por compatibilidad".

- [x] **El alcance del listado.** `GET /api/users` devuelve los usuarios de la compañía
      activa, o **todos** si el solicitante tiene
      `Configurations_Users_ViewAllApplicationUsers`. El tercer alcance del .NET,
      `Configurations_Users_ViewGroupUsers`, **no se implementa y no es deuda**: "los
      usuarios de mi grupo" es idéntico a "los de la instalación" cuando cada cliente tiene
      su propia instancia (`CLAUDE.md` §31). Quien tenga solo ese permiso ve el alcance de
      compañía.

- [ ] **La búsqueda no ignora acentos.** El `LIKE` de SQLite solo ignora la caja en ASCII:
      buscar `SOLÍ` no encuentra a `Solís` (sí lo encuentra `solí`). Aplica igual a
      `Connection.search`. No se corrigió porque `LOWER()` tampoco cubre acentos sin la
      extensión ICU.
      **Pendiente:** se resuelve solo al pasar a SQL Server, cuya collation por defecto es
      case e accent insensitive. Verificarlo ahí en vez de meter un workaround en Ruby.

- [x] **La tabla "Completar registro" mostraba "Correo Confirmado"** — se fue con el tab.

---

## Grupos de compañías — código muerto por decisión de producto

Esta versión se despliega **una instancia por cliente / grupo económico**, así que el
concepto de grupo desapareció: el aislamiento entre clientes lo da el despliegue, no una
columna. La regla completa está en `CLAUDE.md` §31. Lo que quedó sin limpiar:

- [ ] **La pantalla `/configurations/group` sigue existiendo entera.** Vista
      (`app/views/configurations/group/index.html.erb`), controller
      (`app/controllers/configurations/group_controller.rb`), `group_controller.js` y su
      registro en `app/javascript/controllers/index.js`. Consume `/api/Group/*` vía proxy.
      **Pendiente:** borrarla junto con su ruta y su nodo de menú. Es una tarea aparte
      —borrar una pantalla completa no se hace de pasada dentro de otra migración— y hay
      que confirmar antes que ningún cliente en producción dependa de verla.

- [ ] **Quedan llamadas a `/api/Group/*` en dos controllers JS.**
      `companies_controller.js` y `company_form_controller.js` (selector de grupo en el
      formulario de compañías). El tercero, `users_register_controller.js`, se eliminó
      junto con la página de alta de usuarios.
      **Pendiente:** eliminarlas al migrar esas pantallas, con el mismo criterio que se usó
      acá — el filtro se va junto con la consulta que lo alimentaba (§24), no se conserva
      mandando un valor por defecto.

- [ ] **Seis permisos de grupos siguen activos porque los evalúa la pantalla que falta
      borrar.** `S_Groups` (nodo de menú) y los cinco `Configurations_Groups_*` que lee
      `group_controller.js`. Darlos de baja ahora dejaría la pantalla inalcanzable sin
      que nadie lo haya decidido.
      **Pendiente:** al borrar `/configurations/group`, agregarlos a `DEACTIVATE` de una
      migración nueva y a `DEACTIVATED` en `db/seeds.rb` — las dos listas tienen que
      coincidir. Están anotados en `db/permission_name_map.yml` con `deactivated: false`.

- [x] **Los tres permisos de grupos que ya nadie evaluaba se dieron de baja** —
      `Configurations_Users_ViewGroupUsers`, `Configurations_Companies_ChangeGroup` y
      `Configurations_Groups_ViewAllApplicationGroups`, junto con `S_CompUser`.
      Baja lógica (`is_active = false`), no `DELETE`: §2.2 lo prohíbe y borrar la fila
      arrastraría las de `role_permissions` / `user_permissions` que la referencien.

> ⚠️ `Configurations_Companies_ViewGroupCompanies` **no** es huérfano, aunque tenga
> "Group" en el nombre: es la vía de escape del alcance de asignación de compañías
> (`AssignableCompanies::SEE_ALL_COMPANIES`). Sin grupos, "las compañías del grupo" son
> las de la instalación, que es exactamente lo que habilita.

---

## Cumplimiento del estándar — pendientes y correcciones a proponer

Revisión contra `ClavisCo/platform-standards` (commit `84752f1`). Lo que ya se corrigió está
en `[x]`; lo que sigue abierto necesita una decisión, no solo trabajo.

- [x] **§2.4 — el middleware `ErrorHandler`/`RequestLogger` no estaba registrado.** Estaban
      aliasados en `clavisco_submodules.rb` pero nunca montados, así que una excepción en
      `/api/*` salía como HTML vacío con 500 en vez del contrato `ApiResponse`. Cubierto por
      `spec/requests/api/error_handler_spec.rb`.

- [ ] **⚠️ El snippet de §2.4 está mal y hay que proponer la corrección aguas arriba.** El
      estándar dice `config.middleware.insert_before Rails::Rack::Logger, ErrorHandler`. En esa
      posición el middleware queda **por fuera** de `ActionDispatch::ShowExceptions`, que es
      quien rescata las excepciones del controller y renderiza sin re-lanzarlas
      (`show_exceptions = :all`, el default en los tres ambientes). Con el snippet literal el
      `ErrorHandler` **nunca corre**: verificado, `GET /api/roles` con una excepción adentro
      devuelve `text/html` con cuerpo vacío.
      Acá se registra con `insert_after ActionDispatch::DebugExceptions`, que sí funciona.
      **Pendiente:** proponer el cambio en `platform-standards` §2.4. Cualquier producto que
      haya copiado el snippet tal cual tiene un ErrorHandler muerto y no se enteró.

- [x] **§1.5 — DSN de Sentry hardcodeado en el repositorio.** `config/initializers/sentry.rb`
      tenía `ENV.fetch('SENTRY_DSN', 'https://86ce06ab...@o4511328163725312...')`: un secreto
      real commiteado y, de paso, el mismo DSN para todos los ambientes (§10 pide uno por
      deployment). Ahora es `ENV['SENTRY_DSN']` sin fallback. También se apagó
      `send_default_pii`, que mandaba cabeceras y cuerpo de cada request a Sentry — justo lo
      que `filter_parameter_logging.rb` evita en los logs propios.
      **Pendiente operativo:** el DSN viejo quedó en el historial de git. Si el proyecto de
      Sentry sigue en uso, **rotarlo**.

- [ ] **§1.5 — quedan tres `ENV.fetch` con fallback hacia el backend legado.**
      `config/initializers/proxy.rb` define `API_FE_SYNC_URL`, `API_FE_APP_URL` y
      `API_CABYS_URL` con hostnames de desarrollo como valor por defecto. La regla es literal:
      *"ningún puente hacia un backend legado usa un valor hardcodeado como fallback... si la
      variable falta, debe fallar explícitamente"*. El riesgo real es que producción arranque
      apuntando a los servidores de dev sin que nadie lo note.
      **Pendiente:** decidir si se quitan los defaults (rompe el arranque de quien no tenga
      `.env`) o si se toleran solo fuera de producción con un `raise` en `production`.

- [x] **§1.6 — la reasignación de permisos por rol escribía checkbox por checkbox.** El
      estándar nombra ese caso exacto como el N+1 de la escritura. Ahora es un `insert_all`
      más dos `update_all`, con las columnas de auditoría escritas a mano (las operaciones en
      lote no disparan los callbacks de `Auditable`). Fijado por spec que cuenta las sentencias.

- [x] **§7.1/§1.6 — faltaba la gema `bullet`.** Agregada al grupo `development` y configurada
      en `config/environments/development.rb`.

- [x] **§4.5 — un `skip_permission_check!` sin justificación adyacente.**
      `Api::ProfilesController#update`. Los demás ya la tenían.

- [ ] **§4.4/§4.5 — los endpoints de escritura de roles se protegen con un permiso `_Access`.**
      `POST /api/roles` y `PATCH /api/roles/:id` exigen `Configurations_Security_Access`, y
      `PUT /api/roles/:id/permissions` exige `Configurations_Permissions_Access`. §4.5 pide que
      el permiso *corresponda de verdad a la acción* (su ejemplo: un `#destroy` no debería
      usar un permiso terminado en `_View`).
      **No se inventaron** `Configurations_Security_Create` / `_Update`: el catálogo de
      permisos está pendiente de importación (ver más arriba, faltan 11 ids) y crear nombres
      que nadie tenga asignado dejaría la pantalla de seguridad inutilizable con 403 apenas se
      importe. El catálogo actual solo tiene `_Access` para esta pantalla, mientras que para
      conexiones sí distingue `_Create`/`_Update` (ids 61 y 62) — la inconsistencia viene del
      origen.
      **Pendiente:** resolverlo junto con la importación del catálogo, no antes.

- [ ] **§8 — faltan `sap_licenses` y el rename a `company_memberships`.** Ya anotado arriba en
      la sección de SAP. §8 es explícito en que las 8 tablas son *"no-negociables en todo
      producto, sin condicional. La ausencia de cualquiera de ellas es ❌, nunca N/A"*.

- [ ] **`AUDITORIA_PLATFORM_STANDARDS.md` está desactualizado.** Reporta como ❌ HIGH cosas ya
      resueltas (los submodules no instalados, el token en `localStorage`, `Current` inexistente)
      y marca §2.7 como N/A por *"producto sin integración SAP directa"*, que es falso.
      **Pendiente:** re-correr la auditoría o fechar el documento como instantánea histórica.

---

## Submódulos — cambios que corresponden a `cl-auth-ruby`

Estas tres cosas están resueltas **con workarounds en este producto** porque el submódulo
`vendor/clavisco/auth` no las ofrece y su código **no se toca desde acá** (ver `CLAUDE.md`
§27). Cada una debe implementarse en el repo `Crisql/cl-auth-ruby`; al mergearse allá, se
mueve el puntero del submódulo y se borra el workaround.

- [ ] **`logout_url` no acepta `id_token_hint`.** Sin ese parámetro Keycloak 18+ no cierra la
      sesión SSO: muestra una pantalla de confirmación y, si el usuario no la confirma, el
      siguiente login entra sin pedir credenciales.
      **Workaround:** `AuthController#provider_logout_url` concatena `&id_token_hint=` a la URL
      que devuelve el submódulo, solo cuando el proveedor es Keycloak.
      **Pendiente submódulo:** `logout_url(return_to:, id_token_hint: nil)` en
      `lib/clavisco/auth/oidc_client.rb`, incluyendo el parámetro para Keycloak e ignorándolo
      en Auth0 (su `/v2/logout` no lo entiende). Probado localmente contra el Keycloak real:
      la URL con el hint es correcta y el rechazo que veíamos era por el post-logout URI sin
      registrar en el cliente `fec`, no por el hint.

- [ ] **No existe `OidcConfig.build` — los endpoints se derivan en el producto.**
      CLAVISCO-PLATFORM-STANDARDS §2.3 exige derivar authorize/token/jwks/logout desde
      `Clavisco::Auth::OidcConfig.build(domain:, client_id:, client_secret:, provider:, realm:,
      audience:)`; esa clase no existe en el submódulo.
      **Workaround:** `config/initializers/oidc.rb` arma el `Struct` y el `case provider` a mano
      (issuer sin slash final y JWKS en `/protocol/openid-connect/certs` para Keycloak).
      **Pendiente submódulo:** crear `OidcConfig` y reemplazar el initializer por una llamada
      a `build`.

- [ ] **`JwtValidator` hardcodea el patrón de Auth0 — rompe el Bearer con Keycloak.**
      `initialize` solo acepta `domain:`/`audience:`, fija `@issuer = "https://#{domain}/"`
      (Keycloak no lleva slash final) y busca las llaves en
      `https://#{domain}/.well-known/jwks.json` (Keycloak las publica en
      `/protocol/openid-connect/certs`). Resultado: **ningún Bearer JWT valida contra Keycloak**,
      en silencio, hasta que alguien consume la API con token.
      **Sin workaround en el producto** — hoy no pega porque la UI usa la session cookie, no
      Bearer. El initializer ya calcula `issuer` y `jwks_uri` correctos, pero nadie los consume.
      **Pendiente submódulo:** `initialize(domain:, audience:, issuer: nil, jwks_uri: nil)`
      leyendo esos valores de la config, con el patrón Auth0 solo como fallback.

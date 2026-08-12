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

## Perfil de usuario — endpoints migrados a Rails (`/configurations/user-profile`)

La pantalla ya no toca el .NET: `GET /api/profile`, `PATCH /api/profile`,
`POST /api/sap_credential_validations` y `GET /api/companies` son nativos. Lo que quedó
pendiente:

- [ ] **`POST /api/Connections/validate-user-credentials` sigue vivo en
      `users_controller.js:470`** (pantalla de asignación de usuarios). Es exactamente el
      mismo llamado con el mismo payload que ya resuelve `POST /api/sap_credential_validations`,
      pero esa pantalla no entraba en esta migración y su semántica es distinta: valida las
      credenciales de **otro** usuario, no las propias, así que el `skip_permission_check!`
      del endpoint nativo no aplica tal cual.
      **Pendiente:** al migrar la pantalla de usuarios, apuntarla al endpoint nativo y
      agregarle el permiso que corresponda (`Configurations_Users_*`).

- [ ] **`GET /api/Group/GetGroupsByUser` no se migró: se eliminó de esta pantalla.** El
      Angular lo pedía y descartaba la respuesta (ningún campo del perfil depende de los
      grupos), así que no era deuda sino código muerto — criterio de §24. Sigue en uso en
      `group_controller.js`, `users_controller.js` y `users_register_controller.js`, que sí
      lo consumen; ahí se migra cuando toque esas pantallas (no existe todavía tabla `groups`
      en la base propia).

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

- [ ] **`connections.sl_type` no lo lee nadie.** Se agregó para distinguir el motor sobre el
      que corre SAP (SQL Server / HANA) porque hay sintaxis de `SQLQueries` y funciones de
      fecha que difieren, pero hoy ninguna consulta la usa — no la pide el estándar y el
      único código que la menciona es su migración. No confundirla con los selects "Motor de
      Base de Datos" / "Tipo de Servidor" del formulario de conexión (`CLAUDE.md` §22): esos
      viajan al API .NET, no a esta tabla.
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

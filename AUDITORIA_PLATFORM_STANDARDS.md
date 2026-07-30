# Auditoría de cumplimiento — platform-standards

- **Proyecto:** `cl_cl_mlt_fec_app` (Costa Rica) — HECA/FEC, migración UI Angular → Rails 8 + Hotwire/Stimulus
- **Repositorio:** https://github.com/Crisql/cl_cl_mlt_fec_app (privado)
- **Tipo de producto detectado:** **UI + Proxy** (BFF de migración). Rails 8 sirve vistas Hotwire/Stimulus y actúa como *proxy transparente* (`ProxyController`) hacia dos APIs externas ya existentes (`ApiAppUrl` / `ApiFEUrl`, estilo .NET) que son la fuente real de datos, permisos y lógica de negocio. **No hay modelos ActiveRecord de negocio** (`app/models/` solo tiene `application_record.rb`) ni submodules Ruby de plataforma instalados.
- **Fecha:** 2026-07-30
- **Estándar auditado contra:** `CLAVISCO-PLATFORM-STANDARDS.md` — **con salvedad importante**, ver nota abajo.

> ⚠️ **Salvedad de esta corrida.** El repositorio `ClavisCo/platform-standards` es privado. En esta sesión no fue posible traer `CLAVISCO-PLATFORM-STANDARDS.md` directo desde GitHub: no hay `gh` CLI disponible, `raw.githubusercontent.com` devolvió 404 incluso vía el Chrome autenticado del usuario, y la navegación directa a `github.com` está bloqueada por política del navegador en esta sesión. Por indicación explícita del usuario, esta auditoría se corrió en su lugar contra las **13 páginas de Confluence** ("Guías para desarrollo", espacio `desarrollo`, página raíz [3250913289](https://clavisco.atlassian.net/wiki/spaces/desarrollo/pages/3250913289)), que son un resumen de alto nivel derivado de ese mismo `.md`. Varias páginas remiten a "Sección X" del `.md` para el detalle exacto (checklist completo, queries exactas, etc.) que no estuvo disponible aquí. **Recomendación:** re-correr esta auditoría con acceso directo al `.md` en GitHub para confirmar el detalle fino de cada sección — lo que sigue es correcto al nivel de las reglas resumidas, pero puede no capturar matices que solo viven en el documento completo.

Todo hallazgo below está respaldado por lectura directa del código (`Read`/`Grep`/`Bash` sobre el repo real), no por inferencia.

> ✅ **Actualización 2026-07-30.** Se corrigieron los 4 hallazgos puramente mecánicos de esta corrida (sin cambios pendientes de decisión de equipo): CSP activada (§1, Issue 2), Tabulator vendorizado (§9), leak de listener en `documents_receptions_controller.js` (§8), y suite RSpec inicial (§9, Issue 1). Detalle en cada sección correspondiente, marcado como "✅ Corregido". Los cambios están en el working tree, sin commitear todavía. Los hallazgos arquitectónicos (§2, §3, §5, §6 e Issues 3-4) siguen abiertos — requieren decisión de equipo o acceso al `.md` completo, no una corrección de código.
>
> ⚠️ **Regresión detectada y corregida en la misma sesión.** Al activar la CSP se rompió el layout de **todas** las tablas Tabulator de la app (headers apilados verticalmente en vez de en fila). Causa: `app/javascript/vendor/clavisco/tabulator/styles/tabulator.css` tenía un `@import url('https://cdn.jsdelivr.net/...')` — una **segunda** dependencia de CDN para Tabulator (además del `pin` de JS ya corregido en §9) que la auditoría original no detectó porque solo se revisó `config/importmap.rb`, no los `@import` de CSS. La nueva CSP bloqueó correctamente ese `@import` cross-origin, y como era la única fuente del tema visual de Tabulator, la tabla quedó sin estilos. Se corrigió vendorizando el CSS real (`tabulator-tables@6.3.1/dist/css/tabulator.min.css`) directamente dentro de ese archivo. Verificado en un server de debug aparte: sin errores de CSP en consola, `.tabulator-col` con `display:inline-flex` correcto, 9 columnas detectadas. **Lección para futuras auditorías de este tipo de hallazgo: revisar también `@import` en CSS, no solo pins de JS en `importmap.rb`.**

---

## 1. Calidad de código y buenas prácticas

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Fat models / skinny controllers | N/A — mecanismo no aplica | — | No hay modelos de negocio (`app/models/` solo `application_record.rb`); toda la lógica de negocio vive en las APIs externas proxied. |
| Strong Parameters | N/A — mecanismo no aplica | — | `ProxyController#forward` reenvía `request.raw_post` sin parsear ni persistir nada localmente ([proxy_controller.rb:58](app/controllers/proxy_controller.rb:58)). |
| Sin N+1 (lectura/escritura) | N/A — mecanismo no aplica | — | Sin ORM de negocio, no hay queries que puedan tener N+1. |
| Guard clauses / SOLID | No evaluado en profundidad | — | Varios controllers Stimulus superan 700-1000 líneas (`company_form_controller.js`, `documents_reception_create_controller.js`) mezclando validación, render de UI y fetch; no se confirmó una violación puntual de SRP con evidencia concreta, se deja como señal a revisar, no como hallazgo. |
| Sin código muerto en JS | No auditado | — | Requiere análisis estático (ts-prune/knip) fuera del alcance de esta corrida; no se reporta sin evidencia. |
| Seguridad — CSP activo | ✅ Corregido | ~~HIGH~~ | [config/initializers/content_security_policy.rb](config/initializers/content_security_policy.rb) — `script-src 'self'` con nonce por request (`content_security_policy_nonce_generator`); `style-src` mantiene `unsafe-inline` de forma deliberada y documentada por el uso extensivo de `style="..."` inline en badges/tooltips (ver §7-8). El `<script>` inline del auth-gate en `protected.html.erb` se migró a `javascript_tag nonce: true`. Verificado con specs de request ([spec/requests/content_security_policy_spec.rb](spec/requests/content_security_policy_spec.rb)) que confirman el header y el nonce coincidiendo con el script. |
| Seguridad — sin credenciales por defecto | ⚠️ Parcial | MEDIUM | [config/initializers/sentry.rb:2](config/initializers/sentry.rb:2) hardcodea un DSN real de Sentry como fallback de `ENV.fetch`, en vez de fallar/quedar en blanco si falta la variable. El DSN de Sentry no es una credencial de alto riesgo (es semi-público por diseño), pero el patrón "credencial embebida en código como default" es exactamente lo que la regla prohíbe. |
| Seguridad — errores genéricos al cliente | ⚠️ Parcial | LOW | [proxy_controller.rb:83-86](app/controllers/proxy_controller.rb:83) devuelve `"API request failed: #{e.message}"` al browser en timeouts/errores de red — no expone stack trace, pero sí el mensaje crudo de la excepción Ruby (puede incluir host/puerto internos en fallos de conexión). |
| Seguridad — `reset_session` al cerrar sesión | N/A — mecanismo no aplica | — | No hay sesión de Rails: el logout es 100% client-side (limpieza de `localStorage`). Ver hallazgo relacionado en §3. |
| Rendimiento — debounce en buscadores | ✅ Cumple | — | `debounce` implementado en los componentes vendor genéricos de búsqueda: [search-modal](app/javascript/vendor/clavisco/search-modal/controllers/search_modal_controller.js), [slide-search](app/javascript/vendor/clavisco/slide-search/controllers/slide_search_controller.js). |

---

## 2. Submodules Ruby de plataforma

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Submodules `vendor/clavisco/*` (structures, common, data_access, licensing, app_menu, service_layer) instalados como git submodules | ❌ No cumple | **HIGH** | `.gitmodules` no existe; `find vendor -maxdepth 3` no encuentra ninguna carpeta `vendor/` a nivel Ruby (solo existe `app/javascript/vendor/clavisco/*`, que es JS, no los submodules Ruby). No hay `clavisco_submodules.rb`, ni `ApiResponse`, ni `Auditable`/`SoftDeletable`. |
| Contrato `ApiResponse` en respuestas | N/A/❌ | — | El único controller de API (`ProxyController`) reenvía el body crudo del backend externo tal cual (`render body: response.body`, [proxy_controller.rb:77](app/controllers/proxy_controller.rb:77)) — correcto para un proxy transparente, pero significa que este producto no emite el contrato `ApiResponse` en ningún punto propio. |

**Nota:** esto es consistente con la arquitectura "UI + Proxy" del producto — las piezas que estos submodules resuelven (auditoría de datos, licensing, permisos, cliente SAP) ya existen del lado de las APIs externas que este repo consume, no se reconstruyen aquí. El estándar permite desviaciones cuando el código depende de un sistema en migración, **pero exige que quede declarado explícitamente en el código** (namespace o comentario) — eso no está presente hoy: ningún controller ni README documenta "este producto es solo UI+proxy, por eso no usa los submodules de plataforma". Por eso se reporta como HIGH y no como N/A: la ausencia del mecanismo es real y no está justificada por escrito en el repo, aunque arquitectónicamente tenga sentido.

---

## 3. Autenticación y autorización (OIDC)

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Tokens nunca en `localStorage` — viven en session cookie de Rails | ❌ No cumple | **HIGH** | Documentado explícitamente en el propio código: `app_controller.rb:7` — *"La autenticación es 100% client-side (token en localStorage)"* ([application_controller.rb:7](app/controllers/application_controller.rb:7)), repetido en [sessions_controller.rb:7-8](app/controllers/sessions_controller.rb:7). El JS lee/escribe el token vía `Storage.get('Session').access_token` (patrón documentado en `CLAUDE.md` del proyecto, §6). |
| No acoplar el código a un proveedor OIDC específico | N/A — mecanismo no aplica | — | Este producto no implementa un flujo OIDC (Auth0/Keycloak) en absoluto: el login delega 100% en el `/token` del API externo (`ApiFEUrl`), replicando 1:1 el `UrlInterceptor` del Angular legacy ([proxy_controller.rb:19-21](app/controllers/proxy_controller.rb:19)). No hay `state`/`nonce`/validación de firma de `id_token` que auditar porque no hay integración OIDC que la use. |

**Es una desviación deliberada y documentada**, no un descuido: el proyecto es una migración de UI que replica a propósito el comportamiento del Angular legacy (que ya guardaba el token en `localStorage` y no tenía OIDC). Aun así, el estándar marca esto como "no negociable" y el riesgo real (robo de token vía XSS, dado que no hay `httpOnly` cookie) sigue vigente sin importar la razón histórica — por eso se reporta como HIGH, no se cierra como N/A, y se deja para que el equipo decida si documentarlo como excepción aceptada o planificar la migración a session cookie.

---

## 4. SAP Object Sync — UDTs y UDFs

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Sync de UDT/UDF vía `cl-sap-udfs-ruby` + `connections.json` + rake tasks | N/A — mecanismo no aplica | — | No hay `config/sap_schemas/*.json`, ni `cl-sap-udfs-ruby`, ni `cl-sap-servicelayer-ruby` como submodule. El producto no habla con SAP Service Layer directamente: todo el acceso a SAP pasa por las APIs externas proxied (`ApiAppUrl`/`ApiFEUrl`), que son quienes en teoría ya usan esa pieza de plataforma. Coherente con la arquitectura de proxy — no se reporta como incumplimiento. |

---

## 5. Sistema de permisos

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Verificación de permiso (`require_permission!`) al inicio de cada acción, antes de lógica de negocio | ❌ No cumple / N/A ambiguo | **HIGH** | `grep -rn "require_permission!\|skip_permission_check!" app/controllers` → 0 resultados. Ningún controller Rails verifica permisos — la verificación real ocurre (se asume) del lado del API externo al recibir el request proxied, y del lado del cliente solo a nivel de UI (botones deshabilitados, patrón `#hasPerm` de `CLAUDE.md` §26) para UX, no como control de acceso real. |
| `skip_permission_check!` con comentario que justifique la excepción | N/A | — | No aplica: no existe el mecanismo en este repo. |

**Ambigüedad real:** si el enforcement de permisos vive genuinamente en el API externo (`ApiAppUrl`), este Rails app no necesita duplicarlo — sería redundante. Pero eso no está verificado desde este repo (el API externo no es parte del código auditado) ni documentado explícitamente en ningún archivo del proyecto. Se reporta como HIGH siguiendo la regla de no cerrar HIGH como N/A sin evidencia, y se deja como pregunta abierta para el equipo: *¿el API externo real hace este chequeo, o el proxy transparente está exponiendo endpoints sin ninguna verificación de permisos en ninguna capa?*

---

## 6. Licenciamiento de productos

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| `check_license` (JWT `license.jwt`) en el base controller | ❌ No cumple | **HIGH** | `grep -rn "check_license\|LicenseService\|LICENSE_" app config` → 0 resultados. No hay verificación de licencia general en ningún controller. |
| `requires_module` por controller, alineado con `menu.json` | ❌ No cumple | **HIGH** | `grep -rn "requires_module" app/controllers` → 0 resultados; no existe `config/menu.json` en este repo (el menú es vendor JS, `vendor/clavisco/menu`, consumido dinámicamente, no un archivo estático local). |

Misma ambigüedad que en §5: si el licenciamiento por módulo lo enforce el API externo, no hace falta duplicarlo aquí — pero no hay ninguna nota en el código que lo declare, por lo que se reporta como HIGH y no como excepción tácita.

---

## 7. Componentes frontend vendor

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| SweetAlert2 directo para notificaciones/confirmaciones, sin wrapper propio | ❌ No cumple | MEDIUM | El proyecto **no usa SweetAlert2 en absoluto** (`grep -rn "sweetalert2\|SweetAlert" app/javascript config` → 0 resultados). En su lugar reimplementó su propio sistema de toasts/modales en vanilla JS + Tailwind: [app/javascript/vendor/clavisco/alerts/index.js](app/javascript/vendor/clavisco/alerts/index.js). Es exactamente la capa que el estándar pide evitar ("sin wrapper propio, para no mantener una capa que la librería ya resuelve"). Nota positiva: la implementación propia sí escapa el contenido antes de insertarlo (`document.createTextNode` en `showToast`, [alerts/index.js:74-76](app/javascript/vendor/clavisco/alerts/index.js:74)), por lo que no introduce XSS. |
| Tabulator para tablas | ✅ Cumple | — | `vendor/clavisco/tabulator` presente y usado consistentemente en los controllers de listados. |
| Paneles laterales en vez de modales para formularios/detalle | ✅ Cumple | — | Confirmado el patrón en `CLAUDE.md` del proyecto (§8) y replicado en varios controllers (`connections_controller.js`, `company_form_controller.js`). |
| Design System (`cl_design_system` — `tokens.css`/`components.css`, clases `.cl-btn`, etc.) | ❌ No cumple | MEDIUM | `grep -rln "cl-btn\|cl-side-nav\|tokens.css\|components.css" app` → 0 resultados. El proyecto usa Tailwind CSS con clases utilitarias y colores hex hardcodeados directamente en JS (ver `CLAUDE.md` del proyecto §1, badges con `#e8f5ee`/`#3a7d52`, etc.) en vez de las clases del Design System compartido. |

---

## 8. Patrón de controller Stimulus

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| `disconnect()` limpia todo listener/timer registrado en `connect()` | ⚠️ Parcial | MEDIUM | 10 de 32 controllers Stimulus tienen `addEventListener` sin ningún método `disconnect()`: `branches_controller.js`, `companies_controller.js`, `company_form_controller.js`, `connections_controller.js`, `documents_emails_controller.js`, `documents_receptions_controller.js`, `email_senders_controller.js`, `mail_parser_controller.js`, `reception_logs_controller.js`, `users_register_controller.js`. La mayoría de esos listeners cuelgan de nodos hijos del propio elemento del controller (se liberan solos cuando Turbo remueve el subárbol), por lo que el riesgo real es bajo — **excepto el caso concreto de abajo**, que sí es un leak real. |
| Antipatrón — listener global sin remover | ✅ Corregido | ~~HIGH~~ | [documents_receptions_controller.js:491-519](app/javascript/controllers/documents_receptions_controller.js:491): se agregó `menu.addEventListener('click', () => close(null))` para que elegir cualquier opción también libere el listener de `document` (antes solo se liberaba al hacer clic fuera del menú). `close` ahora tolera `ev === null`. Verificado con `node --check`. |
| Antipatrón — `fetch` sin comprobar `response.ok` | No evaluado en esta corrida (fuera de alcance por volumen) | — | El patrón `#apiFetch` documentado en `CLAUDE.md` del proyecto (§6) sí valida `response.ok` de forma centralizada; no se auditó si todos los controllers lo usan exclusivamente. |
| Antipatrón — `innerHTML` con datos de API sin escapar (XSS) | ⚠️ Parcial | LOW | La mayoría de los formatters de Tabulator interpolan campos fijos (labels de un mapa interno), no texto libre de API, y `alerts/index.js` sí escapa. Un caso con interpolación directa de datos semi-controlados sin escapar: [documents_reception_create_controller.js:441](app/javascript/controllers/documents_reception_create_controller.js:441) — `data-udf-name="${udf.Name}"` dentro de un `innerHTML`, donde `udf.Name` viene de metadata de SAP (no user input directo, riesgo bajo pero técnicamente sin sanitizar). |

---

## 9. Stack técnico y testing

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Rails 8 + importmap (sin bundler JS) | ✅ Cumple | — | [Gemfile:15-17](Gemfile) — `importmap-rails`, sin webpack/vite/esbuild. |
| Solid stack (cache/queue/cable) en vez de Redis | ✅ Cumple | — | [Gemfile:24-27](Gemfile) — `solid_cache`, `solid_queue`, `solid_cable`. |
| Cobertura RSpec 100% | ⚠️ Corregido parcialmente | ~~HIGH~~ → MEDIUM | Se agregó `rspec-rails` + `webmock` y una primera suite en [spec/requests/](spec/requests/): `proxy_spec.rb` (enrutamiento por header API, reescritura de `/api/token`, filtrado de headers salientes/entrantes, timeout → 504, error de conexión → 502), `sessions_spec.rb`, `home_spec.rb`, `content_security_policy_spec.rb`. 13 examples, 0 failures. **No es cobertura 80-100%** (solo cubre `ProxyController` a fondo) — es la base para seguir agregando specs por controller; queda como MEDIUM hasta ampliar cobertura al resto de los ~23 controllers. |
| Ninguna librería de terceros servida desde CDN — se vendoriza | ✅ Corregido | ~~MEDIUM~~ | `ruby bin/importmap pin tabulator-tables@6.3.1` descargó el paquete a [vendor/javascript/tabulator-tables.js](vendor/javascript/tabulator-tables.js) (451KB) y actualizó el pin en [config/importmap.rb](config/importmap.rb) — ya no depende de `cdn.jsdelivr.net`. Confirmado sin referencias a `jsdelivr` en el HTML renderizado. |
| `brakeman` para análisis estático de seguridad | ✅ Cumple | — | [Gemfile:44](Gemfile) — `gem 'brakeman'` en el grupo `development, test`. |
| `bullet` para detección de N+1 | N/A | — | No aplica sin ORM de negocio (ver §1); tampoco está en el Gemfile, pero no hay N+1 posible en este código. |

---

## 10. Base de datos — esquema mínimo

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| `created_by`/`updated_by` (Auditable) e `is_active` (SoftDeletable) en toda tabla de negocio | N/A — mecanismo no aplica | — | No hay tablas de negocio locales; SQLite solo alberga las tablas de infraestructura de Solid Queue/Cache/Cable (`db/`). Toda la data de negocio vive en las APIs externas. |
| Sin funciones SQL específicas de SQLite | N/A | — | Sin queries de negocio que auditar. |

---

## 11. Variables de entorno de producción

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Prefijos por submodule (`OIDC_*`, `LICENSE_*`, `SENTRY_*`) | ⚠️ Parcial | — | Solo `SENTRY_DSN` sigue la convención (no hay `OIDC_*`/`LICENSE_*` porque esos submodules no están instalados, ver §2/§3/§6). Variables propias del proyecto (`API_FE_SYNC_URL`, `API_FE_APP_URL`, `API_CABYS_URL`) están bien documentadas en [.env.example](.env.example). |
| `.env` con secretos reales fuera de git | ✅ Cumple | — | `.gitignore:11,53-54` excluye `.env*`; confirmado que `.env` no está trackeado (`git ls-files | grep -x "\.env"` → vacío). |

---

## 12. Error tracking con Sentry

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| SDK backend (`sentry-ruby`/`sentry-rails`) configurado | ✅ Cumple | — | [Gemfile:39-40](Gemfile), [config/initializers/sentry.rb](config/initializers/sentry.rb). |
| Patrón `/tunnel` para el SDK de navegador (evita ad-blockers, no bloquea al usuario) | N/A — mecanismo no aplica | — | **No hay SDK de Sentry en el navegador en absoluto** (`grep -rln "sentry\|Sentry" app/views app/javascript` → 0 resultados). Solo se capturan errores del lado del servidor Rails; los 32 controllers Stimulus (fetch, manipulación de DOM, lógica de formularios) no reportan ningún error de JS a Sentry. No es un incumplimiento del patrón tunnel en sí (no hay mecanismo que evaluar), pero sí es un **gap real de observabilidad**: un error de JS en producción hoy es invisible para el equipo salvo que el usuario lo reporte. |
| `send_default_pii` + timeout corto en el reenvío server→Sentry | ⚠️ Parcial | LOW | [sentry.rb:4](config/initializers/sentry.rb:4) tiene `send_default_pii = true` sin el patrón tunnel que lo intermedie — para el SDK backend esto es normal (va servidor→Sentry directo, no hay ad-blocker de por medio), pero combinado con la ausencia total de captura frontend, todo el valor de Sentry en este producto hoy es exclusivamente backend. |

---

## Borradores de issue — hallazgos HIGH

> Repo destino: `Crisql/cl_cl_mlt_fec_app` (GitHub, privado). Formato listo para `gh issue create` o creación manual.

### Issue 1 — Sin suite de pruebas automatizadas (cobertura 0%)

> ✅ **Arrancado 2026-07-30**: rspec-rails + webmock instalados, 13 specs de request pasando
> (`ProxyController`, `SessionsController`, `HomeController`, CSP). Queda abierto el resto del
> alcance: ampliar cobertura a los ~19 controllers restantes y a los Stimulus controllers.

```
Título: Estandar Agregar suite de pruebas automatizadas RSpec

Cuerpo:
El proyecto no tiene carpeta test/ ni spec/, ni gemas de testing mas alla
de las que trae Rails por defecto. Cobertura actual: 0%.

Plataforma exige RSpec con cobertura 80%+ como minimo (100% es el objetivo
declarado). Sin suite de pruebas, cualquier refactor o cambio en
ProxyController, los 32 Stimulus controllers, o el manejo de sesion/token
no tiene red de seguridad.

Alcance sugerido para un primer corte:
- rspec-rails + configuracion base
- Specs de ProxyController (enrutamiento por header API, forwarding de
  headers, manejo de timeout/error)
- Specs de request para SessionsController y HomeController
- VCR/WebMock para las llamadas HTTP salientes del proxy

Evidencia: ausencia confirmada de test/, spec/, y gemas de testing en Gemfile.
```

### Issue 2 — Sin Content-Security-Policy configurada

> ✅ **Resuelto 2026-07-30** — ver `config/initializers/content_security_policy.rb`. Se deja el
> texto original del issue como referencia histórica del hallazgo.

```
Título: Bug Activar Content Security Policy en Rails

Cuerpo:
No existe config/initializers/content_security_policy.rb ni ninguna
configuracion de content_security_policy en el proyecto. Rails 8 trae el
soporte nativo listo para usar (config.content_security_policy en un
initializer) y hoy esta completamente ausente.

Sin CSP, el navegador no tiene ninguna restriccion adicional sobre que
scripts/estilos/conexiones puede ejecutar la pagina, lo que amplifica el
impacto de cualquier XSS futuro (mas relevante aun porque el token de
sesion vive en localStorage, ver issue relacionado).

Evidencia: grep -rn "content_security_policy" config app -> 0 resultados.
```

### Issue 3 — Token de sesion en localStorage en vez de session cookie

```
Título: Estandar Evaluar migracion de token de sesion a session cookie httpOnly

Cuerpo:
El estandar de plataforma marca como "no negociable" que los tokens nunca
vivan en localStorage del frontend, sino en la session cookie de Rails.
Este proyecto guarda el token de acceso en localStorage
(Storage.get('Session').access_token), documentado explicitamente en
application_controller.rb y sessions_controller.rb como una decision
deliberada para replicar el comportamiento del Angular legacy durante la
migracion.

Es una desviacion documentada, no un descuido, pero el riesgo que la regla
busca prevenir (robo de token via XSS, sin proteccion httpOnly) sigue
vigente. Se abre este issue para que el equipo decida explicitamente:
(a) aceptar la excepcion y documentarla formalmente en el codigo (comentario
    o ADR) como excepcion de arquitectura de migracion, o
(b) planificar la migracion a session cookie en una iteracion futura.

Evidencia: application_controller.rb:7, sessions_controller.rb:7-8.
```

### Issue 4 — Sin submodules de plataforma ni enforcement de permisos/licencia en este repo

```
Título: Estandar Documentar excepcion arquitectonica de submodules permisos y licenciamiento

Cuerpo:
Este repo no instala ningun submodule Ruby de plataforma (structures,
common, data_access, auth, licensing, app_menu, service_layer) y no tiene
ningun controller que llame require_permission!, requires_module, o
check_license. Toda esa logica (si existe) vive en las APIs externas
proxied (ApiAppUrl/ApiFEUrl), no en este Rails app.

El estandar permite desviaciones cuando el codigo depende de un sistema en
migracion, pero exige que quede declarado explicitamente en el codigo
(namespace o comentario) por que la regla no aplica. Hoy esa declaracion
no existe en ningun archivo del repo.

Accion pedida: agregar un comentario/README explicito (ej. en
ApplicationController o en un ARQUITECTURA.md) que documente que este
producto es "UI + Proxy" y que permisos/licencia/auditoria de datos se
verifican del lado del API externo, no aqui — y confirmar con el equipo que
efectivamente el API externo hace esa verificacion (no se pudo confirmar
desde este repo).

Evidencia: ausencia de .gitmodules, ausencia de require_permission!/
requires_module/check_license en app/controllers.
```

---

## Resumen ejecutivo

**Calidad de código.** El código en sí es limpio y consistente con las convenciones propias del proyecto (documentadas exhaustivamente en su `CLAUDE.md`): badges estandarizados, tooltips accesibles, manejo de errores de API con `cl-message`, paneles laterales sobre modales, formato de fechas uniforme. El hallazgo real más concreto de esta capa — un listener de `document` que quedaba huérfano en el menú de acciones de `documents_receptions_controller.js` — **ya se corrigió** (2026-07-30).

**Estándares técnicos.** Los cuatro hallazgos mecánicos de esta capa **ya se corrigieron** (2026-07-30): CSP activa con nonce por request, Tabulator vendorizado localmente, y una primera suite RSpec (13 specs, `ProxyController` a fondo + smoke tests). La suite es una base, no cobertura 80-100% — falta extenderla a los ~19 controllers restantes. Sigue sin resolverse la reimplementación propia de SweetAlert2/Design System en vez de las piezas compartidas (§7), que no es un fix mecánico: implica reescribir el sistema de alerts/badges de toda la app.

**Discrepancias documentación-vs-código (arquitectura).** El hallazgo estructural más importante de esta corrida es que este repo es, por diseño, un producto "UI + Proxy" sin lógica de negocio propia — lo cual explica de forma coherente por qué no tiene submodules de plataforma, modelos de negocio, ni chequeos de permiso/licencia server-side: esa responsabilidad vive en las APIs externas que consume. Esa arquitectura tiene sentido para un proyecto de migración de UI, pero **hoy no está declarada explícitamente en ningún archivo del repo**, y el estándar exige justamente esa declaración por escrito para que una desviación cuente como deliberada y no como un vacío sin dueño. Lo mismo aplica al token en `localStorage`: es una decisión consciente para replicar el Angular legado durante la migración, pero el propio estándar la marca "no negociable" — por lo que amerita una conversación explícita del equipo, no un silencio. Ninguno de estos dos puntos se cierra como N/A en este reporte a propósito: son reales, y quedan para que el equipo decida cómo documentarlos o resolverlos.

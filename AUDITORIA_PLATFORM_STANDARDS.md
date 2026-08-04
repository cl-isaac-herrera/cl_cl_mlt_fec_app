# Auditoría de cumplimiento — CLAVISCO-PLATFORM-STANDARDS.md

**Proyecto:** `cl_cl_mlt_fec_app`
**Tipo de producto detectado:** UI — evidencia: `app/views/` con vistas ERB completas, `config/importmap.rb`, 32 controllers Stimulus bajo `app/javascript/controllers/`, Tailwind CSS v4 (`tailwindcss-rails 4.4.0`). Sin evidencia de integración SAP directa (no existe `vendor/clavisco/service_layer` ni `vendor/clavisco/sap_udfs`, no hay variables `SAP_SL_URL`/`SAP_COMPANY_DB`) → las secciones marcadas **[solo SAP]** se marcan N/A. El proyecto expone rutas `/api/*`, pero como **proxy HTTP transparente** (`ProxyController`, ver Sección 4) hacia dos backends externos (`ApiAppUrl`/`ApiFEUrl`) — no existe **ningún** controller `Api::*` propio. Las reglas **[API + UI]** se evalúan igual (aplican a todo producto por definición del documento), y esa ausencia total del patrón de API es en sí misma el hallazgo central de la Sección 4.5.
**Fecha:** 2026-08-03
**Estándar auditado:** [CLAVISCO-PLATFORM-STANDARDS.md](https://github.com/ClavisCo/platform-standards/blob/main/CLAVISCO-PLATFORM-STANDARDS.md) (traído directo de GitHub en esta corrida — commit `4e4563b`)

## Leyenda
Estado: ✅ Cumple · ⚠️ Cumple parcialmente · ❌ No cumple · N/A (no aplica a este tipo de producto)
Severidad (solo en ⚠️/❌): 🔴 HIGH · 🟠 MEDIUM · 🟡 LOW

> **Nota sobre N/A y mecanismos ausentes.** Varias reglas de este documento asumen la existencia de piezas que este producto no tiene en absoluto (modelos de negocio, controllers `Api::*`, submodules Ruby de plataforma). Siguiendo el propio criterio del documento en la Sección 4.5 ("queda completamente fuera del radar... no porque los incumpla, sino porque el mecanismo ni siquiera está presente"), estos casos **no se cierran como N/A silencioso** ni se evalúan regla por regla sin sentido — se reportan como su propio hallazgo en el nivel donde corresponde (Sección 2, principalmente), y las reglas hijas que dependen de ese mecanismo ausente se marcan N/A con la evidencia de *por qué* no hay nada que evaluar, nunca para descartar un incumplimiento real.

---

## Sección 1 — Calidad de código

### 1.1 Buenas prácticas

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Fat models / skinny controllers | N/A | — | No existe ningún modelo de negocio (`app/models/` solo tiene `application_record.rb`). Nada que evaluar; ver hallazgo central en Sección 2. |
| Strong Parameters (nunca `params.permit!`) | N/A | — | `grep -rn "permit!" app` → 0 resultados. `ProxyController#forward` reenvía `request.raw_post` crudo sin parsear params localmente ([proxy_controller.rb:58](app/controllers/proxy_controller.rb#L58)) — no hay superficie de Strong Parameters que auditar. |
| Callbacks con moderación | ✅ Cumple | — | `ApplicationController` no declara `before_action`/`after_action` que oculten lógica; los controllers de página son triviales (`layout 'protected'` + acción vacía). |
| Sin N+1 queries | N/A | — | Sin ORM de negocio, no hay queries que puedan tener N+1. |
| Specs descriptivas (`it "returns X when Y"`) | ✅ Cumple | — | Los 13 specs en `spec/requests/` leen como oración: `it 'con header API: ApiFEUrl y path /api/token, lo reescribe a /token (sin prefijo /api)'`. |
| **JS/Stimulus — sin código muerto** | ⚠️ Cumple parcialmente | 🟡 LOW | 2 `console.log` de debug en [documents_receptions_controller.js](app/javascript/controllers/documents_receptions_controller.js) (`grep -rn "console\.log(" app/javascript/controllers` → 2, ambos en ese archivo). El resto del código no muestra funciones comentadas ni variables sin usar en el muestreo realizado. |
| **JS/Stimulus — manejo de errores consistente** (`try/catch` + `showToast`, `showOverlay/hideOverlay` en `finally`) | ⚠️ Cumple parcialmente | 🟠 MEDIUM | El patrón `try/finally` con overlay sí se sigue (documentado y replicado en `CLAUDE.md` del proyecto, tipos A-D de loader). Pero **no usa `showToast`/SweetAlert2 de la Sección 5.1** — usa un sistema de toasts propio (`vendor/clavisco/alerts`). Ver hallazgo detallado en Sección 5.1/6.4. |
| **JS/Stimulus — targets verificados antes de usar** (`if (!this.hasXTarget) return`) | ✅ Cumple | — | Patrón presente y usado consistentemente en el muestreo (ej. [documents_issued_controller.js:94](app/javascript/controllers/documents_issued_controller.js#L94), `this.hasBtnBulkDownloadTarget`). |
| **JS/Stimulus — eventos DOM limpiados en `disconnect()`** | ❌ No cumple | 🟠 MEDIUM | 10 de 32 controllers registran `addEventListener` sin ningún método `disconnect()`: `branches`, `companies`, `company_form`, `connections`, `documents_emails`, `documents_receptions`, `email_senders`, `mail_parser`, `reception_logs`, `users_register`. El documento es explícito: *"Se marca como incumplimiento cualquier registro sin su limpieza correspondiente, exista o no el método `disconnect()`"* (Sección 6.3) — detalle completo en Sección 6.3 más abajo. |

### 1.2 Principios SOLID

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| **S** — un método, una responsabilidad (métodos >50 líneas se dividen) | ⚠️ Cumple parcialmente | 🟡 LOW | No se hizo un barrido método-por-método de las ~13,000 líneas de JS del proyecto en esta corrida (fuera de alcance práctico); a nivel de archivo, `company_form_controller.js` y `documents_reception_create_controller.js` superan las 700-1000 líneas mezclando validación, render y fetch — señal a revisar, no una violación puntual confirmada método por método. |
| **O** — no modificar submodules internamente | N/A | — | No hay submodules Ruby instalados (Sección 2) — nada que proteger de modificación. |
| **D** — depender de abstracciones compartidas (`getAPIHeaders`, `showToast`, `showOverlay`) | ⚠️ Cumple parcialmente | 🟡 LOW | `showOverlay`/`hideOverlay` sí son compartidos. `showToast` **no es el de la Sección 5.1** (SweetAlert2) — es una reimplementación propia. `getAPIHeaders` tampoco existe con ese nombre; el proyecto usa su propio `#apiFetch` por controller (documentado en `CLAUDE.md` del proyecto, un patrón a copiar manualmente en cada controller, no un import compartido único). |
| Backend — S/O/I/D | N/A | — | Sin controllers `Api::*` ni servicios de negocio, no hay nada que evaluar bajo estos principios backend. |

### 1.3 Simplicidad y 1.4 Legibilidad

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Guard clauses en vez de `if` anidados | ✅ Cumple | — | Confirmado en el muestreo (`return unless`, `if (!this.hasXTarget) return`) — patrón consistente con el ejemplo del propio documento. |
| Nombres que explican intención | ✅ Cumple | — | Nombres de métodos y variables descriptivos en el código revisado (`#handleRowAction`, `#fetchPage`, `#totalRecords`). |
| Sin sobre-ingeniería | ✅ Cumple | — | No se observaron abstracciones innecesarias; el proyecto es directo para su alcance (proxy + vistas). |

### 1.5 Seguridad — checklist obligatorio

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Cerrar sesión con `reset_session` | N/A | — | No hay sesión de Rails (`session[...]`) en absoluto — la autenticación es 100% client-side vía `localStorage`. `grep -rln "reset_session" app` → 0. Ver el hallazgo real relacionado (token en `localStorage`) abajo. |
| OIDC — `state`/`nonce` | N/A | — | No hay integración OIDC en este repo; el login delega 100% en el `/token` del API externo. |
| OIDC — validar firma del `id_token` | N/A | — | Mismo motivo — sin flujo OIDC que auditar. |
| **CSP habilitada y ajustada a los recursos reales** | ✅ Cumple | — | [config/initializers/content_security_policy.rb](config/initializers/content_security_policy.rb) — `script-src 'self'` con nonce por request, resto de directivas ajustadas a los recursos reales (Google Fonts, mismo origen). Corregido en esta misma sesión de trabajo. |
| **Sin credenciales por defecto en `ENV.fetch`** | ❌ No cumple | 🟠 MEDIUM | [config/initializers/sentry.rb:2](config/initializers/sentry.rb#L2) — `ENV.fetch('SENTRY_DSN', 'https://86ce...ingest.us.sentry.io/...')` hardcodea un DSN real como fallback. El documento es textual: *"Si la variable falta, debe fallar explícitamente, nunca caer en un secreto de repuesto."* |
| Sanitizar `LIKE` con `sanitize_sql_like` | N/A | — | `grep -rn "LIKE\|sanitize_sql_like" app/controllers app/models` → 0 resultados; no existe ninguna query SQL con wildcard en el código (consistente con la ausencia total de modelos de negocio). |
| Logs sin secretos | ✅ Cumple | — | [proxy_controller.rb:153](app/controllers/proxy_controller.rb#L153) — `Rails.logger.info "[Proxy] Headers: #{headers.except('Authorization').inspect}"` excluye explícitamente el header `Authorization` del log. |
| Errores genéricos al cliente | ⚠️ Cumple parcialmente | 🟡 LOW | [proxy_controller.rb:83-86](app/controllers/proxy_controller.rb#L83) devuelve `"API request failed: #{e.message}"` al cliente en errores de conexión — no expone stacktrace, pero sí el mensaje crudo de la excepción Ruby (puede incluir host/puerto internos en fallos de red). |
| Revalidar usuario activo en cada request | N/A | — | Sin sesión de servidor ni modelo `User`, no hay mecanismo de "usuario activo" que revalidar en este repo — la responsabilidad completa recae en el API externo. |
| Administración de permisos protegida | N/A | — | No existe ningún endpoint de administración de permisos/roles en este repo (no hay modelos `roles`/`permissions`). |

### 1.6 Rendimiento — checklist obligatorio

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| No precargar de más | ✅ Cumple | — | Los paneles/tablas usan carga diferida (`fetchData`) en el muestreo revisado; no se detectaron precargas costosas de más. |
| N+1 queries / gema `bullet` | N/A | — | Sin ORM de negocio. `bullet` tampoco está en el `Gemfile`, consistente con que no hace falta. |
| Filtrar en SQL, no en Ruby | N/A | — | Sin queries de negocio que filtrar. |
| Índices en `company_id`/`user_id` | N/A | — | Sin tablas de negocio (Sección 8). |
| Debounce en buscadores | ✅ Cumple | — | Implementado en los componentes vendor genéricos: [search-modal](app/javascript/vendor/clavisco/search-modal/controllers/search_modal_controller.js), [slide-search](app/javascript/vendor/clavisco/slide-search/controllers/slide_search_controller.js). |
| N escrituras en loop (`upsert_all`/`insert_all`) | N/A | — | Sin modelos de negocio, no hay escrituras en loop que auditar. |

---

## Sección 2 — Submodules Ruby obligatorios

**❌ HALLAZGO CENTRAL — HIGH.** Ninguno de los 8 submodules Ruby de plataforma está instalado. No existe `.gitmodules`, no existe ninguna carpeta bajo un `vendor/` a nivel Ruby (solo existe `app/javascript/vendor/clavisco/*`, que es JS, un concepto distinto), y no existe `config/initializers/clavisco_submodules.rb`. Esto no es una desviación puntual — es la ausencia total de la capa que el documento asume como base de todo producto Rails Clavisco.

El documento permite desviaciones cuando el código depende de verdad de un sistema legado, **pero exige que la excepción esté declarada explícitamente en el código** (un namespace `Api::Legacy` o un comentario claro). Esa declaración **no existe en ningún archivo de este repo** — ni un comentario, ni un README, ni un namespace que diga "este producto es solo UI+proxy, por eso no adopta los submodules de plataforma". Por regla textual del propio documento (*"Sin declaración explícita... la desviación se marca como incumplimiento normal"*), se reporta como ❌ No cumple, HIGH, y no como N/A.

| Submodule | Estado | Severidad | Evidencia |
|---|---|---|---|
| 2.1 `structures` (`ApiResponse`) | ❌ No cumple | 🔴 HIGH | No instalado. `ProxyController` reenvía `response.body` crudo del backend externo ([proxy_controller.rb:77](app/controllers/proxy_controller.rb#L77)) — nunca emite el contrato `{ Data:, Code:, Message: }` porque no lo necesita para su función (es un pass-through), pero tampoco existe la gema en absoluto para el resto del producto. |
| 2.2 `data_access` (`Auditable`/`SoftDeletable`/`CompanyScoped`) | ❌ No cumple | 🔴 HIGH | No instalado. No aplica de forma directa por ausencia total de modelos, pero la ausencia del submodule en sí es el hallazgo. |
| 2.3 `auth` (OIDC + dual auth) | ❌ No cumple | 🔴 HIGH | No instalado. Ver hallazgo detallado abajo (token en `localStorage`). |
| 2.4 `common` (middleware `ErrorHandler`/`RequestLogger`) | ❌ No cumple | 🔴 HIGH | No instalado. `grep -rn "ErrorHandler\|RequestLogger" config` → 0. Sin captura centralizada de excepciones en `/api/*` ni reporte automático a Sentry desde el middleware. |
| 2.5 `licensing` | ❌ No cumple | 🔴 HIGH | No instalado. Ver detalle en Sección 4.5. |
| 2.6 `app_menu` | ⚠️ Cumple parcialmente | 🟠 MEDIUM | El submodule Ruby no está instalado, pero el **concepto** de menú enriquecido existe del lado JS (`vendor/clavisco/menu`, `app/javascript/data/menu.js`, movido ahí por incompatibilidad de importmap con imports JSON — comentario explícito en el propio archivo). El menú no declara el campo `Module` por ítem (`grep -n '"Module"' app/javascript/data/menu.js` → 0), consistente con que tampoco hay licenciamiento por módulo que enriquecer. |
| 2.7 `service_layer` [solo SAP] | N/A | — | Producto sin integración SAP directa. |
| 2.8 `sap_udfs` [solo SAP] | N/A | — | Idem. |

### Hallazgo relacionado — Token de sesión en `localStorage`, no en session cookie (Sección 2.3)

❌ **No cumple — HIGH.** El documento es "no negociable" en esto: *"Los tokens NO se almacenan en localStorage del frontend. Viven en la session cookie Rails."* Este proyecto hace exactamente lo contrario, y lo documenta como decisión deliberada: [application_controller.rb:7](app/controllers/application_controller.rb#L7) — *"La autenticación es 100% client-side (token en localStorage)"*, repetido en [sessions_controller.rb:7-8](app/controllers/sessions_controller.rb#L7).

Es una desviación **documentada** (replica el comportamiento del Angular legado durante la migración), pero no está declarada como excepción formal en el sentido que exige la introducción del documento (namespace/comentario que justifique la excepción como tal, no solo que describa qué hace el código). El riesgo que la regla busca prevenir — robo de token vía XSS, sin protección `httpOnly` — sigue vigente. Se reporta como HIGH y no se cierra como N/A.

---

## Sección 3 — Cómo cargar los submodules en Rails

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| `config/initializers/clavisco_submodules.rb` | ❌ No cumple | 🔴 HIGH | No existe. Consecuencia directa de la Sección 2. |
| `app/models/current.rb` con `ActiveSupport::CurrentAttributes` | ❌ No cumple | 🟠 MEDIUM | No existe (`cat app/models/current.rb` → No such file). El contexto de request (empresa activa, etc.) se maneja hoy vía JS (`SStore`, `Storage`) en vez de `Current` en el servidor — consistente con que tampoco hay sesión de servidor que darle contexto. |

---

## Sección 4 — Sistema de permisos

### 4.1-4.4

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Tablas obligatorias (`users`, `companies`, `roles`, `permissions`, `role_permissions`, `user_roles`) | ❌ No cumple | 🔴 HIGH | `db/schema.rb` está vacío (`ActiveRecord::Schema[8.1].define(version: 0) do end`) — cero tablas, ni siquiera `db/migrate/` existe. Ver detalle completo en Sección 8. |
| Verificación en API controllers (`require_permission!`) | ❌ No cumple | 🔴 HIGH | No aplica un veredicto de "cumple parcialmente" — no existe ningún controller `Api::*`, ni `AuthorizedController`, ni `require_permission!`/`skip_permission_check!` en todo el repo (`grep -rn "require_permission!\|skip_permission_check!" app/controllers` → 0). |
| Verificación en view controllers (`require_view_permission!`) | ❌ No cumple | 🔴 HIGH | 0 resultados para `require_view_permission!` en todo `app/controllers`. Ningún controller de vista verifica permisos — coherente con que la app delega esa verificación al API externo, pero sin ninguna declaración que lo confirme desde este repo. |
| Convención de nombres `{Módulo}_{Recurso}_{Acción}` | N/A | — | No hay ningún permiso declarado en este repo que nombrar. |

### 4.5 Auditoría: permisos y licenciamiento en conjunto

Esta es la sección donde el documento pide explícitamente ir más allá del safety net y verificar puntualmente. Resultado de cada verificación puntual pedida:

- **Herencia de `Api::BaseController`/`Api::AuthorizedController`:** ❌ **No cumple — HIGH.** `grep -rn "class \w+Controller < (Api::BaseController|Api::AuthorizedController)" app/controllers` → 0 resultados, porque **no existe ningún controller bajo un namespace `Api::`** en este repo. El único punto de entrada a `/api/*` es `ProxyController < ApplicationController` — fuera de la cadena de herencia que el documento asume como punto de partida de todo lo demás en esta sección. El documento es explícito sobre esto: *"queda completamente fuera del radar de todos los puntos siguientes"* — es exactamente ese caso.
- **`skip_permission_check!` con comentario:** N/A — el mecanismo no existe en este repo.
- **Nombre de `require_permission!` sigue la convención:** N/A — mismo motivo.
- **`requires_module` alineado con `menu.json`:** ❌ **No cumple — HIGH.** Ningún controller declara `requires_module` (no existe el concern `Licensable`). Coherente con que `menu.js` tampoco declara `Module` por ítem — pero, siguiendo el propio criterio del documento (*"sin declaración ni comentario, se marca como hallazgo"*), la ausencia total no se excusa por consistencia interna.

---

## Sección 5 — Componentes frontend vendor

### 5.1 Servicios singleton

| Módulo | Estado | Evidencia |
|---|---|---|
| `core` | ✅ Cumple | [vendor/clavisco/core/index.js](app/javascript/vendor/clavisco/core/index.js) exporta `Storage`, `downloadBase64File`, `isValidEmail`, `CL_ACTIONS` — coincide con el contrato exacto. |
| `overlay` | ✅ Cumple | [vendor/clavisco/overlay/index.js](app/javascript/vendor/clavisco/overlay/index.js) exporta `open(modalId)`, `close(modalId)`. |
| `linker` | ✅ Cumple | Presente en `vendor/clavisco/linker`. |
| `login` | ✅ Cumple | [vendor/clavisco/login/index.js](app/javascript/vendor/clavisco/login/index.js) expone `login()`, `logout()`, `hasPermission(code)`. |
| `menu` | ✅ Cumple | Presente en `vendor/clavisco/menu`. |

**Regla — SweetAlert2 directo, sin wrapper propio:** ❌ **No cumple — MEDIUM.** `grep -rn "sweetalert2\|SweetAlert\|Swal\." app/javascript config` → 0 resultados. El proyecto **no usa SweetAlert2 en absoluto**; reimplementó su propio sistema de toasts/confirmaciones en vanilla JS + Tailwind ([vendor/clavisco/alerts/index.js](app/javascript/vendor/clavisco/alerts/index.js)) — exactamente la capa que el documento pide evitar (*"decisión consciente: no se mantiene un `alertService`/`showToast` propio"*). Nota positiva: la implementación propia sí escapa el contenido antes de insertarlo (`document.createTextNode` en `showToast`), por lo que no introduce XSS por su cuenta.

**Regla — `Turbo.config.forms.confirm` enganchado a SweetAlert2:** N/A — no aplica mientras no se adopte SweetAlert2 (ver arriba); no se encontró configuración de `Turbo.config.forms.confirm` en absoluto.

### 5.2 Controladores Stimulus vendor — coherencia

| Componente | Estado | Evidencia |
|---|---|---|
| `overlay` (base, todo producto) | ✅ Cumple | Presente y usado (Tipo A/B de loader en `CLAUDE.md` del proyecto). |
| `table` + `tabulator` (el producto tiene tablas) | ✅ Cumple | Presente, usado consistentemente. |
| `base` (paneles laterales) | ✅ Cumple | Presente, usado en `connections_controller.js` y otros. |
| `slide-search` | ✅ Cumple | Presente donde aplica. |
| `skeleton` | ✅ Cumple | Presente en el vendor. |

### 5.3 Paneles laterales sobre modales

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Sin modales custom (`<dialog>`, div con z-index fijo simulando modal) | ⚠️ Cumple parcialmente | 🟡 LOW | Los flujos de creación/edición usan panel lateral (`base`) consistentemente. Las **confirmaciones** y **notificaciones**, sin embargo, no usan `Swal.fire` (Sección 5.1) sino un modal/toast propio — no es un "modal custom" en el sentido de la Sección 5.3 (no reemplaza un panel lateral), pero es la misma raíz del hallazgo de 5.1. |

### 5.4 Paginación server-side

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Todo listado de solo lectura pagina en servidor por default | ✅ Cumple | — | Confirmado `ajaxRequestFunc`/`fetchData` en los controllers de listados revisados (`documents_issued_controller.js`, `connections_controller.js`, etc.), sin `data: [...]` local salvo casos declarados. |
| Contrato de headers `cl-sl-pagination-*` | ✅ Cumple (con extensión declarada) | — | `documents_create_controller.js` usa `cl-sl-pagination-page/page-size/records-count` — coincide exacto. `connections_controller.js` usa en cambio `cl-dba-pagination-*` ([connections_controller.js:161-171](app/javascript/controllers/connections_controller.js#L161)) — un header distinto para un backend distinto (acceso directo a BD, no Service Layer SAP), y `ProxyController` ya reenvía ambas familias de forma explícita ([proxy_controller.rb:70](app/controllers/proxy_controller.rb#L70)). Es una extensión coherente del contrato, no una desviación silenciosa. |
| `ajaxURL` es una URL válida, no un string arbitrario | ✅ Cumple | — | Confirmado en el muestreo (`ajaxURL: '/api/...'`, rutas reales). |

---

## Sección 6 — Patrón de controller Stimulus

### 6.1 Tipos de mensaje / 6.2 Indicadores de carga

| Regla | Estado | Severidad | Evidencia |
|---|---|---|---|
| Un solo componente de notificación (toast SweetAlert2) en toda la app | ❌ No cumple | 🟠 MEDIUM | Ya reportado en 5.1: el "único componente" existe (`vendor/clavisco/alerts`), pero no es SweetAlert2. La consistencia interna del proyecto es alta (todo pasa por ese único sistema propio), pero no es el que exige el documento. |
| Overlay enganchado a eventos de ciclo de vida de Turbo (`turbo:before-fetch-request/response`) | ⚠️ Cumple parcialmente | 🟡 LOW | No se verificó de forma exhaustiva en los 32 controllers; el patrón documentado en `CLAUDE.md` del proyecto es manual (`showOverlay()`/`hideOverlay()` explícito por fetch), no un enganche global a los eventos de Turbo. Señal a confirmar, no una violación cerrada. |

### 6.3 Limpieza de recursos en `disconnect()`

❌ **No cumple — MEDIUM.** El documento es estricto: *"Se marca como incumplimiento cualquier registro sin su limpieza correspondiente, exista o no el método `disconnect()`."* 10 de 32 controllers registran `addEventListener` sin ningún `disconnect()`: `branches_controller.js`, `companies_controller.js`, `company_form_controller.js`, `connections_controller.js`, `documents_emails_controller.js`, `documents_receptions_controller.js`, `email_senders_controller.js`, `mail_parser_controller.js`, `reception_logs_controller.js`, `users_register_controller.js`.

De estos, la mayoría registra listeners sobre nodos hijos del propio elemento del controller (se liberan al remover el subárbol vía Turbo — riesgo real bajo), con una excepción real ya corregida en esta sesión de trabajo: [documents_receptions_controller.js:491](app/javascript/controllers/documents_receptions_controller.js#L491) registraba un listener en `document` que quedaba huérfano si el usuario elegía una opción del menú sin cerrar haciendo clic afuera — corregido para que ambos caminos liberen el listener. El hallazgo de fondo (10 controllers sin `disconnect()` como método) sigue abierto como deuda del resto del código.

### 6.4 Antipatrones conocidos — búsqueda puntual

| Antipatrón | Encontrado | Severidad | Evidencia |
|---|---|---|---|
| `document.dispatchEvent(new CustomEvent("toast"...` en vez de SweetAlert2 | ❌ Sí | 🟠 MEDIUM | 3 archivos: [payment-slide](app/javascript/vendor/clavisco/payment-slide/controllers/payment_slide_controller.js), [stock-warehouse-slide](app/javascript/vendor/clavisco/stock-warehouse-slide/controllers/stock_warehouse_slide_controller.js), [tabulator_controller.js:496](app/javascript/vendor/clavisco/tabulator/controllers/tabulator_controller.js#L496) (`document.dispatchEvent(new CustomEvent("toast", ...))` dentro de un método `showToast`). Coincide textualmente con el primer antipatrón listado en el documento. |
| `alert()`/`confirm()` nativos | ✅ No encontrado | — | `grep -rn "window\.confirm(\|window\.alert(\|window\.prompt(" app/javascript/controllers` → 0. |
| `addEventListener`/timers sin `disconnect()` | ❌ Sí | 🟠 MEDIUM | Ver 6.3 arriba. |
| `innerHTML =`/`+=` con datos de API sin escapar (XSS) | ⚠️ Parcial | 🟡 LOW | La mayoría de los formatters de Tabulator interpolan campos de un mapa interno fijo (badges), no texto libre de API. Un caso con interpolación semi-directa sin escapar: [documents_reception_create_controller.js:441](app/javascript/controllers/documents_reception_create_controller.js#L441) — `data-udf-name="${udf.Name}"` dentro de un `innerHTML`, donde `udf.Name` viene de metadata de SAP (riesgo bajo, no user input directo, pero técnicamente sin sanitizar). |
| `this.xTarget` sin declarar en `static targets` | ✅ No verificado con evidencia sólida | — | Requeriría cruzar cada `Target` usado contra `static targets` en los 32 controllers — fuera de alcance práctico de esta corrida; no se reporta sin evidencia concreta. |
| Mismo método definido dos veces en un archivo | ✅ No verificado con evidencia sólida | — | Un grep heurístico dio falsos positivos (coincide con *llamadas* repetidas, no con *definiciones* duplicadas) — se descarta como hallazgo sin evidencia confiable. |
| `URL.createObjectURL()` sin `URL.revokeObjectURL()` | ❌ Sí | 🟡 LOW | 3 archivos sin `revokeObjectURL` en el mismo archivo: [vendor/clavisco/core/index.js](app/javascript/vendor/clavisco/core/index.js), [vendor/clavisco/rptmng-menu/index.js](app/javascript/vendor/clavisco/rptmng-menu/index.js), [vendor/clavisco/table/controllers/table_controller.js](app/javascript/vendor/clavisco/table/controllers/table_controller.js). Riesgo de fuga de memoria en descargas/vistas previas repetidas. |
| `"/api"` hardcodeado en vez del `Value` configurable | ⚠️ Parcial | 🟡 LOW | 19 ocurrencias de rutas `'/api/...'` literales fuera del patrón `apiUrlValue`/`#apiFetch` en el muestreo (`grep -c`) — no se verificó cada una individualmente contra si el controller ya tiene un `Value` declarado para esa base; señal a revisar, no un conteo de violaciones confirmadas una por una. |
| `fetch()` cuya respuesta se usa sin comprobar `response.ok` | ✅ No verificado con evidencia sólida | — | 30 archivos llaman `await fetch(`; el patrón centralizado `#apiFetch` documentado en `CLAUDE.md` del proyecto sí valida `response.ok`, pero no se confirmó que las 30 llamadas pasen exclusivamente por ese patrón — no se reporta como violación sin verificar cada sitio. |
| Misma librería externa reimplementada de forma independiente en varios controllers | ✅ No encontrado | — | No se detectó una librería externa (ej. exportar a Excel, mapas) importada y reimplementada por separado en múltiples controllers en el muestreo. |
| Identificador usado sin `import` correspondiente | ✅ No verificado con evidencia sólida | — | Requeriría un linter real (ESLint) corriendo sobre las 32 controllers; no se ejecutó en esta corrida. |

---

## Sección 7 — Stack técnico obligatorio

### 7.1 Backend

| Gem | Requerido | Presente | Estado | Severidad |
|---|---|---|---|---|
| `rails` | `~> 8.1` | `~> 8.0` ([Gemfile:7](Gemfile#L7)) | ⚠️ Cumple parcialmente | 🟡 LOW |
| `importmap-rails` | latest | ✅ presente | ✅ Cumple | — |
| `turbo-rails` | latest | ✅ presente | ✅ Cumple | — |
| `stimulus-rails` | latest | ✅ presente | ✅ Cumple | — |
| `tailwindcss-rails` | latest | ✅ presente (4.4.0) | ✅ Cumple | — |
| `httparty` | latest | ❌ ausente | ❌ No cumple | 🟡 LOW |
| `jwt` | latest | ❌ ausente | ❌ No cumple | 🟡 LOW |
| `openid_connect` | `~> 2.5` | ❌ ausente | ❌ No cumple | 🟡 LOW |
| `sentry-ruby` + `sentry-rails` | latest | ✅ presente | ✅ Cumple | — |
| `solid_cache` + `solid_queue` | latest | ✅ presente (+ `solid_cable`, extra) | ✅ Cumple | — |
| `sqlite3` | `~> 2.0` | `>= 2.1` ([Gemfile:23](Gemfile#L23)) | ✅ Cumple | — |
| `rspec-rails` | dev/test | ✅ presente (agregado en esta sesión) | ✅ Cumple | — |
| `factory_bot_rails` | dev/test | ❌ ausente | ❌ No cumple | 🟡 LOW |
| `webmock` | dev/test | ✅ presente (agregado en esta sesión) | ✅ Cumple | — |
| `brakeman` | dev | ✅ presente | ✅ Cumple | — |

Las gemas ausentes (`httparty`, `jwt`, `openid_connect`, `factory_bot_rails`) son consistentes con la ausencia total de los submodules `auth`/`licensing` (Sección 2) — no es un olvido puntual de instalar una gema, es la misma causa raíz. Se listan como LOW individualmente porque instalar la gema sin la arquitectura que la usa no resolvería nada por sí solo; el hallazgo real y de mayor severidad ya está en la Sección 2.

**Gema extra no listada en el estándar:** `faraday` ([Gemfile:31](Gemfile#L31)) está declarada pero **sin ningún uso en el código** (`grep -rln "Faraday" app/` → 0 resultados) — `ProxyController` usa `Net::HTTP` directo, no Faraday. Dependencia muerta.

### 7.2 Frontend

| Librería | Requerido | Estado | Severidad | Evidencia |
|---|---|---|---|---|
| `@hotwired/stimulus` / `turbo-rails` | importmap | ✅ Cumple | — | Confirmado en `config/importmap.rb`. |
| `tabulator-tables` | importmap, vendorizado `--download`, `6.3.1` | ✅ Cumple | — | Vendorizado en esta sesión de trabajo (`vendor/javascript/tabulator-tables.js`, versión 6.3.1 exacta). Antes se servía desde `cdn.jsdelivr.net` — corregido. |
| Tailwind CSS v4 | CSS pipeline | ✅ Cumple | — | `tailwindcss-rails 4.4.0` / `tailwindcss-ruby ~> 4.0`. |
| Material Icons | auto-hospedado | ❌ No cumple | 🟠 MEDIUM | [application.html.erb:12](app/views/layouts/application.html.erb#L12) y [protected.html.erb:41](app/views/layouts/protected.html.erb#L41) cargan `<link href="https://fonts.googleapis.com/icon?family=Material+Icons" rel="stylesheet">` — **no está auto-hospedado**, depende de Google Fonts en cada carga de página. Es, además, la razón por la que la CSP nueva tuvo que abrir `style-src`/`font-src` a `fonts.googleapis.com`/`fonts.gstatic.com` — descargarlo y servirlo desde el propio dominio permitiría cerrar esa excepción también. |

**Regla de auditoría — CDN es alerta, no bloqueo automático.** Consistente con esa regla, el hallazgo de Material Icons se marca como alerta (MEDIUM) para que el equipo decida corregirlo o justificarlo — no bloquea por sí solo.

### 7.3 Herramientas de testing

| Herramienta | Estado | Severidad | Evidencia |
|---|---|---|---|
| RSpec + FactoryBot | ⚠️ Cumple parcialmente | 🟠 MEDIUM | RSpec sí (agregado en esta sesión). FactoryBot no está instalado — no hay factories porque no hay modelos que factorizar; consistente con la Sección 2/8. |
| **Cobertura RSpec 100%** | ❌ No cumple | 🔴 HIGH | 13 specs, todos sobre `ProxyController` + smoke tests de 2 páginas + CSP. **Cero cobertura** en los ~19 controllers de `app/controllers` restantes (namespaces `configurations/*`, `documents/*`) y en los 32 controllers Stimulus. El documento es explícito: *"Un push con cobertura menor es bloqueante."* |
| Vitest `^4.0` (Stimulus controllers) | ❌ No cumple | 🟠 MEDIUM | No instalado — `grep -rn "vitest" package.json` → sin `package.json` con dependencias JS de testing en absoluto. Los 32 controllers Stimulus no tienen ninguna prueba automatizada. |
| Playwright `^1.57` (E2E) | ❌ No cumple | 🟠 MEDIUM | No instalado. Sin pruebas E2E. |

---

## Sección 8 — Base de datos: esquema mínimo obligatorio

❌ **No cumple — HIGH.** `db/schema.rb` completo:

```ruby
ActiveRecord::Schema[8.1].define(version: 0) do
end
```

Cero tablas. Ni siquiera existe `db/migrate/`. Las 6 tablas marcadas **★ no-negociables** por el documento (`users`, `companies`, `roles`, `permissions`, `role_permissions`, `user_roles`) están completamente ausentes — no hay ninguna base de datos de negocio local; toda la data vive en las APIs externas que este repo proxya.

| Regla | Estado | Severidad |
|---|---|---|
| Tablas ★ no-negociables | ❌ No cumple | 🔴 HIGH |
| `sap_licenses` [solo SAP] | N/A | — |
| Sin funciones SQL específicas de SQLite | ✅ Cumple (por ausencia de queries) | — |
| `is_active` con `default: true, null: false` | N/A | — |

---

## Sección 9 — Variables de entorno (producción)

| Variable | Estado | Evidencia |
|---|---|---|
| `OIDC_*` (5 variables) | ❌ No cumple | Ninguna presente en `.env.example` — consistente con la ausencia del submodule `auth`. |
| `LICENSE_PUBLIC_KEY` / `LICENSE_PATH` | ❌ No cumple | Ausentes — consistente con la ausencia del submodule `licensing`. |
| `SENTRY_DSN` | ✅ Cumple | Presente en `.env.example` y usada (con el problema de fallback hardcodeado ya reportado en 1.5). |
| `SENTRY_TUNNEL_PROJECT_IDS` | ❌ No cumple | Ausente — no existe endpoint `/tunnel` en absoluto (ver Sección 10.1). |
| `SECRET_KEY_BASE` | ✅ Cumple | Presente en `.env`/`.env.example`. |
| `RAILS_MASTER_KEY` | N/A | No se usa `credentials.yml.enc` en este proyecto (variables de entorno directas en su lugar) — no es una desviación reportable sin más contexto de por qué el proyecto eligió ese camino, se deja como observación. |

Variables propias del proyecto no listadas en el estándar (`API_FE_SYNC_URL`, `API_FE_APP_URL`, `API_CABYS_URL`) están bien documentadas en `.env.example` — extensión razonable, no un incumplimiento.

---

## Sección 10 — Error tracking (Sentry)

### Backend

⚠️ **Cumple parcialmente — MEDIUM.** Config actual completa ([config/initializers/sentry.rb](config/initializers/sentry.rb)):

```ruby
Sentry.init do |config|
  config.dsn = ENV.fetch('SENTRY_DSN', 'https://86ce...')  # ❌ fallback hardcodeado, ver 1.5
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.send_default_pii = true
  config.traces_sample_rate = 1.0   # doc recomienda 0.1 para APM, ajustable por volumen
end
```

Falta `config.environment = Rails.env` y `config.release = ...` (formato exacto del documento) — sin esto, los eventos en Sentry no se pueden filtrar por ambiente ni por versión de release, dificultando triage real en producción.

### 10.1 Frontend — patrón tunnel

❌ **No cumple — HIGH.** El documento es explícito: *"Obligatorio en todo producto con frontend."* Este producto tiene un frontend extenso (32 controllers Stimulus, fetch manual en 30 de ellos) y **no tiene ningún SDK de Sentry en el navegador** (`grep -rln "sentry\|Sentry" app/views app/javascript` → 0 resultados). No existe `/tunnel`, no existe `SentryTunnelController`, no existe `Sentry.init({ tunnel: ... })` en el JS.

Esto no se cierra como N/A por ausencia de mecanismo (a diferencia de casos como Sección 4/8 donde no hay nada equivalente que evaluar) — aquí el mecanismo **debería existir** porque el producto sí tiene frontend, y hoy cualquier error de JavaScript en producción es completamente invisible para el equipo salvo que el usuario lo reporte manualmente.

---

## Borradores de issue — hallazgos HIGH

> Repo destino: `Crisql/cl_cl_mlt_fec_app` (GitHub — confirmado con `git remote get-url origin`, privado).

### Issue 1 — Cobertura RSpec real: 13 specs sobre un solo controller, 0% en el resto

```
Título: Estandar Ampliar cobertura RSpec mas alla de ProxyController

Cuerpo:
La suite actual (agregada en una sesion reciente) cubre ProxyController a
fondo (13 specs) pero no toca ninguno de los ~19 controllers restantes
(namespaces configurations/* y documents/*) ni los 32 controllers Stimulus.
El estandar de plataforma exige cobertura 100% de forma bloqueante.

Impacto: cualquier regresion en los controllers de Configuraciones o
Documentos hoy solo se detecta navegando la UI a mano.

Sugerencia: priorizar request specs para los controllers con logica no
trivial (companies, connections, users) antes que smoke tests genericos
para el resto.

Evidencia: spec/requests/ solo tiene 4 archivos, todos sobre Proxy/Home/
Sessions/CSP.
```

### Issue 2 — Sin ningun controller Api::* ni sistema de permisos server-side

```
Título: Estandar Documentar o implementar la capa de permisos y licenciamiento server-side

Cuerpo:
No existe ningun controller bajo el namespace Api:: en app/controllers.
El unico punto de entrada a /api/* es ProxyController, que reenvia todo
de forma transparente a dos backends externos. Esto deja a este repo
completamente fuera del patron de permisos (Seccion 4) y licenciamiento
(Seccion 2.5) que el estandar de plataforma exige en todo producto.

El estandar permite esta desviacion si depende de verdad de un sistema
legado, pero exige que quede declarada explicitamente en el codigo
(namespace o comentario) — hoy esa declaracion no existe en ningun
archivo del repo.

Accion pedida:
(a) Confirmar con el equipo que el API externo (ApiAppUrl/ApiFEUrl) SI
    hace esta verificacion de permisos/licencia server-side, y
(b) Documentarlo explicitamente en el codigo (ej. comentario en
    ApplicationController o ARQUITECTURA.md) para que la proxima
    auditoria no vuelva a reportarlo como incumplimiento sin dueno.

Evidencia: grep -rn "class \w+Controller < Api::" app/controllers -> 0
resultados; grep -rn "require_permission!" app/controllers -> 0.
```

### Issue 3 — Token de sesion en localStorage en vez de session cookie

```
Título: Estandar Evaluar migracion de token de sesion a session cookie httpOnly

Cuerpo:
El estandar marca como no negociable que los tokens nunca vivan en
localStorage del frontend, sino en la session cookie de Rails. Este
proyecto guarda el token de acceso en localStorage, documentado
explicitamente en application_controller.rb y sessions_controller.rb
como decision deliberada para replicar el comportamiento del Angular
legado durante la migracion.

Es una desviacion documentada, no un descuido, pero el riesgo que la
regla busca prevenir (robo de token via XSS, sin proteccion httpOnly)
sigue vigente.

Evidencia: application_controller.rb:7, sessions_controller.rb:7-8.
```

### Issue 4 — Cero tablas de base de datos, sin las 6 tablas no-negociables

```
Título: Estandar Documentar por que el esquema de BD esta vacio o agregar las tablas no negociables

Cuerpo:
db/schema.rb no tiene ninguna tabla (version: 0, sin db/migrate/). Las 6
tablas marcadas no-negociables por el estandar (users, companies, roles,
permissions, role_permissions, user_roles) no existen en este repo.

Si la decision es que toda esa data vive en los APIs externos (lo cual
es consistente con la arquitectura actual de proxy), falta documentarlo
explicitamente para que la proxima auditoria no lo vuelva a marcar como
un vacio sin dueno.

Evidencia: db/schema.rb (version: 0), ausencia de db/migrate/.
```

### Issue 5 — Sin Sentry en el frontend (patron tunnel ausente)

```
Título: Estandar Implementar Sentry SDK de navegador con patron tunnel

Cuerpo:
El producto tiene un frontend extenso (32 controllers Stimulus) y no
reporta ningun error de JavaScript a Sentry — solo el backend Rails
esta cubierto. El estandar marca esto como obligatorio en todo producto
con frontend, con el patron tunnel especifico (endpoint /tunnel propio,
reenvio en background con timeout corto) para evitar que ad-blockers
pierdan los eventos y sin bloquear al usuario.

Impacto: un error de JS en produccion hoy es invisible para el equipo
salvo que el usuario lo reporte manualmente.

Evidencia: grep -rln "sentry" app/views app/javascript -> 0 resultados.
```

---

## Resumen ejecutivo

### Bloque 1 — Calidad de código (Sección 1)

- 🟠 MEDIUM — Manejo de errores no usa SweetAlert2 (Sección 5.1); reimplementación propia consistente pero fuera de estándar.
- 🟠 MEDIUM — 10/32 controllers Stimulus sin `disconnect()`, con un leak real ya corregido en esta sesión (`documents_receptions_controller.js`).
- 🟡 LOW — 2 `console.log` de debug sin limpiar.
- 🟡 LOW — SOLID en JS no auditado método por método (fuera de alcance práctico); señal a revisar en archivos >700 líneas.

### Bloque 2 — Estándares técnicos (resto de secciones)

- 🔴 HIGH — Ningún submodule Ruby de plataforma instalado (Sección 2), sin declaración de excepción.
- 🔴 HIGH — Token de sesión en `localStorage` en vez de session cookie (Sección 2.3).
- 🔴 HIGH — Ningún controller `Api::*`, sin sistema de permisos ni licenciamiento server-side (Sección 4/4.5).
- 🔴 HIGH — Cero tablas de base de datos; faltan las 6 no-negociables (Sección 8).
- 🔴 HIGH — Cobertura RSpec real ~5% del código (solo `ProxyController`), sin Vitest ni Playwright (Sección 7.3).
- 🔴 HIGH — Sin Sentry en el frontend, patrón tunnel ausente (Sección 10.1).
- 🟠 MEDIUM — DSN de Sentry hardcodeado como fallback (Sección 1.5).
- 🟠 MEDIUM — Material Icons servido desde Google Fonts, no auto-hospedado (Sección 7.2).
- 🟠 MEDIUM — Gemas del stack backend ausentes (`httparty`, `jwt`, `openid_connect`, `factory_bot_rails`) — misma causa raíz que el hallazgo de submodules.
- 🟡 LOW — `faraday` instalado pero sin ningún uso (dependencia muerta).
- 🟡 LOW — Antipatrón `dispatchEvent(CustomEvent("toast"))` en 3 archivos vendor.
- 🟡 LOW — 3 usos de `createObjectURL` sin `revokeObjectURL` correspondiente.
- ✅ Ya corregido en esta sesión de trabajo — CSP activa, Tabulator vendorizado (JS + CSS), suite RSpec inicial arrancada.

### Bloque 3 — Discrepancias documentación-vs-código

- El propio código documenta la desviación de `localStorage` (comentarios explícitos en `application_controller.rb`/`sessions_controller.rb`), pero esa documentación describe *qué* hace el código, no lo declara como una *excepción formal* con justificación — el documento distingue ambas cosas explícitamente.
- `docs/menu.json` es un archivo placeholder que solo contiene una nota explicando que el menú real vive en `app/javascript/data/menu.js` — no es documentación desactualizada respecto al código, es una nota de redirección correcta, pero vale la pena que un lector nuevo no asuma que `docs/menu.json` es la fuente real.
- No se encontraron afirmaciones de README/comentarios que contradigan directamente el comportamiento real del código más allá de lo ya señalado arriba.

---

Correr esta auditoría no es el final del proceso: resolver lo que indica es responsabilidad de quien desarrolla. Los hallazgos HIGH sin resolver van a seguir apareciendo en la próxima corrida — especialmente la ausencia de submodules, el sistema de permisos, y la cobertura de tests, que son el mismo tipo de vacío estructural repetido en distintas secciones.

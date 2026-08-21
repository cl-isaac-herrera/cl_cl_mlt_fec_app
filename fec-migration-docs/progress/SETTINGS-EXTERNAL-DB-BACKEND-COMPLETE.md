# SETTINGS + EXTERNAL-DB — Backend Completo

**Fecha:** 2026-08-21  
**Alcance:** tabla `settings` (ajustes cifrados) + conector ODBC a base externa  
**Estado:** lógica de negocio completa. **UI sin tocar** — el módulo Configuraciones → Generales sigue leyendo el .NET por proxy  
**Documento técnico:** `docs/CONSULTA-BASE-EXTERNA.md`  
**Reglas del proyecto:** `CLAUDE.md` §36 (settings) y §37 (bases externas)

---

## 🎯 Qué se pidió y qué se entregó

Consultar una base de datos externa que, según la instalación, corre sobre **SQL Server** o
sobre **SAP HANA**, con un conector compatible con los dos (ODBC), y con las credenciales
administrables desde la interfaz.

La configuración vive en una tabla `settings` con `code` + `value` cifrado, sembrada sin valor
desde `db/seeds.rb`, agrupada por convención de prefijo, y con un `is_visible` que decide si el
valor puede salir del servidor.

> ⚠️ **Esto NO es una vía alterna para llegar a SAP.** La base de documentos es propia. El
> acceso a SAP Business One sigue siendo 100% Service Layer y `CLAUDE.md` §29 queda intacto,
> sin excepciones.

---

## ✅ Funcionalidad implementada

### Tabla `settings`

| Funcionalidad | Estado |
|---|---|
| Migración con `code`, `group_code`, `description`, `value`, `is_visible` + auditoría | ✅ |
| `value` cifrado con `encrypts` (reversible, no determinista) | ✅ |
| `value` como `text` y **sin** `limit:` — el sobre del cifrado infla el dato (§29) | ✅ |
| Índice único en `code`, índice en `group_code` | ✅ |
| Convención de `code` validada por formato (`{DOMINIO}_{SUBDOMINIO}_{CAMPO}`) | ✅ |
| Unicidad con `unscope(where: :is_active)` — el índice no excluye a las inactivas | ✅ |
| `Auditable` + `SoftDeletable` como el resto de las tablas | ✅ |
| `Setting.value_for(code)` y `Setting.group(group_code)` | ✅ |
| `Setting#update_value!` — único camino de escritura desde la UI | ✅ |
| `Setting#visible_value` / `#value?` — respetan `is_visible` | ✅ |
| Catálogo en `db/seeds.rb`: 13 ajustes en 3 grupos, **sin valor** | ✅ |
| Seed idempotente que **nunca** toca `value` (a diferencia del de `permissions`) | ✅ |
| Seed reactiva un ajuste dado de baja sin duplicarlo (`unscoped`) | ✅ |
| `db/setting_code_map.yml` — equivalencia con los `code` del .NET | ✅ |
| Claves de i18n del modelo, atributos y `invalid_format` (§30) | ✅ |

### Conector ODBC

| Funcionalidad | Estado |
|---|---|
| Gema `ruby-odbc` compilada y `require: false` (no tumba el boot) | ✅ |
| `ExternalDb::Config` — destino armado desde el grupo de settings | ✅ |
| Ajustes faltantes reportados **todos juntos**, nombrando el `code` completo | ✅ |
| Validación del puerto (obligatorio en HANA, opcional en SQL Server) | ✅ |
| Validación del driver contra los instalados, listando los disponibles | ✅ |
| `ExternalDb::Dialect::SqlServer` — DSN, `[base].[dbo].[obj]`, `OFFSET/FETCH` | ✅ |
| `ExternalDb::Dialect::Hana` — `SERVERNODE`, `base.obj`, `LIMIT/OFFSET` | ✅ |
| `{CALL …}` con escape ODBC — portable entre `EXEC` y `CALL` | ✅ |
| Consultas parametrizadas con `?` (igual en los dos drivers) | ✅ |
| `ExternalDb::StatementGuard` — solo `SELECT`/`WITH`, sin multi-sentencia | ✅ |
| `autocommit = false` + `rollback` en cada sentencia | ✅ |
| Tope de 10 000 filas y timeout de consulta configurable | ✅ |
| `ExternalDb::Pool` indexado por fingerprint de la configuración | ✅ |
| El pool se descarta y cierra cuando el operador cambia un ajuste | ✅ |
| `ExternalDb::HealthCheck` — nunca levanta, devuelve motor, versión y latencia | ✅ |
| Mensajes del driver limpiados de los corchetes de capas + contraseña tapada | ✅ |
| Jerarquía de errores, una constante por archivo (lo exige Zeitwerk) | ✅ |

---

## 🔍 Verificación en el servidor

ODBC no se eligió por descarte: se comprobó que el entorno lo soporta antes de escribir código.

| Qué | Resultado |
|---|---|
| Driver de SAP HANA | `HDBODBC` instalado |
| Driver de SQL Server | `ODBC Driver 17 for SQL Server` instalado |
| Los dos visibles desde Ruby | `ODBC.drivers` los enumera |
| Toolchain para la extensión nativa | gcc 16.1.0 (UCRT64), coincide con `x64-mingw-ucrt` |
| Headers ODBC | `sql.h`, `sqlext.h`, `sqltypes.h`, `sqlucode.h` presentes |
| Compilación | `ruby-odbc-0.999993` compilada e instalada |
| API de la gema | `drvconnect` (DSN-less), `prepare`/`execute`, `fetch_hash`, `timeout=`, `maxrows=`, `rollback` |

---

## 🧩 Diferencias entre motores

**El corazón del conector.** Los campos de configuración son los mismos pero **no significan lo
mismo**. Todo esto vive en `app/services/external_db/dialect/` y en ningún otro lado.

```
SQL Server │ Driver={ODBC Driver 17 for SQL Server};Server=CLSQL01;Database=CL_DOCS;UID=…;PWD=…
HANA       │ Driver={HDBODBC};SERVERNODE=clhna721:30015;UID=…;PWD=…
```

| | SQL Server | HANA |
|---|---|---|
| Clave del host | `Server` | `SERVERNODE` |
| Separador del puerto | **coma** | **dos puntos** |
| Puerto | opcional (1433 implícito) | **obligatorio** (`3<NN>15`) |
| La base | `Database=` en el DSN | **NO va en el DSN** |
| Calificación | `[CL_DOCS].[dbo].[SP]` | `CL_DOCS.SP` (la base **es** el esquema) |
| Paginación | `OFFSET/FETCH`, exige `ORDER BY` | `LIMIT/OFFSET` |
| Sondeo | `SELECT 1` | `SELECT 1 FROM DUMMY` |
| Entrecomillado | `[obj]`, duplica `]` | desnudo en mayúscula; `"obj"` solo si lo exige |

Tres puntos que salieron de la práctica real de las instalaciones, no de la documentación de los
drivers:

- **El puerto de HANA es el puerto SQL de la instancia** (`30015` para la 00). No hay valor
  implícito, así que `Config` lo exige cuando el motor es HANA.
- **En HANA la base no entra al DSN.** Califica cada objeto de cada consulta
  (`CALL <db-code>.SP1`). Hay un spec que falla si se filtra al DSN.
- **El entrecomillado de HANA replica lo que ya funciona.** HANA pasa a mayúsculas todo
  identificador sin comillas, así que emitirlo desnudo apunta al mismo objeto que la consulta
  escrita a mano. Entrecomillar tal cual lo que teclee el operador rompería la consulta el día
  que escriba el código de base en minúscula: `"cl_docs"` no existe, `CL_DOCS` sí.

| El operador escribe | Se emite | Por qué |
|---|---|---|
| `CL_DOCS` | `CL_DOCS` | Ya es seguro sin comillas |
| `cl_docs` | `CL_DOCS` | Desnudo y en mayúscula: HANA lo normalizaría igual |
| `CL-DOCS` | `"CL-DOCS"` | El guion exige comillas; ahí la caja se respeta |

---

## 🔒 Alcance real del solo-lectura

Se documenta explícitamente porque es fácil sobreestimarlo.

### Lo que el código hace

| Defensa | Qué cubre |
|---|---|
| `StatementGuard` | Abre con `SELECT`/`WITH`; rechaza verbos de escritura en cualquier posición y más de una sentencia |
| Sin `#execute` | Ningún método público ejecuta DML |
| `autocommit = false` + `rollback` | Si algo llegó a modificar, se deshace |
| `maxrows` + tope en `#collect` | 10 000 filas: un `SELECT` sin `WHERE` no se trae la tabla entera |
| `timeout` | Una consulta colgada no retiene la conexión del pool para siempre |

### Lo que NO cubre

- **`ruby-odbc` no expone `SQL_ATTR_ACCESS_MODE`** — verificado: define `SQL_AUTOCOMMIT` y
  ninguna constante de access mode. **La conexión no se puede abrir en modo lectura.**
- **`WITH` puede llevar DML** — `WITH c AS (SELECT…) DELETE FROM c` es válido en SQL Server. Los
  verbos se buscan en cualquier posición, pero es un chequeo textual, no un parser.
- **Un procedimiento almacenado hace lo que quiera.** `#call` los invoca y **no pasa por el
  guard**: desde la app no hay forma de saber si lee o escribe.

### 🔑 La garantía real

> El usuario de `DOCS_DB_ODBC_USER` tiene permisos de **lectura y nada más**
> (`db_datareader` en SQL Server, `SELECT` sobre el esquema en HANA). `GRANT EXECUTE` se concede
> **procedimiento por procedimiento**, nunca sobre el esquema completo: un procedimiento corre
> con los permisos de su dueño y puede escribir aunque quien lo llama no pueda.

El DDL de los grants para los dos motores está en `docs/CONSULTA-BASE-EXTERNA.md` §5.

---

## 🐛 Defectos encontrados y corregidos

Cuatro, todos detectados por verificación y no por revisión visual. Los tres primeros habrían
fallado en producción con mensajes inútiles.

| # | Defecto | Cómo se habría visto |
|---|---|---|
| 1 | Cinco constantes de error en un solo `error.rb` | `NameError: uninitialized constant ExternalDb::ReadOnlyViolation` en ejecución — Zeitwerk resuelve una constante por archivo |
| 2 | `Driver={{ODBC Driver 17…}}}` — llaves duplicadas | "Data source name not found": el dialecto las ponía y `build_dsn` otra vez |
| 3 | `Driver={ODBC Driver 17 for SQL Server` — **sin cerrar** | Igual. La forma interpolada necesita **dos** `}` finales (uno cierra la interpolación, otro es el literal) y quedó uno |
| 4 | Byte NUL crudo en `config.rb` | `grep` reportaba el archivo como binario (§18) |

El #3 se reescribió con concatenación explícita, que no se puede leer mal:

```ruby
# ✅ inequívoco
'{' + value.to_s.gsub('}', '}}') + '}'

# ❌ frágil: con un `}` menos, la llave de cierre desaparece en silencio
"{#{value.to_s.gsub('}', '}}')}}"
```

El #4 estaba en el separador del fingerprint. La intención era correcta —`\0` no puede aparecer
en un host ni en una contraseña, mientras un espacio dejaría colisionar `['ab','c']` con
`['a','bc']`— pero tenía que ir como escape. Quedó en la constante `FINGERPRINT_SEPARATOR`.

---

## 📊 Pruebas

- **Archivos:** `spec/models/setting_spec.rb`, `spec/services/external_db/{config,dialect,statement_guard}_spec.rb`
- **Total:** 94 ejemplos nuevos · **543 en la suite completa** · **0 fallas**
- **Suites:**
  1. `Setting` — convención del `code`, unicidad con soft delete, cifrado, `is_visible`, `.value_for`, `.group`, `#update_value!` (25 tests)
  2. `ExternalDb::Config` — faltantes listados juntos, puerto por motor, driver instalado, fingerprint (19 tests)
  3. `ExternalDb::Dialect` — las dos cadenas de conexión completas, calificación, `{CALL}`, paginación, sondeo (27 tests)
  4. `ExternalDb::StatementGuard` — qué pasa, qué se rechaza y **qué no atrapa** (23 tests)

**Verificaciones fuera de RSpec:**

| Qué se probó | Resultado |
|---|---|
| Segundo `db:seed` sobre una base con valores configurados | 13 filas → 13 filas, valores intactos |
| Ajuste oculto (`CRYSTAL_PASSWORD`) tras re-seed | Valor conservado, sigue `is_visible: false` |
| Ajuste dado de baja tras re-seed | Reactivado, sin duplicar |
| `value` en la base | Sobre cifrado de 78 bytes, sin el texto plano |
| Bytes NUL en los archivos nuevos | Todos limpios (§18) |
| Sintaxis Ruby de los 15 archivos nuevos | `ruby -c` en verde |
| Submódulos | Sin cambios (§27) |

**Sin cobertura:** la conexión real. `Client#connect` y el pool necesitan un servidor de base al
otro lado; para eso está `ExternalDb::HealthCheck`, que es lo primero que hay que correr después
de configurar el grupo.

---

## 📁 Archivos creados / modificados

| Archivo | Tipo |
|---|---|
| `db/migrate/20260821120000_create_settings.rb` | Nuevo |
| `db/setting_code_map.yml` | Nuevo (equivalencia con los `code` del .NET) |
| `app/models/setting.rb` | Nuevo |
| `app/services/external_db/error.rb` | Nuevo (base de la jerarquía) |
| `app/services/external_db/configuration_error.rb` | Nuevo |
| `app/services/external_db/connection_error.rb` | Nuevo |
| `app/services/external_db/query_error.rb` | Nuevo |
| `app/services/external_db/read_only_violation.rb` | Nuevo |
| `app/services/external_db/config.rb` | Nuevo (destino desde `settings`) |
| `app/services/external_db/dialect.rb` | Nuevo (resolución del dialecto) |
| `app/services/external_db/dialect/base.rb` | Nuevo (contrato + `build_dsn`) |
| `app/services/external_db/dialect/sql_server.rb` | Nuevo |
| `app/services/external_db/dialect/hana.rb` | Nuevo |
| `app/services/external_db/statement_guard.rb` | Nuevo (red de solo lectura) |
| `app/services/external_db/client.rb` | Nuevo (conexión y consulta) |
| `app/services/external_db/pool.rb` | Nuevo |
| `app/services/external_db/health_check.rb` | Nuevo |
| `docs/CONSULTA-BASE-EXTERNA.md` | Nuevo (referencia técnica) |
| `spec/factories/settings.rb` | Nuevo |
| `spec/models/setting_spec.rb` | Nuevo (25 tests) |
| `spec/services/external_db/config_spec.rb` | Nuevo (19 tests) |
| `spec/services/external_db/dialect_spec.rb` | Nuevo (27 tests) |
| `spec/services/external_db/statement_guard_spec.rb` | Nuevo (23 tests) |
| `Gemfile` | Modificado (`ruby-odbc` con `require: false`, `connection_pool`) |
| `Gemfile.lock` | Modificado |
| `db/seeds.rb` | Modificado (sección 6: 13 ajustes en 3 grupos) |
| `db/schema.rb` | Modificado (tabla `settings`) |
| `config/locales/es.yml` | Modificado (§30: modelo, atributos, `invalid_format`) |
| `CLAUDE.md` | Modificado (§36 settings, §37 bases externas) |
| `TODOS.md` | Modificado (2 secciones nuevas) |

**Una constante de error por archivo** porque lo exige Zeitwerk — misma convención que
`Certificates::Error` / `CompanyFiles::Error`.

---

## 📋 Diferencias con el API .NET

- **La tabla no es nueva: es la migración del `Setting` del .NET.** El módulo Configuraciones →
  Generales ya consumía `GET /api/settings` y `PATCH /api/settings` por proxy, con tres filas
  vivas: `CedulaProveedorSistemas`, `CrystalUser` y `CrystalPassword`.
- **La columna del valor se llamaba `Json` y guardaba strings planos** — el nombre venía de un
  tipo que se abandonó. Pasa a `value`.
- **⚠️ `CrystalPassword` viaja HOY en claro al browser.** `general_configs_controller.js:137`
  hace `this.crystalPasswordInputTarget.value = crystalP.Json` y la enmascara solo con un
  `type="password"` que tiene botón para revelarla. `is_visible: false` corta eso **en el
  servidor**: el valor deja de salir. Como la UI no se tocó en esta tanda, la fuga sigue viva
  hasta que se migre el endpoint.
- **Los `code` pasan de PascalCase a SCREAMING_SNAKE** para poder agrupar por prefijo, que es lo
  que junta los ajustes de un dominio en la pantalla. `Setting::CODE_FORMAT` rechaza el formato
  viejo, así que una importación **tiene** que traducir por `db/setting_code_map.yml`.
- **El `code` es la llave natural y va en la URL, no en el cuerpo.** El .NET manda
  `PATCH /api/settings` con `{ Code, Json, IsActive }`; el endpoint migrado será
  `PATCH /api/settings/:code` (§28).
- **El valor va cifrado en reposo.** El .NET lo guardaba en claro.
- **Los parámetros ODBC que se habían eliminado de `connections` no vuelven ahí.** `TODOS.md`
  registra la decisión del 2026-08-12 de que `ODBCType`, `ServerType`, `DBUser` y `DBPass`
  mueren con el modelo de acceso directo a SAP. Esta conexión es a una base **propia** y su
  configuración vive en `settings`, no en `connections`, así que esa decisión queda intacta.

---

## ⏭️ Pendiente

**No se tocó la UI**, por indicación explícita. La tabla está sembrada pero **nadie la lee
todavía**: el módulo General sigue apuntando al .NET por proxy.

| Pendiente | Detalle |
|---|---|
| `Api::SettingsController` | `GET /api/settings` y `PATCH /api/settings/:code` nativos |
| Serialización | `Value: nil` + `HasValue: true` para los ocultos |
| Migrar la pantalla | El JS lee `s.Json` → pasa a `Value`; los `code` cambian |
| Botón "Probar conexión" | Sobre `ExternalDb::HealthCheck`, que ya está listo |
| Permiso propio | Hoy la pantalla usa `Configurations_General_Access`, que es de lectura |
| Importación de datos | Tarea que traiga los `Setting` del .NET traduciendo por el map |
| Cerrar el pool | `Pool.shutdown!` en el `before_fork` / `on_worker_shutdown` de Puma |

Detalle completo en `TODOS.md` → *Ajustes de la instalación* y *Base de documentos*.

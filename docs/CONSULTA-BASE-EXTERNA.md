# CONSULTA-BASE-EXTERNA — Conector ODBC a SQL Server y SAP HANA

**Fecha:** 2026-08-21
**Estado:** lógica de negocio implementada. **Sin UI todavía** — ver [Lo que falta](#lo-que-falta).
**Ubicación del código:** `app/services/external_db/`
**Configuración:** tabla `settings`, grupo `DOCS_DB_ODBC`

---

## 1. Qué resuelve y por qué ODBC

La app necesita consultar una base de datos **externa** de documentos, alojada en
otro servidor, que según la instalación corre sobre **SQL Server** o sobre **SAP
HANA**. Un solo conector tiene que servir para las dos.

**ODBC es el único que cumple eso con una sola gema.** El driver manager del
sistema resuelve el destino y la app solo cambia la cadena de conexión. La
alternativa era `tiny_tds` para SQL Server más un cliente de HANA: dos
dependencias nativas, dos APIs, dos rutas de error.

Los dos drivers ya están instalados en el servidor (los instala el cliente de
SAP y el paquete de Microsoft):

```
HDBODBC                          ← SAP HANA
ODBC Driver 17 for SQL Server    ← SQL Server
```

### Esto NO reemplaza al Service Layer

La base de documentos **no es la base de SAP Business One**. Todo acceso a SAP
sigue pasando por `Clavisco::ServiceLayer::Client`, y `CLAUDE.md` §29 sigue
vigente sin excepciones. Este conector existe para una base propia; usarlo contra
la base de compañía de SAP saltaría la lógica de negocio de SAP y anularía su
soporte.

| Destino | Vía | Regla |
|---|---|---|
| SAP Business One | `Clavisco::ServiceLayer::Client` | CLAUDE.md §29 |
| Base de documentos | `ExternalDb::Pool` | este documento |

---

## 2. Configuración — la tabla `settings`

Los ajustes se declaran en `db/seeds.rb` **sin valor**; el operador los completa
desde Configuraciones → Generales. La tabla es la contraparte del `Setting` del
API .NET, que ese módulo ya consumía por proxy.

### Esquema

| Columna | Tipo | Notas |
|---|---|---|
| `code` | string | Llave natural. Índice único. Convención en §2.1 |
| `group_code` | string | Prefijo del `code`. Indexado. Lo agrupa en la pantalla |
| `description` | string | Etiqueta que ve el usuario |
| `value` | text | **Cifrado** (`encrypts`). Nullable = sembrado sin configurar |
| `is_visible` | boolean | `false` = el valor no sale del servidor |
| `is_active` | boolean | Baja lógica (`SoftDeletable`) |
| auditoría | — | `created_at/by`, `updated_at/by` (`Auditable`) |

Tres decisiones que conviene no revertir sin leer el motivo:

- **`value` es `text` y no lleva `limit:`.** Lo que se guarda es el sobre del
  cifrado (`{"p":…,"h":{"iv":…,"at":…}}`): ~70 caracteres fijos más 4/3 del texto
  original — una contraseña de 50 chars ocupa 138. Dimensionar contra el dato en
  claro es el error que advierte `CLAUDE.md` §29. El largo del texto plano se
  valida en el modelo (`Setting::MAX_VALUE_LENGTH`).
- **El cifrado es no determinista.** El mismo texto produce un criptograma
  distinto cada vez, así que `where(value: x)` nunca encuentra nada y un índice
  sobre esa columna no sirve. Toda lectura entra por `code`.
- **`group_code` es una columna y no se deriva del `code`.** Partir
  `DOCS_DB_ODBC_QUERY_TIMEOUT` por el último `_` daría el grupo
  `DOCS_DB_ODBC_QUERY`. El grupo ya se declara en el seed; la columna solo lo
  materializa.

### 2.1 Convención del `code`

```
{DOMINIO}_{SUBDOMINIO}_{CAMPO}     en SCREAMING_SNAKE
```

`Setting::CODE_FORMAT` la valida, así que un `code` en PascalCase **no se puede
insertar** — es lo que impide que una importación desde el .NET meta los nombres
del origen sin traducir.

| `code` | `group_code` | Campo |
|---|---|---|
| `DOCS_DB_ODBC_SERVER` | `DOCS_DB_ODBC` | `SERVER` |
| `DOCS_DB_ODBC_QUERY_TIMEOUT` | `DOCS_DB_ODBC` | `QUERY_TIMEOUT` |
| `CRYSTAL_PASSWORD` | `CRYSTAL` | `PASSWORD` |

### 2.2 `is_visible` — campos de solo escritura

`is_visible: false` significa que **el valor nunca sale del servidor**. La
pantalla puede escribirlo, y para saber si ya hay uno guardado consulta
`Setting#value?`, que devuelve un booleano y no el secreto.

Esto arregla un defecto concreto del .NET: hoy `CrystalPassword` viaja **en
claro** al browser y la UI la enmascara con un `type="password"` que tiene botón
para revelarla (`general_configs_controller.js:137`).

```ruby
setting.value          # => "s3cr3t"   (uso interno, para armar el DSN)
setting.visible_value  # => nil        (lo que puede salir en una respuesta)
setting.value?         # => true       ("hay una contraseña guardada")
```

> **Regla:** `is_visible` y `description` los setea **solo** `db/seeds.rb`. Desde
> la interfaz se escribe únicamente `value`, por `Setting#update_value!`, y la
> auditoría se llena sola.

### 2.3 ⚠️ El seed de `settings` NO borra

Es la diferencia con el seed de `permissions`, que hace
`Permission.unscoped.delete_all` para poder forzar los Id del origen. Copiar ese
patrón acá **borraría las credenciales que escribió el operador**, y la
instalación quedaría muda sin ningún error que lo explicara.

```ruby
record = Setting.unscoped.find_or_initialize_by(code: code)  # unscoped: reactiva
record.group_code  = group_code                              # metadata: sí
record.description = description
record.is_visible  = is_visible
record.save!                                                 # `value`: JAMÁS
```

`unscoped` es necesario porque el índice único **no** excluye a las filas
inactivas: sin él, un ajuste dado de baja no se encuentra y el seed intenta
insertar otro igual — y el que se pierde es el que tiene el valor.

Verificado: sembrar dos veces sobre una base con valores configurados deja las 13
filas intactas, con sus valores, y reactiva las dadas de baja sin duplicarlas.

### 2.4 Ajustes del grupo `DOCS_DB_ODBC`

| `code` | Qué es | `is_visible` |
|---|---|---|
| `DOCS_DB_ODBC_ENGINE` | `SQL` o `HANA`. Elige el dialecto | ✅ |
| `DOCS_DB_ODBC_DRIVER` | Nombre del driver instalado | ✅ |
| `DOCS_DB_ODBC_SERVER` | Nombre **DNS** del servidor | ✅ |
| `DOCS_DB_ODBC_PORT` | Puerto. **Obligatorio en HANA** | ✅ |
| `DOCS_DB_ODBC_DATABASE` | Código de base / catálogo | ✅ |
| `DOCS_DB_ODBC_SCHEMA` | Esquema (`dbo` por defecto en SQL Server) | ✅ |
| `DOCS_DB_ODBC_TRUSTED` | Autenticación integrada de Windows. **Solo SQL Server** | ✅ |
| `DOCS_DB_ODBC_USER` | Usuario de BD, **solo lectura**. Opcional con `TRUSTED` | ✅ |
| `DOCS_DB_ODBC_PASSWORD` | Contraseña. Opcional con `TRUSTED` | ❌ |
| `DOCS_DB_ODBC_QUERY_TIMEOUT` | Segundos. Default 30 | ✅ |
| `DOCS_DB_ODBC_EXTRA_PARAMS` | Pares `clave=valor;` extra de la cadena | ✅ |

### 2.5 Equivalencia con los `code` del .NET

`db/setting_code_map.yml` guarda la traducción. **La importación desde SQL Server
tiene que leerlo**: sin traducir, inserta filas con el nombre de origen al lado de
las sembradas y el ajuste queda duplicado — la pantalla muestra el sembrado
(vacío) y el valor real se queda en la fila huérfana, sin que nadie reciba un
error.

| `Setting.Code` (.NET) | `settings.code` (Rails) |
|---|---|
| `CedulaProveedorSistemas` | `GENERAL_PROVIDER_ID` |
| `CrystalUser` | `CRYSTAL_USER` |
| `CrystalPassword` | `CRYSTAL_PASSWORD` (ahora `is_visible: false`) |

---

## 3. Las diferencias entre SQL Server y HANA

**Es el corazón del conector.** Los campos de configuración son los mismos, pero
**no significan lo mismo** en los dos motores. Todo esto vive en
`app/services/external_db/dialect/` y en ningún otro lado: un `if config.hana?`
fuera de esa carpeta significa que la diferencia se escapó.

### 3.1 Cadena de conexión

```
SQL Server │ Driver={ODBC Driver 17 for SQL Server};Server=CLSQL01;Database=CL_DOCS;UID=…;PWD=…
HANA       │ Driver={HDBODBC};SERVERNODE=clhna721:30015;UID=…;PWD=…
```

| | SQL Server | HANA |
|---|---|---|
| Clave del host | `Server` | `SERVERNODE` |
| Separador del puerto | **coma** (`CLSQL01,1433`) | **dos puntos** (`clhna721:30015`) |
| Puerto | opcional (1433 implícito) | **obligatorio** |
| La base | `Database=` **en el DSN** | **NO va en el DSN** |

Tres cosas que cuestan una conexión que no se establece:

- **El puerto de HANA es el puerto SQL de la instancia: `3<NN>15`** — 30015 para
  la instancia 00, 30115 para la 01. No hay valor implícito, por eso
  `ExternalDb::Config` lo exige cuando el motor es HANA.
- **En SQL Server el puerto va con coma.** Con dos puntos el driver lo interpreta
  como nombre de instancia y falla con "server not found". Una instancia nombrada
  se escribe `CLSQL01\INSTANCIA` en el ajuste `SERVER`.
- **En HANA la base no va en la cadena.** Es la práctica de las instalaciones
  vivas: el código de base califica cada objeto de cada consulta. Un
  `DATABASENAME=` solo hace falta en un HANA multi-tenant (MDC) para elegir el
  tenant, y para eso está `EXTRA_PARAMS`.

### 3.2 Entrecomillado del nombre del driver

`Driver` va **siempre entre llaves**: todos los nombres reales llevan espacios.
El dialecto pasa el nombre pelado y `build_dsn` pone las llaves — ponerlas
también en el dialecto produce `Driver={{…}}}`, que el driver manager no
resuelve.

El resto de los valores se encierra solo si lo necesita. **Importa sobre todo
para la contraseña:** una que tenga `;` parte la cadena y los parámetros que
siguen se pierden sin ningún error. Dentro de las llaves, ODBC solo exige
duplicar el `}` de cierre.

### 3.3 Calificación de objetos

```
SQL Server │ [CL_DOCS].[dbo].[SP_DOCS]      base + esquema + objeto
HANA       │ CL_DOCS.SP1                     un solo tramo
```

En HANA **el código de base ES el esquema**: la calificación no tiene el tramo
intermedio que sí tiene SQL Server. Y sin el `dbo`, `[CL_DOCS].[SP]` es una
calificación inválida — por eso el esquema cae en `dbo` cuando no está
configurado.

**El entrecomillado de HANA es deliberadamente conservador.** HANA pasa a
mayúsculas todo identificador sin comillas y respeta la caja exacta de uno
entrecomillado. Como las consultas de las instalaciones se escriben
`CALL <db-code>.SP1` **sin** comillas, el objeto real tiene el nombre en
mayúsculas. Entrecomillar tal cual lo que teclee el operador rompería la consulta
el día que escriba el código de base en minúscula: `"cl_docs"` no existe,
`CL_DOCS` sí.

| El operador escribe | Se emite | Por qué |
|---|---|---|
| `CL_DOCS` | `CL_DOCS` | Ya es seguro sin comillas |
| `cl_docs` | `CL_DOCS` | Desnudo y en mayúscula: HANA lo normalizaría igual |
| `CL-DOCS` | `"CL-DOCS"` | El guion exige comillas; ahí la caja se respeta |

### 3.4 Procedimientos almacenados — `EXEC` en SQL Server, `CALL` en HANA

Cada motor tiene su palabra clave y su forma de escribir la lista de argumentos.
Lo resuelve el dialecto, así que quien llama no escribe ninguna de las dos:

```ruby
client.call('SP_DOCS_POR_FECHA', [desde, hasta])
client.call('SP_PENDIENTES')

# SQL Server → EXEC [CL_DOCS].[dbo].[SP_DOCS_POR_FECHA] ?, ?
#              EXEC [CL_DOCS].[dbo].[SP_PENDIENTES]              ← sin lista
# HANA       → CALL CL_DOCS.SP_DOCS_POR_FECHA(?, ?)
#              CALL CL_DOCS.SP_PENDIENTES()                      ← lista vacía
```

**La lista de argumentos se comporta al revés en los dos motores.** En `EXEC` un
procedimiento sin parámetros no lleva nada; en `CALL` lleva los paréntesis
vacíos, que su gramática exige.

#### `commit:` — cuando el procedimiento SÍ tiene que escribir

La conexión se abre con `autocommit = false` y toda sentencia se revierte al
salir. Es la defensa de solo-lectura del conector, y por defecto también aplica a
`call`. Pero hay procedimientos **diseñados para escribir** que no son una fuga:

```ruby
client.call('CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS', [], commit: true)
```

Ese es un `UPDATE … OUTPUT` que reclama las filas de la cola y las devuelve en la
misma operación atómica. Revertirlo lo deja sin efecto: la cola nunca avanza, la
misma tanda se reprocesa en cada corrida y la ventana de reintento de diez
minutos del procedimiento no llega a activarse nunca.

- **Se confirma solo si la ejecución terminó bien.** Después de un error se
  revierte igual: dejar la mitad del trabajo hecha es peor que no hacer nada.
- **Un commit fallido LEVANTA**, al revés que el rollback, que se traga el error.
  Si no, el llamador creería que reclamó documentos que en realidad siguen
  libres y los tomaría de nuevo en la próxima corrida.
- **No relaja los permisos.** Un procedimiento corre con los permisos de su
  dueño, así que la cuenta de la aplicación sigue necesitando solo `EXECUTE`
  sobre él, nunca escritura sobre las tablas.
- **`select` no lo tiene y no lo va a tener.** La excepción es de `call` y punto;
  quién escribe se audita con un `grep commit: true`.

> En .NET esto no existía porque ADO.NET trabaja en **autocommit**: allá confirmar
> era el comportamiento normal y nadie lo escribía. Acá el default es al revés, y
> por eso la excepción tiene que ser explícita.

#### Por qué no el escape ODBC `{CALL …}`

El conector usaba `{CALL …}`, que es portable en teoría: el driver manager lo
traduce a `EXEC` o a `CALL` según el motor. En la práctica esa traducción no es
transparente. El driver `SQL Server` lee un `()` vacío como una lista de
argumentos **presente** y rechaza la llamada:

```
37000 (8146) Procedure … has no parameters and arguments were supplied.
```

El mensaje miente —no se envió ningún argumento— y cuesta caro de diagnosticar.
Emitir la sintaxis nativa quita esa capa de interpretación, y es además lo que
pide la regla de que toda diferencia entre motores viva en `dialect/`.

### 3.5 Paginación y sondeo

| | SQL Server | HANA |
|---|---|---|
| Paginación | `OFFSET n ROWS FETCH NEXT m ROWS ONLY` | `LIMIT m OFFSET n` |
| `ORDER BY` | **obligatorio** — sin él no compila | opcional (se avisa en el log) |
| Sondeo | `SELECT 1` | `SELECT 1 FROM DUMMY` |

`SELECT 1` a secas, válido en SQL Server, en HANA es **error de sintaxis**: exige
`FROM`, y `DUMMY` es su tabla de una sola fila (el `dual` de Oracle).

El `ORDER BY` se exige en SQL Server porque la sintaxis no compila sin él, pero
el otro motivo aplica a los dos motores: sin un orden determinista, dos páginas
consecutivas pueden repetir u omitir filas.

---

## 4. Uso

```ruby
ExternalDb::Pool.with('DOCS_DB_ODBC') do |client|
  # SELECT parametrizado
  filas = client.select(
    'SELECT Id, Numero, Total FROM Documentos WHERE Fecha >= ? AND Estado = ?',
    [desde, 'abierto']
  )

  # Página
  pagina = client.select_page(
    'SELECT Id, Numero FROM Documentos ORDER BY Id',
    limit: 50, offset: 100
  )

  # Un solo valor
  total = client.select_value('SELECT COUNT(*) FROM Documentos')

  # Procedimiento almacenado
  filas = client.call('SP_DOCS_POR_FECHA', [desde, hasta])
end
```

`Pool.with` entrega un cliente conectado y lo devuelve al pool al salir del
bloque. `#select` devuelve un arreglo de hashes con los nombres de columna tal
como los da la base.

### 4.1 Los valores van SIEMPRE como parámetros

La sentencia lleva `?` y los valores van aparte. El driver los manda tipados y
fuera del texto de la consulta, así que no hay forma de que un valor se
interprete como SQL. `?` es el placeholder de ODBC y **funciona igual en los dos
drivers** — no hay que traducirlo por motor.

```ruby
# ✅ CORRECTO
client.select('SELECT * FROM docs WHERE id = ?', [params[:id]])

# ❌ INYECCIÓN
client.select("SELECT * FROM docs WHERE id = #{params[:id]}")
```

No hay ninguna API que reciba solo un string y lo ejecute sin pasar por el guard.
El **nombre del procedimiento** en `#call` sí se intercala en el texto —un
identificador no puede ir como parámetro—, y por eso se valida contra la forma de
un identificador antes de armar la sentencia.

### 4.2 Verificar la conexión

```ruby
resultado = ExternalDb::HealthCheck.call('DOCS_DB_ODBC')

resultado.ok?        # => true
resultado.engine     # => "HANA"
resultado.version    # => "2.00.075.00.1735196404"
resultado.latency_ms # => 42
resultado.message    # => "La conexión a la base de documentos responde."
```

**Nunca levanta.** Los cuatro modos de falla —falta un ajuste, el driver no está,
el servidor no responde, las credenciales son malas— terminan en un `Result` con
`ok: false` y un mensaje en español, porque para el operador todos significan
"no se pudo" y lo que necesita es el motivo. Mismo criterio que
`Sap::CredentialValidator`.

Corre **dos** sentencias: el sondeo confirma que la sesión responde, y la de
versión confirma que además se puede leer del catálogo del sistema — que es lo
que falla cuando el usuario conectó pero no tiene permisos.

### 4.3 Errores

| Clase | Cuándo | HTTP | ¿Se muestra? |
|---|---|---|---|
| `ConfigurationError` | Falta o está mal un ajuste | 422 | Sí, nombra el `code` |
| `ConnectionError` | No se llegó al servidor | 502 | Sí |
| `QueryError` | La base rechazó la consulta | 502 | Sí |
| `ReadOnlyViolation` | Se intentó escribir | 500 | **No** — es un bug |

`ExternalDb::Error` es la base y rescata las cuatro.

Los mensajes del driver se limpian antes de propagarse
(`Client#sanitize`): un error de ODBC viene como
`[unixODBC][Microsoft][ODBC Driver 17 for SQL Server]Login failed for user 'x'.`
y los corchetes son la cadena de capas que lo reportó, no información. Además se
tapa la contraseña por si el driver hizo eco de la cadena de conexión.

---

## 5. ⚠️ Solo lectura — hasta dónde llega la garantía

Esto hay que leerlo completo antes de confiar en el conector, porque es fácil
sobreestimar lo que garantiza.

### Lo que el código hace

| Defensa | Qué cubre |
|---|---|
| `StatementGuard` | La sentencia tiene que abrir con `SELECT`/`WITH`; rechaza verbos de escritura en cualquier posición y más de una sentencia |
| Sin `#execute` | La API pública no tiene ningún método que ejecute DML. `#select` pasa por el guard; `#call` invoca procedimientos |
| `autocommit = false` + `rollback` | Cada sentencia termina en rollback. Si algo llegó a modificar, se deshace |
| `maxrows` + tope en `#collect` | 10 000 filas, para que un `SELECT` sin `WHERE` no se traiga una tabla entera a la memoria del proceso |
| `timeout` | Una consulta colgada no retiene la conexión del pool para siempre |

El guard limpia comentarios y literales antes de buscar verbos, así que
`-- update esto luego` y una columna `UPDATED_BY` no dan falso positivo.

### Lo que NO cubre

1. **`ruby-odbc` no expone `SQL_ATTR_ACCESS_MODE`** — verificado: la gema define
   `SQL_AUTOCOMMIT` pero ninguna constante de access mode. La conexión **no se
   puede abrir en modo lectura**. Y aunque se pudiera, el atributo es una
   sugerencia que la mayoría de los drivers ignora.
2. **`WITH` puede llevar DML.** En SQL Server,
   `WITH c AS (SELECT…) DELETE FROM c` es válido y empieza con `WITH`. Por eso los
   verbos se buscan en cualquier posición — pero es un chequeo textual, no un
   parser.
3. **Un procedimiento almacenado hace lo que quiera.** `#call` los invoca, y desde
   la app no hay forma de saber si el procedimiento lee o escribe. `#call` **no
   pasa por el guard**.
4. **Falso positivo asumido:** un `;` dentro de un literal
   (`WHERE nombre = 'a;b'`) se rechaza. Se prefirió así porque los valores viajan
   como parámetros, y un literal con `;` es más probable que sea un intento de
   inyección que un dato.

### 🔒 La garantía real: los permisos del usuario de base de datos

> **El usuario de `DOCS_DB_ODBC_USER` tiene que tener permisos de LECTURA Y NADA
> MÁS.** Es lo único que un procedimiento almacenado no puede eludir, y es lo que
> hay que verificar al desplegar.

> ⚠️ **Con `DOCS_DB_ODBC_TRUSTED` activo, el usuario NO es el de la pantalla.** La
> conexión se autentica con la identidad de Windows del proceso Rails: la cuenta
> del servicio en el servidor, la del programador en desarrollo. El `GRANT` hay
> que dárselo a **esa** cuenta, y cambiar la cuenta del servicio cambia con qué
> credenciales se conecta la aplicación sin que la pantalla se vea distinta.
> `DOCS_DB_ODBC_USER` y `_PASSWORD` quedan sin usar — el driver los ignora, así
> que la cadena de conexión ni siquiera los manda.

```sql
-- SQL Server
CREATE LOGIN fec_ro WITH PASSWORD = '…';
CREATE USER  fec_ro FOR LOGIN fec_ro;
ALTER ROLE db_datareader ADD MEMBER fec_ro;
-- y NADA de db_datawriter / db_owner
GRANT EXECUTE ON SCHEMA::dbo TO fec_ro;   -- solo si hay procedimientos que invocar
```

```sql
-- SAP HANA
CREATE USER FEC_RO PASSWORD "…" NO FORCE_FIRST_PASSWORD_CHANGE;
GRANT SELECT ON SCHEMA CL_DOCS TO FEC_RO;
-- y NADA de INSERT / UPDATE / DELETE
GRANT EXECUTE ON CL_DOCS.SP_DOCS TO FEC_RO;   -- procedimiento por procedimiento
```

`GRANT EXECUTE` merece cuidado: un procedimiento corre con sus propios permisos
(`SECURITY DEFINER` en HANA, encadenamiento de propiedad en SQL Server), así que
puede escribir aunque el usuario que lo llama no pueda. **Conceder `EXECUTE`
procedimiento por procedimiento, nunca sobre el esquema completo en HANA**, y
revisar qué hace cada uno antes de habilitarlo.

---

## 6. El pool

`ExternalDb::Pool` mantiene hasta 5 conexiones por destino (el default de
`RAILS_MAX_THREADS`). Abrir una conexión ODBC no es gratis —handshake,
autenticación y, en HANA, negociación de sesión— y Puma corre varios hilos.

**La configuración puede cambiar mientras la app corre**, y eso es la diferencia
con un pool de config estática: el operador edita `DOCS_DB_ODBC_SERVER` desde la
pantalla y las conexiones ya abiertas siguen apuntando al servidor anterior.
Nadie notaría que el cambio no tuvo efecto hasta reiniciar.

Por eso el pool se indexa por `Config#fingerprint`, que es un hash de **todos**
los ajustes del grupo **incluida la contraseña**. Cuando cambia cualquiera, el
fingerprint cambia, se arma un pool nuevo y el viejo se cierra con `shutdown`,
que desconecta cada conexión en vez de dejarlas colgadas del lado del servidor.

El fingerprint es un hash y no los valores porque termina como llave de un hash
en memoria y en mensajes de log: no tiene por qué llevar el secreto adentro.

```ruby
ExternalDb::Pool.stats      # { "DOCS_DB_ODBC" => { size: 5, available: 4 } }
ExternalDb::Pool.shutdown!  # cierra todo (tests, before_fork del servidor)
```

El `Config` se resuelve en **cada** llamada a `Pool.with` —un SELECT sobre un
índice único—, y eso es lo que permite notar el cambio. Lo que no se rearma en
cada llamada es la conexión.

---

## 7. La gema

```ruby
# Gemfile
gem 'ruby-odbc', '~> 0.99999', require: false
gem 'connection_pool', '~> 3.0'
```

**`require: false` a propósito.** Es una extensión nativa enlazada contra el
driver manager del sistema, y una instalación de ODBC rota no tiene por qué
tumbar el boot de toda la app. La carga `ExternalDb::Client.require_odbc!` cuando
se va a usar, así el fallo sale como un error del módulo de documentos y no como
una pantalla en blanco.

`connection_pool` se declara explícito aunque ya entrara como dependencia
transitiva de `solid_cache`: la app la usa directo, y si esa gema deja de traerla
el fallo aparecería como un `NameError` en la primera consulta.

### Compilación en Windows

`ruby-odbc` es una extensión nativa. Necesita el toolchain MSYS2 de
RubyInstaller, que en este servidor ya está:

```powershell
$env:PATH = "$env:USERPROFILE\Ruby33-x64\msys64\ucrt64\bin;$env:PATH"
gem install ruby-odbc --no-document
```

Verificado en este servidor: gcc 16.1.0 (UCRT64), headers `sql.h` / `sqlext.h` /
`sqltypes.h` presentes, `ruby-odbc-0.999993` compilada. Ruby es `x64-mingw-ucrt`,
así que el toolchain correcto es **ucrt64**, no mingw64.

---

## 8. Archivos

| Archivo | Estado |
|---|---|
| `db/migrate/20260821120000_create_settings.rb` | Nuevo |
| `db/setting_code_map.yml` | Nuevo — equivalencia con los `code` del .NET |
| `db/seeds.rb` | Modificado (sección 6: 13 ajustes en 3 grupos) |
| `app/models/setting.rb` | Nuevo |
| `app/services/external_db/error.rb` | Nuevo — base de la jerarquía |
| `app/services/external_db/configuration_error.rb` | Nuevo |
| `app/services/external_db/connection_error.rb` | Nuevo |
| `app/services/external_db/query_error.rb` | Nuevo |
| `app/services/external_db/read_only_violation.rb` | Nuevo |
| `app/services/external_db/config.rb` | Nuevo — destino armado desde `settings` |
| `app/services/external_db/dialect.rb` | Nuevo — resolución del dialecto |
| `app/services/external_db/dialect/base.rb` | Nuevo — contrato + `build_dsn` |
| `app/services/external_db/dialect/sql_server.rb` | Nuevo |
| `app/services/external_db/dialect/hana.rb` | Nuevo |
| `app/services/external_db/statement_guard.rb` | Nuevo — red de solo lectura |
| `app/services/external_db/client.rb` | Nuevo — conexión y consulta |
| `app/services/external_db/pool.rb` | Nuevo |
| `app/services/external_db/health_check.rb` | Nuevo |
| `config/locales/es.yml` | Modificado (§30: modelo, atributos, `invalid_format`) |
| `Gemfile` | Modificado (`ruby-odbc`, `connection_pool`) |
| `spec/factories/settings.rb` | Nuevo |
| `spec/models/setting_spec.rb` | Nuevo |
| `spec/services/external_db/config_spec.rb` | Nuevo |
| `spec/services/external_db/dialect_spec.rb` | Nuevo |
| `spec/services/external_db/statement_guard_spec.rb` | Nuevo |

**Una constante de error por archivo** porque lo exige Zeitwerk: cinco constantes
en `error.rb` hacen que solo `ExternalDb::Error` se resuelva y las demás fallen
con `NameError` en tiempo de ejecución. Es la misma convención de
`Certificates::Error` / `CompanyFiles::Error`.

---

## 9. Pruebas

**94 ejemplos nuevos, 543 en la suite completa, 0 fallas.**

| Archivo | Ejemplos | Qué fija |
|---|---|---|
| `spec/models/setting_spec.rb` | 25 | Convención del `code`, unicidad con soft delete, cifrado no determinista, `is_visible`, `.value_for`, `.group`, `#update_value!` |
| `spec/services/external_db/config_spec.rb` | 19 | Ajustes faltantes listados juntos, puerto obligatorio en HANA, driver contra los instalados, fingerprint |
| `spec/services/external_db/dialect_spec.rb` | 27 | Las dos cadenas de conexión completas, calificación, `{CALL}`, paginación, sondeo |
| `spec/services/external_db/statement_guard_spec.rb` | 23 | Qué pasa, qué se rechaza, y **qué no atrapa** |

Lo que **no** está cubierto por specs es la conexión real: `Client#connect` y el
pool necesitan un servidor de base al otro lado. Para eso está
`ExternalDb::HealthCheck`, que es lo primero que hay que correr después de
configurar el grupo.

Dos bugs que los specs encontraron antes de que llegaran a producción, los dos en
la cadena de conexión:

1. **`Driver={{ODBC Driver 17…}}}`** — el dialecto ponía las llaves y `build_dsn`
   las ponía otra vez.
2. **`Driver={ODBC Driver 17 for SQL Server`** — sin llave de cierre. La versión
   interpolada (`"{#{v.gsub('}', '}}')}}"`) necesita **dos** `}` finales, uno
   cierra la interpolación y el otro es el literal; con uno solo la llave
   desaparece. Ahora se arma con concatenación explícita, que no se puede leer
   mal.

Ninguno de los dos habría dado un error entendible: el driver manager habría
respondido "Data source name not found".

---

## 10. Lo que falta

**No se tocó la interfaz.** El módulo Configuraciones → Generales
(`/configurations/general`) sigue leyendo `/api/settings` del .NET por proxy.

| Pendiente | Detalle |
|---|---|
| `Api::SettingsController` | `GET /api/settings` y `PATCH /api/settings/:code` nativos. El `code` va en la URL, no en el cuerpo (`CLAUDE.md` §28) |
| Serialización | Respetar `is_visible`: devolver `Value: nil` + `HasValue: true` para los ocultos |
| Migrar la pantalla | `general_configs_controller.js` lee `s.Json` — pasa a `Value`. Los `code` cambian a la convención nueva |
| Botón "Probar conexión" | Sobre `ExternalDb::HealthCheck` |
| Permiso | Falta el que gatee la edición de ajustes; hoy la pantalla usa `Configurations_General_Access` |
| Importación | La tarea que trae los `Setting` del .NET traduciendo por `db/setting_code_map.yml` |
| Cerrar el pool | `Pool.shutdown!` en el `before_fork`/`on_worker_shutdown` de Puma, para no dejar sesiones colgadas del lado de la base |

Las entradas correspondientes están en `TODOS.md` → *Ajustes de la instalación* y
*Base de documentos*.

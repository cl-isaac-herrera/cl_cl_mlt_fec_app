# Schemas de estructura de SAP (UDTs y UDFs)

Cada `*.json` de esta carpeta declara la estructura que este producto necesita en SAP, y
la aplican las rake tasks del submódulo `sap_udfs`
(`rake "sap:schema:diff[…]"` → `rake "sap:schema:sync[…]"`). Las reglas de la convención
—`IsUDT`, el `@` del `table_name`, el `U_` que NO se escribe, `FEC ·` en la descripción,
por qué `diff` va siempre antes de `sync`— viven en `CLAUDE.md` §32 y no se repiten acá.

Este archivo documenta lo otro: **los límites de largo que impone SAP** y **qué está
declarado dos o más veces**, adentro de esta carpeta y afuera, para que un cambio no quede
aplicado a medias.

Los manifiestos de **borrado** van en `delete/` y tienen su propio README.

## Inventario

| Schema | Objeto en SAP | UDT | Qué guarda |
|---|---|---|---|
| `marketing_documents.json` | `OINV` — SAP replica solo al resto del grupo Documentos de Marketing (`ORIN`, `OPCH`, …) | no | Los 7 UDFs `CL_FEC_*` del comprobante electrónico. |
| `payments.json` | `ORCT` | no | Los **mismos** 7 UDFs: `ORCT` es categoría Banking y NO recibe la replicación de `OINV`. |
| `outgoing_mails_udt.json` | `@CL_FEC_MAILSQUEUE` | sí | Detalle del correo de recepción electrónica (destinatarios, remitente, estado del envío). La escribe `Sap::MailQueue`. |
| `doc_sync_attempts_udt.json` | `@CL_FEC_DOCSYNCATTMP` | sí | Historial de intentos de sincronización de un documento: con qué estado terminó cada intento y por qué. La escribe y la lee `Sap::DocSyncAttempts`. |
| `sucursales_udt.json` | `@CL_FEC_SUCURSALES` | sí | Sucursales del emisor ante Hacienda. |

## Límites de largo — los pone SAP, no son estilo

| Qué | Campo del schema | Máximo |
|---|---|---|
| Nombre de la UDT | `table_name`, **sin** el `@` | **19** caracteres |
| Descripción de la UDT | `table_description` | **30** caracteres |
| Nombre de un UDF | `Name` de la columna, **sin** el `U_` | **50** caracteres |
| Descripción de un UDF | `Description` de la columna | **50** caracteres |

Pasarse no es un detalle cosmético: SAP no acepta el objeto, así que
`rake sap:schema:sync` lo reporta como fallido y —al ser todo-o-nada— **no escribe el
`config/sync.lock`**, con lo que la corrida entera queda sin marcar como sincronizada
(`CLAUDE.md` §32). Y el error aparece recién contra SAP real: `diff` sobre un objeto que
todavía no existe no tiene con qué comparar el largo.

### Consecuencias prácticas al nombrar

- **El nombre de UDT es el que aprieta.** El prefijo de la convención `CL_<PRODUCTO>_<MODULO>`
  ya gasta 7 (`CL_FEC_`), así que para el módulo quedan **12**. `CL_FEC_MAILSQUEUE` (17) y
  `CL_FEC_SUCURSALES` (17) entran; un nombre "descriptivo" como
  `CL_FEC_DOCSYNCATTEMPTS` (22) no — hay que abreviar el módulo, no el prefijo.
- **La descripción de UDT es el otro cuello:** 30 caracteres, y el `FEC · ` obligatorio se
  lleva 6. Quedan 24 para decir qué guarda la tabla.
- **En el UDF sobra nombre y falta descripción.** 50 caracteres de nombre nunca molestaron
  (el más largo del producto anda en 21), pero 50 de descripción se agotan rápido: con los
  6 del prefijo, quedan 44 útiles.
- **Se cuentan caracteres, no bytes.** `·`, las tildes y las eñes valen 1 aunque en UTF-8
  ocupen 2. Igual conviene no apurar el margen.

> ⚠️ `CLAUDE.md` §32 pide descripciones de UDF de **hasta 60** caracteres, tomado del
> estándar de nomenclatura de Clavisco (§6.2). Cuando los dos números choquen manda el de
> SAP: **50**. El estándar define el estilo (`FEC · propósito`, en español, sin repetir el
> nombre técnico); el límite físico lo pone el motor.

### Cómo verificar antes de correr `sync`

```bash
ruby -rjson -e '
Dir["config/sap_schemas/*.json"].sort.each do |file|
  s = JSON.parse(File.read(file))
  t = s["table_name"].to_s.delete_prefix("@")
  d = s["table_description"].to_s
  if s["IsUDT"]
    puts "#{file}: UDT #{t} (#{t.length} > 19)"        if t.length > 19
    puts "#{file}: desc. UDT (#{d.length} > 30)"       if d.length > 30
  end
  (s["columns"] || []).each do |c|
    puts "#{file}: #{c["Name"]} nombre (#{c["Name"].length} > 50)"           if c["Name"].length > 50
    puts "#{file}: #{c["Name"]} desc. (#{c["Description"].to_s.length} > 50)" if c["Description"].to_s.length > 50
  end
end'
```

Sin salida, todo entra. Los manifiestos de `delete/` no se revisan: nombran objetos que ya
existen.

## 1. El catálogo de estados del documento aparece en CUATRO lados

`dbo.StatusCodes` (`db/external/sql_server/schema.sql`) es **la fuente de verdad**: la
columna `DocumentsQueue.StatusCode` tiene una llave foránea contra esa tabla, y el resto
son copias que hay que mantener alineadas a mano.

| Dónde | Campo | Valores declarados hoy |
|---|---|---|
| `db/external/sql_server/schema.sql` | `dbo.StatusCodes` (tabla + FK) | 0, 2, 3, 4, 6, 7, 8 |
| `app/services/documents/pending_queue.rb` | `STATUS_*` | los 7 |
| `marketing_documents.json` | `CL_FEC_Status` → `ValidValues` | 0, 3, 4, 6, 7, **8** — sin el 2 |
| `payments.json` | `CL_FEC_Status` → `ValidValues` | idem, sin el 2 |
| `doc_sync_attempts_udt.json` | `Status` → `ValidValues` | los 7, **con** el 2 |

### Por qué el 2 (`Processing`) está en la UDT y no en el UDF del documento

El UDF vive **en el comprobante** y dice cómo quedó: `Processing` es la marca transitoria
con la que `CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS` reclama la fila, no un desenlace, y
publicarla en el documento solo agregaría un estado que aparece y desaparece.

La UDT es distinta: es el **historial de intentos**, así que declara el catálogo completo
—los 7 valores que `dbo.StatusCodes` tiene hoy— y puede registrar un intento que quedó en
cualquier estado, incluido el transitorio.

### Checklist al AGREGAR un estado

1. `INSERT` en `dbo.StatusCodes` (`db/external/sql_server/schema.sql`) y su espejo en
   `db/external/hana/schema.sql`.
2. La constante `STATUS_*` en `app/services/documents/pending_queue.rb`.
3. `ValidValues` de `Status` en **`doc_sync_attempts_udt.json`** — siempre, porque acá el
   catálogo va completo.
4. `ValidValues` de `CL_FEC_Status` en **`marketing_documents.json` Y `payments.json`** —
   los dos o ninguno (ver §2) — **solo si el estado es un desenlace visible en el
   comprobante**. Un estado transitorio como `Processing` se queda fuera, a propósito.
5. `rake "sap:schema:diff[…]"` y después `sync` contra **cada instalación viva**: el JSON
   no se aplica solo, y hasta que corra, SAP rechaza el valor nuevo ("campo inválido") en
   el primer `PATCH` que lo mande.

### Checklist al QUITAR un estado

Igual que arriba, en el mismo orden, con dos avisos:

- **Las filas que ya lo tienen guardado no se limpian solas.** Sacar un valor de
  `ValidValues` no toca los documentos ni las filas de la UDT que quedaron con él: el
  valor sigue ahí y ninguna pantalla sabe cómo llamarlo. Decidir a qué estado se migran
  **antes** de quitarlo.
- **`dbo.StatusCodes` es lo último que se toca:** la FK de `DocumentsQueue.StatusCode`
  impide borrar la fila del catálogo mientras un documento la esté usando — y eso es una
  protección, no un estorbo.

`Description` de cada `ValidValues` es el nombre en inglés del catálogo
(`dbo.StatusCodes.Name`: `Pending`, `Sent`, `Error`, …), no una traducción: es lo que
permite reconocer de un lado y del otro que se trata del mismo estado. La traducción al
español la pone la pantalla.

## 2. Los 7 UDFs del comprobante están DUPLICADOS en dos schemas

`marketing_documents.json` (`OINV`) y `payments.json` (`ORCT`) declaran **exactamente los
mismos** campos: `CL_FEC_FechaEmision`, `CL_FEC_Status`, `CL_FEC_ErrorDetails`,
`CL_FEC_Clave`, `CL_FEC_NumConsecutivo`, `CL_FEC_XmlSentUrl`, `CL_FEC_XmlResponseUrl`.

No es un descuido ni se puede unificar: SAP replica un UDF solo entre las tablas de una
**misma** categoría, y Documentos de Marketing (`OINV` y sus ~32 hermanas) y Banking
(`ORCT`) son categorías distintas. Por eso `ORIN`/`OPCH` no necesitan schema y `ORCT` sí.

> **Regla:** todo cambio en uno de esos 7 campos —tamaño, descripción, `ValidValues`— va
> en **los dos archivos**, en el mismo cambio. Verificar con
> `grep -l CL_FEC_Status config/sap_schemas/*.json`.

## 3. El catálogo de estados del correo también está en dos lados

| Dónde | Campo | Valores |
|---|---|---|
| `db/external/sql_server/schema.sql` | `CK_OutgoingMailsQueue_Status` (CHECK) | 1, 2, 3, 4, 5 |
| `app/services/documents/mail_queue.rb` | `STATUS_*` | los 5 |
| `outgoing_mails_udt.json` | `Status` → `ValidValues` | los 5, en español |

Es el mismo reparto que el del documento —la base externa decide **cuándo** reintentar, la
UDT guarda **qué pasó**— y el mismo cuidado: agregar un estado obliga a tocar el CHECK, la
constante y el `ValidValues`. En una instalación viva el CHECK necesita un `ALTER` a mano
(anotado en `TODOS.md`).

`U_Type` (1 Envío / 2 Reenvío) es el único catálogo que existe **solo** en la UDT.

## 4. `DocEntry` + `DocType` es la llave del documento en las dos UDTs

`@CL_FEC_MAILSQUEUE` y `@CL_FEC_DOCSYNCATTMP` identifican el documento con el par
`U_DocEntry` + `U_DocType`, y nunca con el `Id` de la cola externa: ese `Id` es de otra
base y adentro de SAP no se puede resolver. `SAPDB` tampoco viaja — la compañía la
determina la base de SAP contra la que se consulta.

`DocType` es `db_Alpha(2)` con los códigos de `dbo.DocTypes` (`01`, `02`, `03`, `04`,
`08`, `09`, `10`), el mismo catálogo que `app/models/doc_type.rb`. Un tipo nuevo se agrega
en los tres lados; el `Size` de 2 no se toca.

## 5. Las fechas son `db_Alpha(25)` con ISO 8601, nunca `db_Date`

`CL_FEC_FechaEmision`, `U_CreatedAt` y `U_LastAttempt` son texto de 25 caracteres con la
fecha en ISO 8601 (`2026-09-10T14:03:12-06:00`). Hace falta la hora y el offset —los dos
importan para Hacienda y para ordenar intentos del mismo día—, y así el valor viaja igual
entre Rails, el Service Layer y la pantalla, sin que ninguna capa lo reinterprete.

`Size: 25` es el largo de esa cadena: no bajarlo (`Size` solo se puede incrementar, §32).

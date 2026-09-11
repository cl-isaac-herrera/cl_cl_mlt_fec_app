# Manifiestos de borrado de estructura en SAP

Cada archivo `*.json` de esta carpeta nombra **explícitamente** los UDFs o UDTs que se
quitaron de SAP. Los consume `rake "sap:schema:delete[<manifiesto>,<conexiones>]"`.

> ⚠️ Los manifiestos **NO van en `config/sap_schemas/` a secas**, solo acá dentro. El
> `sync`/`diff` hace glob de `config/sap_schemas/*.json` (un nivel, no recursivo) y
> trataría un manifiesto como si fuera un schema de creación, fallando para siempre en
> cada corrida posterior.

## Hoy esta carpeta está vacía, y es a propósito

Todavía no hay ninguna instalación con estos schemas creados en SAP. Un manifiesto de
borrado sirve para dos cosas —comprobar si algo sigue en SAP y dejar el rastro de qué se
quitó y cuándo—, y **las dos suponen que el borrado ocurrió en algún lado**. Sin clientes,
no documenta nada: es un archivo que describe una limpieza que nadie necesitó correr.

Por eso, mientras eso siga así, un campo que sale de un schema sale también sin dejar
manifiesto detrás.

### Cuándo cambia

Desde la primera instalación en productivo. Ahí sí se conservan después de usarlos:
`delete_field` / `delete_table` reportan `:not_found` en vez de fallar cuando el objetivo ya
no existe, así que volver a correr un manifiesto viejo siempre es seguro, y pasa a ser la
única constancia de qué estructura se quitó de las bases de los clientes.

## Convenciones

- El nombre del campo va **sin** el prefijo `U_`: la herramienta filtra
  `UserFieldsMD` por `Name`, que es como SAP lo guarda (`CL_FEC_EmsrNombre`, no
  `U_CL_FEC_EmsrNombre`).
- `table_name` se escribe igual que en los schemas: con `@` para una UDT propia, pelado
  para una tabla nativa de SAP (`OADM`, `OPCH`).
- Cada ítem lleva **exactamente uno** de `delete_fields` (arreglo de nombres) o
  `delete_table: true` (solo válido si `table_name` empieza con `@`).

## Es irreversible y pide confirmación

La tarea es interactiva: exige escribir el nombre exacto de cada objetivo antes de
borrarlo, y **nunca toca el `config/sync.lock`**. Borrar un UDF se lleva los datos de esa
columna en todas las filas de la tabla, en cada compañía del archivo de conexiones.

## Un caso que va a volver: cambiar el `Type` de un UDF

SAP no deja cambiar el `Type` de un UDF existente (ODBC -1029), así que la salida no es
editar el schema y correr `sync` —el campo queda en `update_failed` y encima no se escribe
el `config/sync.lock`— sino **borrar para recrear**: un manifiesto que quita el campo, y
después `sync`, que lo vuelve a crear con el tipo nuevo.

Ya pasó una vez, con `Email` de la UDT de correos (pasó de `db_Memo` a `db_Alpha(160)`:
guarda un remitente, no el cuerpo del correo). Se resolvió así y el manifiesto se borró
después, por lo de arriba. El `Size`, en cambio, sí se puede aumentar por `PATCH` — nunca
reducir.

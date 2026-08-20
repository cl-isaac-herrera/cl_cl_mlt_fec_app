# Manifiestos de borrado de estructura en SAP

Cada archivo `*.json` de esta carpeta nombra **explícitamente** los UDFs o UDTs que se
quitaron de SAP. Los consume `rake "sap:schema:delete[<manifiesto>,<conexiones>]"`.

> ⚠️ Los manifiestos **NO van en `config/sap_schemas/` a secas**, solo acá dentro. El
> `sync`/`diff` hace glob de `config/sap_schemas/*.json` (un nivel, no recursivo) y
> trataría un manifiesto como si fuera un schema de creación, fallando para siempre en
> cada corrida posterior.

## Por qué se conservan después de usarlos

`delete_field` / `delete_table` reportan `:not_found` en vez de fallar cuando el objetivo
ya no existe, así que volver a correr un manifiesto viejo siempre es seguro. Sirven de dos
cosas: comprobar si algo sigue en SAP, y dejar el rastro de qué se borró y cuándo.

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

## Historial

| Manifiesto | Qué quitó | Por qué |
|---|---|---|
| `oadm_company_config.json` | Los 10 UDFs `CL_FEC_*` de `OADM` | La configuración de FE de la compañía pasó a vivir en la base de la aplicación (tabla `companies`), no en SAP. |

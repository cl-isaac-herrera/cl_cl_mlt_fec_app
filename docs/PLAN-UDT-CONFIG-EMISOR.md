# Plan de impacto — mover la configuración del emisor de `companies` a una UDT de SAP

> **Estado: PLANIFICADO, sin una línea de código escrita.** Redactado el 2026-09-12.
> Nada de lo que sigue está aplicado: `companies` conserva las seis columnas y ningún
> flujo habla con la UDT. Para retomar, ver **§7 Dónde retomar mañana**.

## 0. Qué se pidió

Mover seis campos de `companies` a una UDT de SAP:

| Columna hoy (SQLite) | Nombre en la UDT | Nota |
|---|---|---|
| `name` | `CommercialName` | **NO se elimina de SQLite** — sigue siendo el display name de la aplicación |
| `issuer_legal_name` | `LegalName` | |
| `issuer_id_type` | `IdType` | |
| `issuer_id_number` | `IdNumber` | ⚠️ ver §1 — es componente de ruta |
| `economic_activity_code` | `EconomicActivityCode` | |
| `tax_registry_8707` | `TaxRegistry8707` | |

## 0.1 ⚠️ Advertencia previa — esto revierte una decisión documentada

Estos mismos seis campos **ya vivieron en SAP** como UDFs sobre `OADM` y se trajeron a
`companies` en `db/migrate/20260819130000_add_issuer_fields_to_companies.rb`. El caso está
escrito como advertencia en `CLAUDE.md` §32 y repetido en el comentario de
`Api::CompaniesController#show`.

El argumento que los mató **no era "UDF vs UDT"** sino *«SAP no lee este dato»*: son
parámetros de la facturación electrónica de Costa Rica que solo consume este producto, así
que el campo en SAP no deduplicaba nada — era la única copia, alojada en el sistema
equivocado. Una UDT tampoco los lee.

Los tres costos que se citaron en esa reversión reaparecen idénticos:

1. una vuelta al Service Layer para pintar un formulario,
2. credenciales de SAP obligatorias para abrir la pantalla,
3. validación imposible del lado del modelo.

Queda dicho una vez. El resto del documento asume que la decisión está tomada.

---

## 1. El bloqueo real: `issuer_id_number` es una RUTA, no un campo

Es el punto que decide la forma de todo lo demás. Hoy la cédula del emisor es **componente
de path** en dos lugares:

| Dónde | Qué arma | Cuándo corre |
|---|---|---|
| `app/services/company_files/store.rb:159` (`#directory`) | `{FILES_BASE_PATH}/{cédula}/` — carpeta del `.p12`, el logo y el `.rpt` (`CLAUDE.md` §34) | Al subir un archivo, **dentro del request** |
| `app/services/documents/xml_archive.rb:119` (`#id_number`) | Path del blob en Azure de cada XML | En **cada emisión** |

Consecuencias que no se pueden esquivar:

- Subir un certificado pasa a requerir una vuelta al Service Layer **antes de escribir el
  archivo**. Si SAP no responde, no se puede guardar ni un logo.
- Si alguien edita `IdNumber` en la UDT desde SAP, los archivos ya escritos quedan
  huérfanos en silencio: `cert_path` guarda la ruta absoluta, así que los viejos siguen
  abriendo, pero todo lo nuevo va a otra carpeta. El servicio de firma del .NET abre el
  `.p12` **por ruta** — nadie se entera hasta que una compañía deja de emitir.
- `Sap::CompanyClient.for` exige conexión + `sap_db` + credenciales de licencia. Una
  compañía a la que todavía no se le asignó conexión **no podría subir archivos ni
  emitir**, porque no se puede leer su propia cédula.

> **Recomendación:** `issuer_id_number` se conserva además en SQLite como **columna espejo
> de solo lectura**, escrita por el mismo PATCH que escribe la UDT. La UDT es la fuente de
> verdad para el usuario; la columna es el índice local que permite derivar rutas sin
> depender de SAP. Es el mismo trato que ya recibe `name`.

---

## 2. Diseño propuesto

### 2.1 El schema (`CLAUDE.md` §32)

Nuevo `config/sap_schemas/company_config_udt.json`. **Una sola fila por base de SAP** (cada
compañía es su propia `sap_db`), `bott_NoObjectAutoIncrement`, `Code` fijo (`'1'`):

```
@CL_FEC_COMPANYCONFIG          FEC · Configuración del emisor de FE
  CommercialName        db_Alpha  80   FEC · Nombre comercial del emisor
  LegalName             db_Alpha 100   FEC · Razón social del emisor ante Hacienda
  IdType                db_Alpha   2   FEC · Tipo de identificación del emisor
                                       + ValidValues 01 / 02 / 03 / 04
  IdNumber              db_Alpha  20   FEC · Número de identificación del emisor
  EconomicActivityCode  db_Alpha   6   FEC · Código de actividad económica
  TaxRegistry8707       db_Alpha  12   FEC · Registro fiscal de la ley 8707
```

- Los `Size` salen de los `limit:` actuales de `db/schema.rb` — ya están alineados con lo
  que acepta el esquema 4.4 de Hacienda. Ojo con `IdNumber`: son **20**, no 12; subió
  porque el `Size` del UDF viejo no alcanzaba para DIMEX ni NITE
  (`20260901120000_tighten_company_identity_limits.rb`).
- `ValidValues` de `IdType` replica `Company::ISSUER_ID_TYPES` (`%w[01 02 03 04]`).
- Descripciones con el prefijo `FEC ·`, en español, ≤60 caracteres (§32).
- Actualizar el checklist de `config/sap_schemas/README.md`.

> ⚠️ **Verificar primero si alguna instalación viva todavía tiene los `U_CL_FEC_*` de
> `OADM`.** Si el `rake sap:schema:delete` de aquella tanda nunca corrió contra ella, van a
> convivir dos copias del mismo dato. `config/sap_schemas/delete/` está vacía hoy.

### 2.2 El catálogo `sl_resources`

Bloque nuevo `SL_RESOURCES_COMPANY_CONFIG` en `db/seeds.rb`, siguiendo el patrón de
`SL_RESOURCES_DOC_SYNC_ATTEMPTS` (línea ~892): un código de lectura (`getCompanyConfig`) y
uno de escritura (`updateCompanyConfig`), contra el entity set `U_CL_FEC_COMPANYCONFIG`.

**Más una migración de datos** que inserte esas dos filas en instalaciones ya sembradas:
`db:seed` completo contra una base viva borra las asignaciones de permisos (`CLAUDE.md`
§36). Patrón de referencia: `20260911150000_rename_mail_udt_sl_resources.rb`.

### 2.3 El servicio

Nuevo `app/services/sap/company_config.rb`, modelado sobre
`app/services/sap/doc_sync_attempts.rb`: `Sap::CompanyClient` + `Sap::ResourceQuery`, nunca
HTTP a mano (`CLAUDE.md` §29). Expone `read(company)` → `Data` y `update(company, attrs)`.

**Necesita caché por request / por job.** `Documents::UnifiedBuilder` toca estos campos en
5 puntos por documento; sin memoización son 5 vueltas al Service Layer por comprobante, y
`SyncIssuedDocumentsJob` procesa en lote.

---

## 3. Tabla de impacto

| Archivo | Qué cambia | Riesgo |
|---|---|---|
| `config/sap_schemas/company_config_udt.json` | **nuevo** | — |
| `config/sap_schemas/README.md` | checklist de la UDT nueva | — |
| `db/seeds.rb` | bloque `SL_RESOURCES_COMPANY_CONFIG` | — |
| `db/migrate/…_add_company_config_sl_resources.rb` | **nueva** — filas del catálogo para instalaciones vivas | — |
| `db/migrate/…_drop_company_issuer_fields.rb` | **nueva** — baja de 4 columnas (no `name`, no `issuer_id_number` si se acepta §1) | 🔴 irreversible sin respaldo |
| `app/services/sap/company_config.rb` | **nuevo** — lectura + escritura de la UDT | — |
| `app/models/company.rb` | quitar 4 validaciones de largo + `inclusion` de `issuer_id_type`; `ISSUER_ID_TYPES` pasa a alimentar los `ValidValues`; **`email_sender_name` deja de resolverse local** (lo usa `Documents::ReceiptMailer`) | 🟠 se pierde validación con mensaje i18n (§30) |
| `app/controllers/api/companies_controller.rb` `#serialize_detail` | 5 claves + `EmsrNombreComercial` salen de SAP; `show` pasa a ser endpoint SAP-dependiente | 🟠 definir desenlace cuando SAP no responde |
| `app/controllers/api/companies/general_controller.rb` | 5 attrs salen de `general_params`; el PATCH escribe **dos sistemas**; `name` se espeja a `CommercialName` | 🔴 fallo parcial: orden validar → escribir → compensar (§34) |
| `app/services/documents/unified_builder.rb` L105, L160-172 | 5 lecturas → config cacheada | 🟠 latencia por documento |
| `app/services/documents/xml_archive.rb:119` | origen de la cédula | 🔴 ver §1 |
| `app/services/company_files/store.rb:159` | origen de la cédula (+ subclase `Certificates::Store`) | 🔴 ver §1 |
| `app/javascript/controllers/company_form_controller.js` L440, L468-476, L1762-66, L1990-99 | **posiblemente cero cambios** — ver §5 | 🟢 |
| `app/views/configurations/companies/_form.html.erb` | sin cambios de campos; sí mensajería de error si SAP falla | 🟢 |
| `config/locales/es.yml:113-117` | 4-5 claves quedan muertas | 🟢 |
| **14 archivos de spec** (~77 referencias) | doble de SAP en todo spec que toque el detalle de compañía, incluido `spec/support/hacienda_document_helpers.rb` | 🟠 el grueso del trabajo |
| `CLAUDE.md` §32, §34, §28 | §32 pasa a **contradecir el código**: reescribir el párrafo de `oadm_company_config` explicando por qué la UDT sí y los UDFs no | 🟠 |
| `TODOS.md` (sección Compañías → "Crear compañía") | afirma *«ya no hay que crear estructura en SAP para dar de alta una compañía»* — deja de ser cierto | 🟠 |

### Los 14 archivos de spec afectados

```
spec/models/company_spec.rb                            10 refs
spec/requests/api/company_general_spec.rb              17
spec/services/documents/unified_builder_spec.rb        13
spec/requests/api/companies_spec.rb                     7
spec/requests/api/company_attachments_spec.rb           6
spec/requests/api/company_tax_authority_spec.rb         5
spec/services/hacienda/document_validator_spec.rb       4
spec/services/hacienda/validations/header_validator_spec.rb  4
spec/services/documents/xml_archive_spec.rb             3
spec/services/hacienda/xml_builder_spec.rb              3
spec/support/hacienda_document_helpers.rb               2
spec/requests/api/company_certificate_spec.rb           1
spec/requests/api/company_logo_spec.rb                  1
spec/requests/api/company_print_format_spec.rb          1
```

---

## 4. Orden de ejecución

1. **Schema JSON** + `rake "sap:schema:diff[config/sap_connections.json]"` contra una base
   real. Sin eso no hay dónde escribir.
2. **Catálogo `sl_resources`** (seeds + migración de datos).
3. **`Sap::CompanyConfig`** con sus specs, aislado y verificable.
4. **Rake de migración de datos** que empuje los valores actuales de `companies` a la UDT
   de cada compañía. No va en una migración de Rails: es I/O contra SAP, tiene que poder
   reintentarse y reportar por compañía.
5. **Cablear lectura** (`show`, `UnifiedBuilder`, `email_sender_name`) manteniendo las
   columnas todavía pobladas — así se puede comparar y volver atrás.
6. **Cablear escritura** (`GeneralController`) con dual write.
7. **Recién entonces** la migración que da de baja las columnas.

Los pasos 5 y 6 son los que no se pueden hacer a medias: mientras haya dos fuentes que
alguien escriba, divergen.

---

## 5. Decisiones pendientes — hay que tomarlas ANTES de escribir código

- [ ] **¿Se conserva `issuer_id_number` en SQLite?** Recomendación: **sí** (§1). Si no,
      subir un logo pasa a depender de SAP.
- [ ] **¿`show` falla o degrada cuando SAP no responde?** Devolver el detalle sin el bloque
      del emisor deja al usuario editando un formulario que va a rechazar el guardado.
      Recomendación: **502** con el motivo de `MissingConfiguration` /
      `ServiceLayerError#sap_message` (§29).
- [ ] **¿El PATCH es atómico?** No puede serlo — son dos sistemas. Recomendación: validar
      todo primero, escribir SAP, y solo si eso pasó escribir SQLite; si SQLite falla,
      revertir la UDT.
- [ ] **Las claves del JSON NO cambian.** `EmsrNombre`, `EmsrIdeTipo`, `CodigoActividad`…
      son contrato con el frontend (§28 regla 7). Si se respetan, `company_form_controller.js`
      no se toca y el riesgo de la pantalla cae a casi cero.

---

## 6. Esfuerzo

Lo caro no es mover seis campos: son los **14 archivos de spec** que hoy escriben
`issuer_id_number` como atributo y pasan a necesitar un doble de Service Layer, y el dual
write del PATCH.

- Schema + catálogo + servicio: una tanda corta.
- Cableado + specs: dos o tres tandas más.

---

## 7. Dónde retomar mañana

Nada está aplicado. El árbol está limpio en `main` (último commit al redactar esto:
`f834cd2 chore(documentos): retirar la pantalla de Historial de correos`).

**Primer paso concreto:** resolver la decisión de `issuer_id_number` (§5, primer checkbox)
— es la que cambia la forma del resto. Con eso resuelto, arrancar por el paso 1 de §4
(escribir `config/sap_schemas/company_config_udt.json` y correr `sap:schema:diff`).

**Contexto que conviene releer antes de tocar nada:** `CLAUDE.md` §32 (UDTs/UDFs y el caso
`oadm_company_config`), §34 (archivos de compañía en disco) y §29 (acceso a SAP).

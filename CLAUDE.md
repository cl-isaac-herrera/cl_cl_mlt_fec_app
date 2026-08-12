# Convenciones de UI — FEC Rails Migration

## 17. Paginación remota Tabulator — contador de filas correcto

**Problema:** `paginationCounter: 'rows'` calcula el total como `last_page × pageSize`.
Si la última página no está llena (ej. 154 registros en páginas de 10 → last_page = 16),
Tabulator muestra "160 filas" en la primera carga y corrige a 154 solo al llegar a la última página.

**Causa raíz:** Tabulator no conoce el total real — solo infiere `last_page` del API response.

**Patrón obligatorio para toda tabla con paginación remota:**

```js
// 1. Campo de instancia para guardar el total real
#totalRecords = 0;

// 2. En getTableConfig() — reemplazar paginationCounter: 'rows'
paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
  const total = this.#totalRecords;
  if (!total) return '';
  const to = Math.min(currentRow + _pageSize - 1, total);
  return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
},

// 3. En #fetchPage() — guardar el total antes de retornar
const total = json.Data[0]?.MaxQtyRowsFetch ?? 0;  // o la propiedad que use la API
this.#totalRecords = total;
const lastPage = Math.max(1, Math.ceil(total / size));
return { data: json.Data, last_page: lastPage };
```

**⚠️ NUNCA usar `paginationCounter: 'rows'`** en tablas con `paginationMode: 'remote'`.

### Paginación remota — migrar de `setData()` local a `ajaxRequestFunc`

Si un controller carga datos con `this.table.setData(records)` (modo local), Tabulator
no puede paginar correctamente en el servidor. El patrón correcto es `ajaxRequestFunc`:

```js
// getTableConfig()
ajaxURL: '/api/MiEndpoint',                              // activa modo remote
ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
ajaxResponse:    (_url, _params, response) => response,

// connect() — super.connect() ya dispara la primera carga, no llamar #fetchPage manualmente
super.connect();

// action público de búsqueda — setData() recarga y vuelve a página 1
search() { this.table?.setData(); }
```

## 0. Registro obligatorio de Stimulus controllers

**Regla:** Todo controller nuevo **DEBE** registrarse en `app/javascript/controllers/index.js`
como parte del mismo paso en que se crea el archivo `*_controller.js`.
Si no se registra, Stimulus no reconoce el `data-controller` y la página queda muda (sin errores visibles).

### Patrón obligatorio

```js
// 1. Import al final del bloque de imports
import BranchesController from 'controllers/branches_controller'

// 2. Register al final del bloque de application.register(...)
application.register('branches', BranchesController)
```

### Regla del nombre del identificador

El identificador de `application.register` debe coincidir exactamente con el valor de
`data-controller="..."` en la vista ERB.
Convención: `snake_case` del archivo → `kebab-case` del identificador.

| Archivo | Identificador |
|---|---|
| `branches_controller.js` | `branches` |
| `roles_by_users_controller.js` | `roles-by-users` |
| `company_form_controller.js` | `company-form` |

### ⚠️ Error silencioso más frecuente en migraciones

**Síntoma:** La página carga pero no hace ninguna llamada API, la tabla aparece vacía
y no hay errores en consola.
**Causa:** El controller no está registrado en `index.js`.
**Verificación:** `grep 'NombreController' app/javascript/controllers/index.js`

---

## 1. Badges de estado

Todos los estados (activo/inactivo, estados de documentos, etc.) se renderizan como
**badges tipo Jira**: fondo tenue + texto en color + `rounded-full`.

### Colores base

| Estado | Fondo | Texto | Uso |
|---|---|---|---|
| Activo | `#e8f5ee` | `#3a7d52` | Registros habilitados |
| Inactivo | `#fdecea` | `#c0392b` | Registros deshabilitados |
| Abierto / Open | `#e8f0fe` | `#1a56db` | Documentos abiertos |
| Cerrado / Closed | `#f3f4f6` | `#4b5563` | Documentos cerrados |
| Pendiente | `#fffbeb` | `#b45309` | En espera de acción |
| Cancelado | `#fef2f2` | `#991b1b` | Anulados |
| Borrador / Draft | `#f5f3ff` | `#6d28d9` | Sin confirmar |
| Pagado | `#ecfdf5` | `#065f46` | Documentos pagados |
| Parcial | `#fff7ed` | `#c2410c` | Pago parcial |

### Implementación (JavaScript)

```js
#statusBadge(status) {
  const map = {
    active:    { bg: '#e8f5ee', color: '#3a7d52', label: 'Activo'    },
    inactive:  { bg: '#fdecea', color: '#c0392b', label: 'Inactivo'  },
    open:      { bg: '#e8f0fe', color: '#1a56db', label: 'Abierto'   },
    closed:    { bg: '#f3f4f6', color: '#4b5563', label: 'Cerrado'   },
    pending:   { bg: '#fffbeb', color: '#b45309', label: 'Pendiente' },
    cancelled: { bg: '#fef2f2', color: '#991b1b', label: 'Cancelado' },
    draft:     { bg: '#f5f3ff', color: '#6d28d9', label: 'Borrador'  },
    paid:      { bg: '#ecfdf5', color: '#065f46', label: 'Pagado'    },
    partial:   { bg: '#fff7ed', color: '#c2410c', label: 'Parcial'   },
  }
  const { bg, color, label } = map[status] ?? { bg: '#f3f4f6', color: '#4b5563', label: status }
  return `<span style="background-color:${bg}; color:${color};"
               class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
    ${label}
  </span>`
}
```

### Implementación (ERB inline)

```erb
<span style="background-color:#e8f5ee; color:#3a7d52;"
      class="inline-block px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
  Activo
</span>
```

---

## 2. Botones de acción en tablas

Los botones de acción en filas de tabla usan **ícono + tooltip**, sin texto visible.
El tooltip se muestra via JS con `position: fixed` (no CSS puro) para evitar ser recortado
por el `overflow: hidden` que Tabulator aplica en las celdas.

### Estructura HTML (dentro de formatters Tabulator)

```html
<button type="button"
        data-action-type="edit"
        data-tooltip="Editar"
        class="p-1.5 text-blue-600 rounded hover:bg-blue-50 transition-colors cursor-pointer">
  <span class="material-icons text-base">edit</span>
</button>
```

### Cómo funciona

`TabulatorController.setupTooltip()` (llamado automáticamente en `initializeTable()`) registra
event delegation sobre el contenedor de la tabla. Al hacer hover en cualquier `[data-tooltip]`,
mueve un `div#cl-tabulator-tooltip` con `position: fixed; z-index: 9999` a las coordenadas
del cursor — nunca queda dentro del stacking context de la celda.

### Reglas

- Agregar `data-tooltip="Texto"` directamente en el `<button>` — **no** en el span de ícono
- **No usar** `<div class="relative group">` + `<span class="...group-hover:opacity-100...">` en tablas Tabulator — el `overflow:hidden` de las celdas recorta esos tooltips
- Para tooltips **fuera de Tabulator** (formularios, toolbar) sí se puede usar el patrón CSS puro con `group-hover`

### Tooltips en botones deshabilitados — mensaje específico obligatorio

Los botones que se inhabilitan en función del estado de la fila **deben incluir `data-tooltip` con una razón específica y accionable**. Nunca usar mensajes genéricos.

| ❌ Incorrecto | ✅ Correcto |
|---|---|
| `"Esta opción no está disponible"` | `"El correo debe tener detalle para ver esta opción"` |
| `"No disponible"` | `"El documento debe estar en estado Abierto para anularlo"` |
| `"Acción no permitida"` | `"Solo se puede reenviar si el estado del correo es Error"` |

**Regla:** el tooltip del botón deshabilitado debe responder implícitamente a la pregunta *¿cuándo SÍ podré usarlo?*

```js
// ✅ CORRECTO — tooltip explica la condición
const tooltip = hasDetail
  ? 'Ver detalle del correo'
  : 'El correo debe tener detalle para usar esta opción';

return `<button type="button"
                data-action-type="view-detail"
                data-tooltip="${tooltip}"
                ${hasDetail ? '' : 'disabled'}
                class="...">
  <span class="material-icons text-base">lists</span>
</button>`;

// ❌ INCORRECTO — tooltip genérico o ausente en botón deshabilitado
return `<button type="button"
                data-action-type="view-detail"
                ${hasDetail ? 'data-tooltip="Ver detalle"' : ''}
                ${hasDetail ? '' : 'disabled'}
                class="...">
  <span class="material-icons text-base">lists</span>
</button>`;
```

**Importante:** `data-tooltip` debe estar **siempre** presente en el botón, habilitado o no.
El tooltip del estado habilitado describe la acción; el del deshabilitado explica la condición.

---

## 3. Columnas de tabla estándar

| Tipo de columna | Renderizado |
|---|---|
| Estado | Badge (ver sección 1) |
| Acciones | Botón ícono + tooltip (ver sección 2) |
| Fecha | Formato `DD/MM/YYYY` |
| Monto | `toLocaleString('es-CR')` + símbolo de moneda |
| Booleano | Badge Activo/Inactivo |

---

## 4. Inputs con botones sufijo (matSuffix)

Todo campo que tenga botones de acción dentro del input (adjuntar archivo, descargar,
toggle password, agregar ítem) usa un **contenedor unificado con borde compartido**,
equivalente al `mat-form-field` con `matSuffix` de Angular Material.

### Estructura HTML

```html
<div class="flex items-center border border-gray-300 rounded-lg overflow-hidden focus-within:ring-2 focus-within:ring-blue-500 bg-gray-50">
  <input type="text" readonly
         class="flex-1 px-3 py-2 text-sm bg-transparent outline-none cursor-default">
  <button type="button"
          class="self-stretch flex items-center px-2 border-l border-gray-200 text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors flex-shrink-0"
          title="Acción">
    <span class="material-icons text-base leading-none">attach_file</span>
  </button>
</div>
```

### Reglas

- El **wrapper** lleva el borde, radio y `overflow-hidden`. El input/select no tiene borde propio.
- `focus-within:ring-2 focus-within:ring-blue-500` en el wrapper → todo el contenedor se resalta al hacer focus.
- Cada botón sufijo lleva `border-l border-gray-200` para el separador vertical interno.
- `flex-shrink-0` en botones para que no se compriman.
- `leading-none` en el ícono para evitar altura extra.
- El input usa `bg-transparent outline-none` para no mostrar borde ni fondo propios.
- Para inputs **editables**: `bg-white` en el wrapper. Para **readonly**: `bg-gray-50` + `cursor-default`.
- **NO usar `p-2` en botones sufijo** — usar `self-stretch flex items-center px-2`.

### Toggle de contraseña (posición absoluta)

```html
<div class="relative">
  <input type="password"
         class="w-full border border-gray-300 rounded-lg px-3 py-2 pr-10 text-sm
                focus:outline-none focus:ring-2 focus:ring-blue-500">
  <button type="button"
          class="absolute right-2 top-1/2 -translate-y-1/2 p-1 text-gray-500 hover:text-gray-700">
    <span class="material-icons text-base">visibility_off</span>
  </button>
</div>
```

---

## 5. Formato de fechas

Todas las fechas se muestran en formato **`yyyy-MM-dd HH:mm:ss`** (ISO 8601 con espacio).

```js
#formatDateTime(dateStr) {
  if (!dateStr) return '';
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return '';
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
```

- **NO usar** `toLocaleDateString()` ni `toLocaleString()` para fechas de la API.
- Solo usar `toLocaleString('es-CR')` para **montos**.

---

## 6. Manejo de errores de API — header `cl-message`

El backend envía mensajes de error en el header HTTP `cl-message` (URI-encoded).
El proxy Rails reenvía este header al browser (`proxy_controller.rb`).

### Patrón `#apiFetch` correcto (copiar en TODO controller)

```js
async #apiFetch(url, options = {}) {
  const isFESync = (options.headers?.['API'] ?? 'ApiAppUrl') === 'ApiFEUrl';

  // Token: FE Sync server usa su propio token (sessionStorage.currentFEUser)
  //        App server usa el token principal de sesión (localStorage.Session)
  const token = isFESync
    ? (JSON.parse(sessionStorage.getItem('currentFEUser') || '{}')?.access_token ?? null)
    : (Storage.get('Session') || {}).access_token;

  const company   = SStore.get('CurrentCompany');
  const companyId = company?.companyId ?? this.#companyId;

  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type':             'application/json',
      'API':                      'ApiAppUrl',
      'X-Skip-Error-Interceptor': 'true',
      ...(token     ? { Authorization:   `Bearer ${token}` } : {}),
      ...(companyId ? { 'Cl-Company-Id': String(companyId) } : {}),
      ...(options.headers || {}),
    },
  });

  const clMessage = response.headers.get('cl-message');
  const decodedMessage = clMessage ? (() => {
    try { return decodeURIComponent(clMessage); } catch { return clMessage; }
  })() : null;

  if (!response.ok) {
    const text = await response.text().catch(() => response.statusText);
    throw new Error(decodedMessage || text || `HTTP ${response.status}`);
  }

  const hasBody = response.status !== 204 &&
                  response.headers.get('content-length') !== '0' &&
                  response.headers.get('content-type')?.includes('application/json');
  if (!hasBody) return { Message: decodedMessage || null };

  const json = await response.json();
  if (decodedMessage && !json.Message) json.Message = decodedMessage;
  return json;
}
```

### Dos backends — el header `API` determina a cuál enruta el proxy

Existen dos servidores backend distintos. El proxy Rails lee el header `API` para decidir el destino:

| Header `API` | Backend | Config | Uso |
|---|---|---|---|
| `ApiAppUrl` (default) | App server | `api_fe_app_url` | Usuarios, empresas, permisos, catálogos, documentos GET/search |
| `ApiFEUrl` | Sync/FE server | `api_fe_sync_url` | Emisión, Hacienda, reprocesar, anular, cambios de estado |

Verificar qué header usa el servicio Angular legacy (`documents.service.ts`) antes de implementar cada llamada.
Si una llamada usa `'API': 'ApiAppUrl'` en Angular → no se pasa nada extra (es el default de `#apiFetch`).
Si usa `'API': 'ApiFEUrl'` → pasar `headers: { 'API': 'ApiFEUrl' }` en las options de `#apiFetch`.

```js
// Endpoint en App server (default — no se necesita header extra)
await this.#apiFetch('/api/Rol/GetRoles?companyId=1')

// Endpoint en Sync/FE server — requiere header explícito
await this.#apiFetch('/api/Documents/123/Reprocess?...', {
  method: 'PATCH',
  body: JSON.stringify({}),
  headers: { 'API': 'ApiFEUrl' },
})
```

### ⚠️ Error: 404 en endpoints de emisión/Hacienda

**Síntoma:** La llamada devuelve 404 aunque el path parece correcto.
**Causa:** El endpoint vive en el servidor `ApiFEUrl` pero se envía sin el header → el proxy lo manda al server equivocado.
**Verificación:** Buscar el método en `documents.service.ts` y confirmar qué valor tiene `'API'` en sus headers.

### Reglas

- **SIEMPRE** enviar `Cl-Company-Id` — el proxy lo reenvía transparente al backend; sin él, la API no sabe a qué empresa corresponde la solicitud.
- **NUNCA** ignorar `cl-message` — es donde vive el mensaje real de la API.
- Para errores (non-2xx): usar `decodedMessage` como mensaje primario.
- **NUNCA** llamar `.json()` sin verificar body — las escrituras frecuentemente devuelven `204`.

### ⚠️ Error: `response.json()` en respuestas 204 No Content

**Síntoma:** Una acción (POST/PATCH/DELETE) lanza una excepción del tipo `SyntaxError: Unexpected end of JSON input` o similar, aunque la operación fue exitosa en el servidor.
**Causa:** El endpoint devuelve `204 No Content` (sin body) y el código llama `.json()` directamente.
**Patrón incorrecto:**
```js
const json = await response.json(); // ❌ explota si status === 204
```
**Fix — usar el guard `hasBody` antes de parsear:**
```js
const hasBody = response.status !== 204 &&
                response.headers.get('content-length') !== '0' &&
                response.headers.get('content-type')?.includes('application/json');
if (!hasBody) return { Message: decodedMessage || null };

const json = await response.json(); // ✅ solo si hay body
```
Este guard ya está incluido en el patrón `#apiFetch` canónico de arriba — copiar íntegro, nunca recortar.

### ⚠️ Error silencioso más frecuente

**Síntoma:** La API devuelve 401/403 o datos vacíos aunque el usuario está autenticado.
**Causa probable:** Falta el header `Cl-Company-Id`.
**Verificación:** Abrir DevTools → Network → inspeccionar la request y confirmar que el header está presente.

---

## 7. Notificaciones toast — `showToast`

```js
import { showToast } from 'vendor/clavisco/alerts'
showToast(message, type = 'success', duration = 4000)
// type: 'success' | 'error' | 'warning' | 'info'
```

- **NO** declarar `toast`, `toastIcon`, `toastMessage` en `static targets` — son legacy.
- **NO** agregar divs `data-xxx-target="toast"` en las views — el layout ya tiene `#toast-container`.
- Implementación en `app/javascript/vendor/clavisco/alerts/index.js`.

---

## 8. Paneles laterales vs Modales

| Caso de uso | Componente |
|---|---|
| Formulario de creación/edición complejo | **Panel lateral** |
| Formulario anidado | **Panel lateral** |
| Vista de detalle / previsualización de documento | **Panel lateral** |
| Modal de Angular legacy con contenido extenso | **Panel lateral** |
| Confirmación de acción destructiva | **Modal** |
| Mensaje de error grave | **Modal** |
| Notificación no bloqueante | **Toast** |

Nunca usar modal para formularios de creación, edición o previsualización de contenido.

### Regla de migración desde Angular

Toda `MatDialog` / modal de Angular legacy que muestre **formularios, detalles o previsualización** se migra como **panel lateral**.
Solo se conserva como modal: confirmaciones destructivas, mensajes de error bloqueantes y advertencias simples (sin contenido extenso).

### Implementación — Panel lateral

```html
<div data-controller-target="panelBackdrop"
     data-action="click->controller#closePanel"
     class="hidden fixed inset-0 z-40 bg-black/40"></div>

<div data-controller-target="panel"
     class="fixed top-0 right-0 h-full w-full max-w-lg bg-white shadow-2xl z-50
            translate-x-full transition-transform duration-300 ease-in-out flex flex-col">
  <div class="flex items-center justify-between px-6 py-4 border-b border-gray-100 flex-shrink-0">
    <h3 class="text-base font-semibold text-gray-800">Título del panel</h3>
    <button type="button" data-action="click->controller#closePanel"
            class="p-1 text-gray-400 hover:text-gray-600 rounded hover:bg-gray-100 transition-colors">
      <span class="material-icons text-xl">close</span>
    </button>
  </div>
  <div class="flex-1 overflow-y-auto px-6 py-5"><%# campos %></div>
  <div class="px-6 py-4 border-t border-gray-100 flex justify-end gap-3 flex-shrink-0">
    <button type="button" data-action="click->controller#closePanel"
            class="inline-flex items-center gap-1 px-4 py-2 border border-gray-300 text-gray-700 text-sm font-medium rounded-lg hover:bg-gray-50 transition-colors">
      <span class="material-icons text-base">cancel</span>Cancelar
    </button>
    <button type="button" data-action="click->controller#saveFromPanel"
            class="inline-flex items-center gap-1 px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed">
      <span class="material-icons text-base">check</span>Guardar
    </button>
  </div>
</div>
```

```js
openPanel()  { this.panelBackdropTarget.classList.remove('hidden'); this.panelTarget.classList.remove('translate-x-full'); document.body.style.overflow = 'hidden'; }
closePanel() { this.panelTarget.classList.add('translate-x-full'); this.panelBackdropTarget.classList.add('hidden'); document.body.style.overflow = ''; }
```

---

## 9. Cuándo usar toast vs modal de error

| Situación | Mecanismo |
|---|---|
| Éxito de escritura (POST/PATCH/DELETE) | Toast `success` |
| Error de escritura (POST/PATCH/DELETE) | **Modal de error** |
| Error/advertencia de lectura (GET) | Toast `error` / `warning` |
| Validación client-side | Toast `warning` |
| Sin permisos | Toast `info` |

- Escritura: errores → modal, éxito → toast.
- Lectura: todo → toast.

---

## 10. Idioma de la interfaz — todo en español

Todo texto visible para el usuario debe estar en **español**: títulos, labels, placeholders,
botones, tooltips, mensajes de toast/modal, encabezados de tabla, textos de librerías externas.

### Tabulator — locale español + íconos en el paginador

```js
import { TABULATOR_LOCALE, TABULATOR_LANGS } from 'controllers/tabulator_locale'

getTableConfig() {
  return { ..., paginationCounter: 'rows', locale: TABULATOR_LOCALE, langs: TABULATOR_LANGS }
}
```

- Botones de navegación usan `<span class="material-icons">` en lugar de texto.
- **NO** dejar "First / Prev / Next / Last / Page Size / Showing … of …" en inglés.
- Reutilizar `TABULATOR_LANGS`; no redefinir labels por tabla.

---

## 11. Tablas Tabulator — altura relativa al contenedor

| Capa | Qué aplicar |
|---|---|
| Card / wrapper externo | `flex-1 min-h-0` |
| Toolbar dentro del cuerpo | `flex-shrink-0` |
| Div contenedor de la tabla | `flex-1 min-h-0` |
| Div target de Tabulator | `class="h-full"` |
| Config Tabulator | `height: '100%'`, `maxHeight: undefined` |

### ⚠️ `maxHeight` debe sobreescribirse explícitamente

El `TabulatorController` base inyecta `maxHeight: "500px"` desde su Stimulus value.
Aunque el child declare `height: '100%'`, la tabla quedará limitada a 500px si no se anula:

```js
getTableConfig() {
  return {
    ...super.getTableConfig(),
    height: '100%',
    maxHeight: undefined,  // ← obligatorio para tablas de altura relativa
    // ...
  };
}
```

Sin `maxHeight: undefined`, la tabla ignora el contenedor flex y se corta a 500px.

```html
<div data-controller="mi-modulo" class="p-6 flex flex-col h-full">
  <div class="mb-4 flex-shrink-0 flex justify-end"><!-- toolbar --></div>
  <div class="flex-1 min-h-0 bg-white rounded-xl shadow-sm border overflow-hidden">
    <div data-mi-modulo-target="table" class="h-full"></div>
  </div>
</div>
```

### Acordeón con dos secciones

```js
toggleSeccion() {
  const collapsed = this.seccionSectionTarget.classList.toggle('hidden');
  this.seccionCardTarget.classList.toggle('flex-1',        !collapsed);
  this.seccionCardTarget.classList.toggle('min-h-0',       !collapsed);
  this.seccionCardTarget.classList.toggle('flex-shrink-0', collapsed);
  if (!collapsed) requestAnimationFrame(() => this.table?.redraw(true));
}
```

### Errores comunes

- `height: '100%'` sin contenedor con altura explícita → tabla colapsa.
- `h-full` en el target sin `min-h-0` en el padre → scroll nunca aparece.
- Inicializar Tabulator dentro de `hidden` → llamar `redraw(true)` al mostrar.
- `import('tabulator-tables')` dinámico → usar siempre import estático.

---

## 13. Extensión de TabulatorController — métodos públicos obligatorios

`TabulatorController` (base) llama internamente a `this.getColumns()` y `this.getTableConfig()`
durante `connect()`. Estos métodos **deben ser públicos** en el controller hijo.

### ⚠️ Error recurrente

```
Error: getColumns() must be implemented by child controller
```

**Causa:** declarar `getColumns` como método privado (`#getColumns`).
**Fix:** siempre usar nombre público sin `#`.

### Patrón correcto

```js
export default class extends TabulatorController {

  // ✅ CORRECTO — público, base controller puede llamarlo
  getTableConfig() {
    return {
      ...super.getTableConfig(),
      height: '100%',
      columns: this.getColumns(),   // ← llamada también pública
      // ...resto de config
    };
  }

  // ✅ CORRECTO — público
  getColumns() {
    return [
      { title: 'Nombre', field: 'Name', widthGrow: 2 },
      // ...
    ];
  }
}
```

### ❌ Patrón incorrecto

```js
export default class extends TabulatorController {



  // ❌ INCORRECTO — privado, el base NO puede llamarlo
  #getColumns() { ... }

  getTableConfig() {
    return {
      ...super.getTableConfig(),
      columns: this.#getColumns(), // ← tampoco funciona desde super
    };
  }
}
```

### Regla

> `getColumns()` y `getTableConfig()` son el contrato entre el controller hijo y la base.
> **Nunca** prefixar con `#`. Cualquier método llamado por la clase base debe ser público.

---

## 14. Layout `protected` — obligatorio en todo controller de páginas autenticadas

Todo controller que sirve una página con menú lateral y toolbar **debe** declarar `layout 'protected'`.
Sin esta línea, Rails usa el layout `application` (solo el HTML base sin menú, sin auth-guard, sin toolbar).

### ⚠️ Síntoma

Al navegar a la página: el menú lateral y el toolbar desaparecen completamente.
La página carga pero parece "desnuda" — solo el contenido sin chrome.

### Causa

Rails hereda el layout desde `ApplicationController`, que usa `application.html.erb`.
El layout con menú, toolbar y auth-guard es `protected.html.erb`.
Si el controller no lo declara explícitamente, no lo obtiene.

### Patrón obligatorio

```ruby
# ✅ CORRECTO — tiene menú y toolbar
module Documents
  class IssuedController < ApplicationController
    layout 'protected'

    def index; end
  end
end
```

```ruby
# ❌ INCORRECTO — página sin menú ni toolbar
module Documents
  class IssuedController < ApplicationController
    def index; end   # usa layout 'application' por defecto
  end
end
```

### Regla

> **Cada** controller nuevo bajo `namespace :configurations`, `namespace :documents`,
> o cualquier namespace de páginas autenticadas **DEBE** incluir `layout 'protected'`
> como primera línea del cuerpo de la clase, antes de cualquier action.

### Verificación rápida

```bash
grep -rn "layout 'protected'" app/controllers/
# Debe aparecer en TODOS los controllers excepto sessions_controller y home_controller
```

---

## 12. Botones de acción primaria en toolbar — alineación y color del botón Cancelar

### Alineación del toolbar

Los botones de acción primaria (Nuevo, Crear, Agregar) se alinean siempre a la **derecha**.

```html
<div class="mb-4 flex-shrink-0 flex justify-end">
  <button type="button" ...>
    <span class="material-icons text-base">add</span>
    Nuevo
  </button>
</div>
```

**Nunca** omitir `flex justify-end` en el div del toolbar.

### Color del botón Cancelar

El botón **Cancelar** usa siempre tono **gris neutro**. El rojo implica acción destructiva y cancelar no lo es.

```html
<%# Correcto %>
<button class="px-4 py-2 text-sm font-medium text-gray-700 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors">
  Cancelar
</button>

<%# Incorrecto — rojo genera alarma innecesaria %>
<button class="px-4 py-2 text-sm font-medium text-red-600 border border-red-300 rounded-lg hover:bg-red-50 transition-colors">
  Cancelar
</button>
```

El rojo se reserva para acciones **destructivas e irreversibles** (eliminar, anular).

---

## 16. Diálogos de confirmación — NUNCA alertas nativas del navegador

**Regla:** Está **prohibido** usar `window.confirm()`, `window.alert()` o `window.prompt()` en cualquier parte de la app.
Estas APIs bloquean el hilo principal, no respetan el diseño del sistema y su aspecto varía por OS/browser.

### Patrón obligatorio — `confirm()` del alerts service

```js
import { confirm } from 'vendor/clavisco/alerts'

async #miAccionDestructiva() {
  const confirmed = await confirm('¿Está seguro de que desea eliminar este registro?', 'Eliminar registro')
  if (!confirmed) return

  // ... continuar con la acción
}
```

`confirm(message, title?)` retorna `Promise<boolean>` — usa `await` siempre.
Internamente llama a `showAlert({ type: 'warning', showCancel: true, ... })`.

### Para alertas simples (sin cancelar)

```js
import { showAlert, ALERT_TYPES } from 'vendor/clavisco/alerts'

await showAlert({ type: ALERT_TYPES.ERROR, title: 'Error', message: 'Descripción del error.' })
```

### ⚠️ Errores comunes

- Usar `window.confirm()` por conveniencia → **reemplazar siempre** con `confirm()` del service.
- Olvidar `await` → el código continúa sin esperar la respuesta del usuario.

---

## 15. Loaders — cuatro tipos estándar

Existen exactamente cuatro tipos de loader en la app. No inventar variantes fuera de estos.

### Tipo A — Overlay bloqueante (partial ERB)

Para operaciones que bloquean la interacción con la página (guardar, procesar, cambiar empresa).
Se renderiza con el partial `shared/overlay_loader`:

```erb
<%= render 'shared/overlay_loader',
      ctrl:       'documents-create',   # controller en kebab-case
      message:    'Guardando...' %>     # texto visible
```

Locals completos:

| Local | Default | Descripción |
|---|---|---|
| `ctrl` | — (requerido) | Nombre del controller en kebab-case |
| `target` | `loadingOverlay` | Nombre del Stimulus target |
| `msg_target` | `loadingMessage` | Target del `<p>` del mensaje. `nil` = mensaje fijo sin target |
| `message` | `Cargando...` | Texto visible |
| `z_class` | `z-50` | Clase z-index. Usar `z-[60]`, `z-[9999]` cuando sea necesario |

El controller lo muestra/oculta con:

```js
this.loadingOverlayTarget.classList.remove('hidden')  // mostrar
this.loadingOverlayTarget.classList.add('hidden')     // ocultar

// Si tiene msg_target, actualizar el mensaje antes de mostrar:
this.loadingMessageTarget.textContent = 'Procesando...'
this.loadingOverlayTarget.classList.remove('hidden')
```

### Tipo B — Overlay global vía JS (overlay service)

Para controllers JS que no tienen una vista ERB propia o necesitan mostrar el loader
desde múltiples puntos de código (ej. `general_configs`, `permissions`).
Usa `showLoading` / `hideLoading` del overlay service:

```js
import { showLoading, hideLoading } from 'vendor/clavisco/overlay'

showLoading('Guardando permisos, espere por favor...')
// ... operación async ...
hideLoading()
```

El overlay global se crea en `document.body` con id `cl-global-loader` y mismo estilo que el partial.

### Tipo C — Table loader (Tabulator)

Para el estado de carga de tablas Tabulator. Usar `TABULATOR_LOADING_HTML` de `tabulator_locale`:

```js
import { TABULATOR_LOADING_HTML } from 'controllers/tabulator_locale'

this.table?.alert(TABULATOR_LOADING_HTML)  // mostrar
this.table?.clearAlert()                   // ocultar
```

### Tipo D — Loader a nivel de fila (celda de estado Tabulator)

Para acciones que afectan **una sola fila** y NO deben bloquear el resto de la tabla
(ej. *Reprocesar* en documentos emitidos/recepciones). En vez de un overlay global,
la celda de **Estado** de esa fila muestra un badge transitorio con spinner mientras
la solicitud está en vuelo; al terminar, `replaceData()` recarga desde el servidor y
restaura el estado real (o revierte el loader si falló).

```js
// Helper — badge transitorio (mismo estilo que los badges de §1)
#sendingBadge(label = 'Enviando') {
  return `<span style="background-color:#e8f0fe; color:#1a56db;"
                class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold tracking-wide">
    <span class="inline-block h-3 w-3 rounded-full border-2 border-current border-t-transparent animate-spin"></span>
    ${label}
  </span>`;
}

// En el formatter de la columna Estado — detectar el marcador transitorio
formatter: (cell) => {
  const val = cell.getValue();
  if (val?.loading) return this.#sendingBadge(val.label);  // o sentinel 'loading' según el tipo del campo
  return this.#statusBadge(val);
}

// En la acción de fila — marcar la celda, lanzar la petición, refrescar en finally
const rowComp = this.table?.getRows().find(r => r.getData().Id === id);
rowComp?.update({ StatusForTable: { loading: true } });
try {
  await this.#apiFetch(/* ... */);
  showToast('Solicitud enviada', 'success');
} catch (err) {
  showToast(err.message, 'error');
} finally {
  this.table?.replaceData();   // restaura estado real (éxito) o revierte loader (error)
}
```

**Regla del texto:** el label debe describir la **fase real** de la operación, no una
acción que no ocurre todavía. Ej.: una acción que solo **encola** el documento para que
un servicio en segundo plano lo procese usa **"Enviando"** (la solicitud se está enviando),
**nunca "Procesando"/"Reprocesando"** — eso implicaría trabajo activo que no está pasando.

### Regla de selección

| Situación | Tipo |
|---|---|
| Operación bloqueante en una vista ERB | **A — partial** |
| Operación bloqueante en controller JS sin vista propia | **B — overlay service** |
| Carga de datos en una tabla Tabulator | **C — TABULATOR_LOADING_HTML** |
| Acción sobre una sola fila que no debe bloquear la tabla | **D — loader a nivel de fila** |

**No usar** `animate-spin material-icons autorenew`, `border-b-2 border-blue-600`
ni `border-4 border-t-transparent` como loaders de página/sección — son patrones legacy
ya eliminados. La **única** excepción permitida para `border-t-transparent animate-spin`
es el spinner pequeño (`h-3 w-3`) dentro del badge del **Tipo D**.

---

## 17. Paginación remota Tabulator — contador de filas correcto

**Problema:** `paginationCounter: 'rows'` calcula el total como `last_page × pageSize`.
Si la última página no está llena (ej. 154 registros en páginas de 10 → last_page = 16),
Tabulator muestra "160 filas" en la primera carga y corrige a 154 solo al llegar a la última página.

**Causa raíz:** Tabulator no conoce el total real — solo infiere `last_page` del API response.

**Patrón obligatorio para toda tabla con paginación remota:**

```js
// 1. Campo de instancia para guardar el total real
#totalRecords = 0;

// 2. En getTableConfig() — reemplazar paginationCounter: 'rows'
paginationCounter: (_pageSize, currentRow, _currentPage, _totalRows, _totalPages) => {
  const total = this.#totalRecords;
  if (!total) return '';
  const to = Math.min(currentRow + _pageSize - 1, total);
  return `Mostrando ${currentRow.toLocaleString('es-CR')}-${to.toLocaleString('es-CR')} de ${total.toLocaleString('es-CR')} filas`;
},

// 3. En #fetchPage() — guardar el total antes de retornar
const total = json.Data[0]?.MaxQtyRowsFetch ?? 0;  // o la propiedad que use la API
this.#totalRecords = total;
const lastPage = Math.max(1, Math.ceil(total / size));
return { data: json.Data, last_page: lastPage };
```

**⚠️ NUNCA usar `paginationCounter: 'rows'`** en tablas con `paginationMode: 'remote'`.

### Paginación remota — migrar de `setData()` local a `ajaxRequestFunc`

Si un controller carga datos con `this.table.setData(records)` (modo local), Tabulator
no puede paginar correctamente en el servidor. El patrón correcto es `ajaxRequestFunc`:

```js
// getTableConfig()
ajaxURL: '/api/MiEndpoint',                              // activa modo remote
ajaxRequestFunc: (_url, _config, params) => this.#fetchPage(params),
ajaxResponse:    (_url, _params, response) => response,

// connect() — super.connect() ya dispara la primera carga, no llamar #fetchPage manualmente
super.connect();

// action público de búsqueda — setData() recarga y vuelve a página 1
search() { this.table?.setData(); }
```



## 18. Edición de archivos — usar las herramientas NATIVAS (Edit/Write), NO Python vía Bash

**Regla:** modificar archivos del proyecto SIEMPRE con las herramientas de archivo **nativas** (`Edit` para reemplazo quirúrgico, `Write` para archivo nuevo o reescritura completa). Estas escriben directo al filesystem de Windows (`C:\...`), de forma atómica.

**Está PROHIBIDO escribir archivos del proyecto con Python, `sed`, redirección `>` u otros medios a través del shell de Bash.** El shell corre en un sandbox aislado que llega a los archivos por un *mount* de red (`/sessions/.../mnt/...`), y ese mount **corrompe las escrituras**.

### Por qué (causa raíz confirmada)

Hay dos caminos distintos hacia los mismos archivos:

| Camino | Cómo escribe | Resultado |
|---|---|---|
| Herramientas nativas `Edit` / `Write` | Directo a `C:\...`, sin intermediario | **Seguro y atómico** |
| Bash (`python open().write()`, `sed -i`, `>`) | A través del mount `/sessions/.../mnt/...` | **Corrompe el archivo** |

Síntomas reales observados al escribir vía el mount:

- **Truncado silencioso** — el archivo queda cortado a la mitad (ej. `users_controller.js` quedó en 962 de 1036 líneas, sin el cierre de clase) por un flush incompleto del mount.
- **Relleno con bytes NUL** — el mount agrega bytes `\0` al final del archivo (ej. `numbering_controller.js`, `CLAUDE.md`). `grep` lo marca como `binary file matches` y el bundler de assets puede fallar.

> ⚠️ La regla anterior de esta sección ("usar SIEMPRE Python vía Bash") era **la causa** de la corrupción, no la solución. Por eso se invierte: en este entorno (Cowork) la herramienta segura es `Edit`/`Write` nativa; lo riesgoso es escribir por el mount de Bash.

### Regla obligatoria

1. Crear o modificar cualquier archivo del proyecto → `Edit` o `Write` nativas. **Nunca** Python / `sed -i` / `>` sobre el mount para escribir.
2. Bash se reserva para **solo lectura** y comandos: `git`, `grep`, `node --check`, `wc`, correr tests, etc.
3. Antes de usar `Edit`, el archivo debe haberse leído con `Read` en la conversación (la herramienta lo exige).
4. `Edit` no se ve afectado por CRLF ni por el tamaño del archivo en este entorno; el problema histórico era el mount, no la herramienta.

### Verificación después de editar (Bash, solo lectura)

```bash
# 1. ¿Quedó algún byte NUL? Debe imprimir "limpio".
grep -qI . app/javascript/controllers/mi_controller.js && echo limpio || echo "NUL/CORRUPTO"

# 2. Sintaxis JS válida
node --check app/javascript/controllers/mi_controller.js

# 3. Conteo de líneas razonable vs HEAD (detecta truncado)
wc -l app/javascript/controllers/mi_controller.js
git show HEAD:app/javascript/controllers/mi_controller.js | wc -l
```

### Señales de archivo corrupto

- `grep` reporta `binary file matches` → el archivo tiene bytes NUL (relleno del mount).
- `tail` muestra el archivo cortado a media función/expresión → truncado.
- El browser lanza `SyntaxError: Private field '#x' must be declared in an enclosing class` → la clase no cerró (truncado).

### Recuperación cuando un archivo ya quedó corrupto / truncado

```bash
# 1. Comparar disco vs HEAD
wc -l app/javascript/controllers/mi_controller.js
git show HEAD:app/javascript/controllers/mi_controller.js | wc -l

# 2. Restaurar el contenido pristino. `git show` lee el blob desde el object store
#    y la redirección '>' restituye el archivo sin el padding del mount (verificado).
git show HEAD:app/javascript/controllers/mi_controller.js > app/javascript/controllers/mi_controller.js
```

Después de restaurar, reaplicar los cambios con `Edit` nativo (no con Python).


---

## 19. Navegación SPA — `Turbo.visit`, NO `window.location.href`

Turbo Drive ya está cargado (`import '@hotwired/turbo-rails'` en `application.js`).
Para navegar entre vistas se usa **`Turbo.visit(ruta)`** (o anclas `<a href>` que
Turbo intercepta), **nunca** `window.location.href`. Turbo reemplaza el `<body>`
sin recargar assets ni perder el `<aside>` permanente del menú → navegación tipo SPA.

`window.location.href` / `location.reload()` hacen un *full reload* del navegador:
descartan el DOM, re-descargan todo y colapsan el menú. Reservarlos SOLO para los
casos que deben re-bootstrapear el estado completo de la app.

### Regla

| Situación | Mecanismo |
|---|---|
| Navegar a otra vista (crear / editar / listar / volver) | **`Turbo.visit(ruta)`** |
| Redirección por guard (sin permiso → `/home`) | `Turbo.visit('/home')` |
| Cambio de empresa | `window.location.reload()` — recarga permisos/empresa y reconstruye el menú |
| Asignación de permisos a un rol | `window.location.reload()` — refresca el estado de permisos |
| Login (post-autenticación) | `window.location.href` — arranque limpio de sesión |
| Logout | `window.location.href = '/login'` — limpia la sesión |
| Sincronización de sesión entre pestañas | `window.location.href` — requiere re-init completo |
| Abrir archivo/PDF en pestaña nueva (`window.open`) | `tab.location.href` — NO es navegación de página |

### Por qué algunos casos SÍ usan reload

El `<aside>` del menú es `data-turbo-permanent`: con `Turbo.visit` no se reconstruye,
por lo que NO reflejaría permisos/empresa nuevos. Tras un **cambio de empresa** o de
**permisos** hay que recargar (`location.reload()`) para que el menú y los catálogos
se reconstruyan con el estado actualizado. Usar `Turbo.visit` ahí dejaría el menú
desincronizado.

### Patrón

```js
// ✅ Navegación pura
Turbo.visit('/configurations/companies')
Turbo.visit(`/configurations/companies/${id}/edit`)

// ✅ Re-bootstrap intencional (cambió el estado global)
window.location.reload()              // cambio de empresa / permisos
window.location.href = '/login'       // logout

// ❌ Navegación con full reload innecesario (parpadeo + colapsa el menú)
window.location.href = '/configurations/companies'
```

### ⚠️ Preferir panel lateral sobre navegar a otra vista

Para crear/editar (ver §8), preferir abrir un **panel lateral** en el mismo listado
en lugar de navegar a `/new` o `/:id/edit`. No hay navegación y el estado del listado
(filtros, página actual) se conserva. Referencia: `connections_controller.js`.

### ⚠️ El menú colapsa al navegar aunque el `<aside>` sea `data-turbo-permanent`

**Síntoma:** los nodos padre expandidos se cierran al navegar con `Turbo.visit`.
**Causa:** al reemplazar el `<body>`, Turbo mueve el `<aside>` permanente al nuevo
body y Stimulus lo trata como **reconexión** → `connect()` corre de nuevo,
`#expandedGroups` (campo de la nueva instancia) nace vacío y `#renderMenu()` borra
el DOM expandido.
**Validación:** `console.log` en `connect()` del `menu_controller` → se dispara en
cada navegación.
**Solución:** el nodo permanente CONSERVA el DOM entre el disconnect y el connect;
en `connect()` se reconstruye `#expandedGroups` leyendo del DOM
(`#captureExpandedFromDom()`) **antes** de re-renderizar, y `#createNodeElement`
respeta ese estado al recrear cada grupo. Sin storage.

---

## 20. Botón de creación primaria — label `Nuevo/Nueva [Entidad]`

El botón de acción primaria del toolbar (el que **abre** el panel/modal de creación) usa
siempre el patrón **`Nuevo/Nueva [Entidad en singular]`**, concordando el género con la
entidad. Nunca un genérico `Crear` ni solo `Nuevo`/`Nueva` sin la entidad.

### Regla

> Label del botón = `Nuevo ` (masculino) o `Nueva ` (femenino) + **nombre de la entidad en
> singular**. El género concuerda con la entidad; el ícono siempre es `add`.

| Módulo | Entidad | Label correcto |
|---|---|---|
| Usuarios | Usuario (m) | `Nuevo Usuario` |
| Seguridad / Roles | Rol (m) | `Nuevo Rol` |
| Grupos | Grupo (m) | `Nuevo Grupo` |
| Conexiones | Conexión (f) | `Nueva Conexión` |
| Compañías | Compañía (f) | `Nueva Compañía` |
| Sucursales | Sucursal (f) | `Nueva Sucursal` |
| Numeración | Numeración (f) | `Nueva Numeración` |
| Bandejas de emisión | Bandeja (f) | `Nueva Bandeja` |
| Bandejas de recepción | Bandeja (f) | `Nueva Bandeja` |

### Patrón

```erb
<%# ✅ CORRECTO — concuerda género + entidad en singular %>
<button type="button"
        data-action="click->mi-modulo#openCreatePanel"
        class="inline-flex items-center gap-1 px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors">
  <span class="material-icons text-base">add</span>
  Nueva Conexión
</button>

<%# ❌ INCORRECTO — genéricos o sin entidad %>
  Crear            <%# genérico, no dice qué se crea %>
  Nuevo            <%# falta la entidad %>
  Nuevo Conexión   <%# género mal concordado %>
```

### Alcance

- Aplica **solo** al botón del toolbar que **abre** el formulario de creación.
- El botón **submit** dentro del panel/modal es acción de formulario, no de apertura:
  conserva `Crear` / `Guardar` según corresponda (ver §12). **No** se renombra.
- El género se concuerda con la entidad aunque el patrón nominal sea "Nuevo [X]":
  preferir español gramaticalmente correcto antes que un literal uniforme.

---

## 21. Capitalización de tabs y encabezados — Sentence case

Todo texto de **navegación (tabs)** y todo **encabezado** (títulos de sección, títulos de
panel/diálogo, encabezados de columnas duales) usa **Sentence case**: solo se capitaliza la
**primera palabra** y los **nombres propios**. Nunca Title Case (capitalizar cada palabra).

### Regla

> Tab / encabezado = primera palabra en mayúscula + resto en minúscula (salvo nombres propios).
> Los nombres comunes (usuario, bandeja, compañía, registro, correos…) van en **minúscula**
> cuando no abren la frase.

| ❌ Title Case | ✅ Sentence case |
|---|---|
| `Lista de Usuarios` | `Lista de usuarios` |
| `Completar Registro` | `Completar registro` |
| `Bandeja de Correos` | `Bandeja de correos` |
| `Asignación de Bandejas a Compañías` | `Asignación de bandejas a compañías` |
| `Bandejas Disponibles` | `Bandejas disponibles` |
| `Información de la Bandeja` | `Información de la bandeja` |

### Alcance

Aplica a: etiquetas de tabs, `<h3>`/títulos de panel lateral y modal, encabezados de las
columnas de listas duales (asignación), y cualquier título de sección visible.
Incluye los títulos de panel asignados dinámicamente en JS
(`this.panelTitleTarget.textContent = 'Nueva bandeja'`).

### Excepción única — botón de creación primaria (§20)

El botón del toolbar que abre el formulario de creación **conserva la entidad capitalizada**
(`Nuevo Usuario`, `Nueva Bandeja`) por la regla de §20. Es la **única** excepción: aunque el
panel que abre se titule `Nueva bandeja` (Sentence case), el botón mantiene `Nueva Bandeja`.
Los botones de formulario (`Crear`, `Guardar`, `Modificar`) siguen §12 — no son encabezados.

---

## 22. Formulario de Conexión SAP — está DUPLICADO en tres lugares

El formulario "Nueva Conexión SAP" (campos Servidor, URL API, URL Crystal API, Tipo ODBC,
Motor de Base de Datos, Tipo de Servidor, Usuario/Contraseña de BD, etc.) **NO es un partial
compartido**: el mismo formulario está copiado en tres ubicaciones independientes. Todo cambio
de campos, validación, etiquetas, requeridos o comportamiento **DEBE replicarse en las tres**,
con su vista y su controller correspondientes.

### Las tres ubicaciones

| # | Vista | Controller | Contexto |
|---|---|---|---|
| 1 | `app/views/configurations/connections/index.html.erb` (panel lateral) | `connections_controller.js` | Crear/editar conexión desde el listado de conexiones (panel lateral, paginación remota). **Es el principal y el que ve el usuario normalmente.** |
| 2 | `app/views/configurations/companies/_form.html.erb` (panel lateral, ~línea 750+) | `company_form_controller.js` (targets `conn*`, acciones `*ConnectionPanel`) | Crear conexión **inline** mientras se crea/edita una compañía (botón `add` del campo "Conexión de SAP"). Solo crea, no edita. Reutilizado por `companies/new` y `companies/edit`. |
| 3 | `app/views/configurations/connections/_form.html.erb` (partial nav) | `connection_form_controller.js` | Formulario legacy de navegación (`connections/new` y `connections/edit`). Orfanado por el panel de #1 pero aún ruteado; mantener en sync por seguridad. |

### Prefijos de target por controller

- `connections_controller.js` → targets `f*` (`fServer`, `fDbUser`, `fServerType`, …).
- `company_form_controller.js` → targets `conn*` (`connServer`, `connDbUser`, `connServerType`, …) + acciones `connServerTypeChanged`, `refreshConnSubmitState`.
- `connection_form_controller.js` → targets sin prefijo (`server`, `dbUser`, `serverType`, …).

### Reglas de negocio vigentes del formulario (mantener idénticas en las tres)

- **Motor de Base de Datos** y **Tipo de Servidor** son `<select>` (no inputs libres).
  - Motor: `SQL` (SQL Server) / `HANA` (SAP HANA).
  - Tipo de Servidor: `SQLSERVERT` (SQL Server trusted) / `HANASERVER` (HANA estándar).
    El sufijo `T` = Trusted (autenticación de Windows). Hay un texto-ayuda dinámico (`*ServerTypeHint`)
    bajo el select y un `#*serverTypeHints` map en cada controller.
  - `#applySelectValue` preserva valores legacy fuera del catálogo al editar (inyecta opción temporal).
- **Campos ocultos** (en el DOM, se conservan en el payload): Servidor de Licencias, Idiomas
  Soportados (BoSuppLangs), DST y el check UseTrusted (Trusted) van con clase `hidden`.
- **Tipo ODBC** y **Tipo de Servidor** son **requeridos**.
- **Tipo ODBC** es un combobox: `<input list>` + `<datalist>` con valores sugeridos
  (`HDBODBC`, `SQL Server`) pero **permite escribir un valor personalizado**. El `id` del
  datalist debe ser único por página (`odbc-types-connections` / `odbc-types-company` /
  `odbc-types-connection-form`). Sigue siendo un `input` (no `select`), así que el target y la
  lectura de `.value` no cambian.
- **Usuario y Contraseña de BD** son requeridos **solo cuando Tipo de Servidor = `HANASERVER`**.
  El asterisco rojo del label se muestra/oculta dinámicamente (`#updateCredentialRequirement` /
  `#updateConnCredentialRequirement`).
- **Botón de guardar deshabilitado** hasta que todo lo requerido esté completo: cada panel/form
  tiene `data-action="input->… change->…"` en el contenedor que llama a `refreshSubmitState` /
  `refreshConnSubmitState`, y se invoca también al abrir/resetear/cargar el formulario.

> ⚠️ Antes de tocar el formulario de conexión, buscá las tres ubicaciones
> (`grep -rl "Tipo de Servidor" app/views/configurations`) y aplicá el cambio en todas.

---

## 23. Auth gate del layout protected — script SÍNCRONO en el `<head>`

El guard de autenticación del layout `protected` (`app/views/layouts/protected.html.erb`)
es un **`<script>` clásico síncrono e inline en el `<head>`**, colocado lo más temprano
posible (antes de stylesheets e importmap). Lee `localStorage['Session']` y, si no hay
sesión válida (token presente + `expires_at` no vencido), hace
`window.location.replace('/login')`.

### Por qué vive en el `<head>` y no en un controller Stimulus

Cualquier guard en un controller Stimulus llega **tarde**: los módulos ES son diferidos,
así que el `<body>` protegido **ya se pintó** antes de que el JS corra. Un redirect async
(`window.location.href` en un controller) dejaba ver un instante el menú/home vacío antes
de navegar a login. **Solo un `<script>` síncrono en el `<head>` corre antes del primer
paint** → cero flash.

> ❌ **NO** poner `if (!isSessionValid()) return` repartido en cada controller
> (`menu`, `company-selector`, etc.). Es frágil, no escala y **no elimina el flash**
> (el body ya está pintado cuando Stimulus conecta).

### Reparto de responsabilidades

| Escenario | Quién lo cubre |
|---|---|
| Cold load / F5 / clear-storage | Gate inline en el `<head>` (síncrono, sin flash) |
| Navegación Turbo in-app + token expirado | `auth_guard_controller.js` en `connect()`, vía `isSessionValid()` |

- El gate inline **NO re-corre en navegaciones Turbo** (Turbo fusiona el `<head>` y no
  reejecuta scripts idénticos) — por eso el `auth_guard` se mantiene para ese caso.
- `isSessionValid()` (`vendor/clavisco/core`) es la **fuente única** de la regla de validez.
  El script del head **inlinea** la misma lógica (no la importa) porque debe ser bloqueante;
  un módulo ES sería diferido y pintaría la página antes de ejecutarse.

### ⚠️ Migración futura a IdP — revisar o eliminar este gate

Próximamente se quitará la página de login de la aplicación y se redirigirá a un **IdP
externo** (OIDC/SAML). El gem/paquete del IdP (p. ej. `omniauth`, `devise` + `omniauth-oidc`,
o el SDK del proveedor) **normalmente ya valida la sesión y redirige al login del IdP por sí
mismo**, típicamente del lado servidor (middleware/before_action) o vía su propio guard.

Cuando se haga esa migración, **revisar si este gate inline sigue siendo necesario**:

- Si el IdP valida y redirige **del lado servidor** (lo más probable): este script del
  `<head>` queda **redundante** → **eliminarlo** junto con `isSessionValid()` / la lógica
  de `Session` en `localStorage`, ya que la sesión pasará a vivir en cookie/servidor.
- Si la app sigue siendo SPA con token en `localStorage` tras el IdP: **adaptar** la regla
  de validez del gate (y de `isSessionValid()`) al nuevo formato de token/claims del IdP.

> No olvidar: al migrar a IdP, este gate y `auth_guard_controller.js` son los dos puntos
> que tocan la sesión client-side — ambos deben revisarse en esa tarea.

---

## 24. TODOS.md — deuda técnica pendiente de actualización del API

En el **root del proyecto** existe `TODOS.md`. Es el registro de cambios de UI que
**ya se aplicaron en las vistas pero que NO se pueden completar todavía en el cliente del
API** porque el backend aún no se ha actualizado.

### Contexto — por qué existe

Cuando se elimina un campo de un formulario que el usuario considera innecesario, la regla es:

1. **Quitar el campo de la vista** (input/label/panel) — esto sí se hace de una vez.
2. **NO quitar el campo del fetch ni del parámetro que se envía al API.** El backend todavía
   espera ese campo; si se elimina ahora, la llamada falla. En su lugar, **enviar un valor
   por defecto** desde el controller para mantener el contrato vigente.
3. **Anotar en `TODOS.md`** que, cuando el API se actualice, hay que terminar de eliminar ese
   campo del `body`/parámetros del fetch y del payload.

### Cuándo se conserva la consulta y cuándo se elimina de una vez

El paso 2 (conservar con valor por defecto + anotar en `TODOS.md`) aplica **solo** cuando la
consulta es **necesaria para la vista** y el campo eliminado es **uno de sus parámetros**.
Si la consulta existe **únicamente** para alimentar el campo eliminado, se elimina completa
en el mismo cambio (no es deuda pendiente).

| Caso | Relación con el campo eliminado | Acción |
|---|---|---|
| Consulta necesaria para la vista; el campo es un parámetro más | El campo es **un input** de la consulta | **Conservar** la consulta + enviar valor por defecto + entrada en `TODOS.md` |
| Consulta cuyo único fin era poblar el campo eliminado | El campo es el **dependiente** de la consulta | **Eliminar** la consulta, su método y su estado ahora mismo |

> Ejemplo real (`email_senders_controller.js`): `POST SearchEmailConfig` es la búsqueda que
> alimenta la tabla → se conserva y `Host` se manda `''`. `GET GetHost` solo llenaba el
> dropdown de Host → se eliminó por completo (método `#loadHosts`, llamada y `#hostList`).

### Regla obligatoria

> Cada vez que se elimine un campo visible de un formulario pero se mantenga en la petición
> al API con un valor por defecto, **DEBE** agregarse una entrada en `TODOS.md` describiendo
> exactamente qué falta limpiar cuando el backend se actualice (archivo, controller, campo,
> valor por defecto que se está enviando).

### Formato de cada entrada en `TODOS.md`

```markdown
## [Módulo / Formulario]

- [ ] Campo `NombreCampo` — eliminado de la vista en `ruta/vista.html.erb`.
      Aún se envía en el fetch de `controller_x.js` con valor por defecto `"..."`.
      **Pendiente API:** quitar `NombreCampo` del body/parámetros una vez el endpoint
      `/api/Endpoint` deje de requerirlo.
```

Antes de marcar una entrada como hecha (`[x]`) confirmar que el endpoint ya no exige el campo.

---

## 25. Tooltips flotantes — SIEMPRE completamente visibles dentro del viewport

Todo tooltip flotante (`position: fixed`, el `#cl-tabulator-tooltip` y cualquier variante)
**DEBE** quedar **completamente visible**: nunca cortado por los bordes de la página. El bug
recurrente es posicionarlo con un offset fijo respecto al cursor (`clientX + 10`,
`clientY - 32`) sin considerar los límites del viewport → cerca del borde derecho o superior
se recorta y el texto queda ilegible.

### Reglas obligatorias

1. **Límite de ancho** — el tooltip nunca puede exceder el ancho de la ventana. Usar
   `max-width: min(320px, calc(100vw - 16px))` + `white-space: normal` + `word-break: break-word`.
   Así los textos largos **envuelven** en varias líneas en vez de desbordarse.
   **NO** usar `white-space: nowrap` sin `max-width` (esa combinación es la causa del recorte horizontal).
2. **Reposicionamiento (flip + clamp)** — antes de mostrarlo, medir su tamaño con
   `getBoundingClientRect()` y colocarlo así:
   - Por defecto **arriba** del cursor (`top = clientY - h - 10`).
   - Si se sale por la **derecha** → flip a la izquierda del cursor (`left = clientX - w - 12`).
   - **Clamp** final contra los cuatro bordes con un margen (`8px`): `left`/`top` nunca
     menores al margen ni mayores a `innerWidth/innerHeight - tamaño - margen`.
   - Si no hay espacio **arriba** → mostrarlo **abajo** del cursor (`top = clientY + 18`).
3. **Posicionar en `mouseover` y en `mousemove`** — llamar al reposicionamiento en ambos
   eventos (no solo en `mousemove`) para que el primer render ya aparezca en el lugar correcto,
   sin parpadeo en coordenadas viejas.

### Implementación de referencia

```js
const place = (e) => {
  const margin = 8;
  const { width: w, height: h } = tip.getBoundingClientRect();
  let left = e.clientX + 12;
  let top  = e.clientY - h - 10;                               // arriba del cursor
  if (left + w + margin > window.innerWidth) left = e.clientX - w - 12;   // flip izquierda
  if (left < margin) left = margin;
  if (left + w + margin > window.innerWidth) left = window.innerWidth - w - margin;
  if (top < margin) top = e.clientY + 18;                     // sin espacio arriba → abajo
  if (top + h + margin > window.innerHeight) top = window.innerHeight - h - margin;
  tip.style.left = left + 'px';
  tip.style.top  = top + 'px';
};
```

Estilo del elemento tooltip (garantiza el ajuste horizontal):

```js
tip.style.cssText = [
  'position:fixed', 'z-index:9999', 'pointer-events:none',
  'background:#1f2937', 'color:#fff', 'padding:4px 8px',
  'border-radius:4px', 'font-size:12px', 'line-height:1.35',
  'max-width:min(320px, calc(100vw - 16px))',
  'white-space:normal', 'word-break:break-word', 'text-align:left',
  'opacity:0', 'transition:opacity 0.15s',
].join(';');
```

### Alcance

- Aplica a **todos** los tooltips flotantes de la app: los de botones de acción en tablas
  Tabulator (§2), los de botones deshabilitados (§2) y los del toolbar.
- **Ya aplicado de forma global** en el `setupTooltip()` base de `TabulatorController`
  (`app/javascript/vendor/clavisco/tabulator/controllers/tabulator_controller.js`): todos los
  controllers que hacen `super.connect()` heredan el reposicionamiento automáticamente, sin
  cambios por vista.
- Cualquier delegación **local** de tooltips (ej. `#setupTooltips()` en controllers que
  construyen sus tablas manualmente sin usar el base, como `numbering_controller.js`) **debe**
  replicar el mismo `place()` con clamp. Al crear una nueva, copiar el patrón del base.

---

## 26. Acciones sin permiso — DESHABILITAR + tooltip explicativo, NO ocultar

Cuando el usuario **no** tiene el permiso requerido para una acción (crear, editar, anular,
reprocesar, etc.), el control **NO se oculta**: se **deshabilita** y muestra un **tooltip con
el motivo**. Ocultar el botón deja al usuario sin pistas de que la acción existe ni de cómo
obtenerla; deshabilitarlo con explicación le dice qué falta.

### Regla

> Acción no permitida ⇒ botón/control **`disabled`** (estilo gris) **+ `data-tooltip` con el
> motivo específico**. Nunca `hidden`/`display:none` para gating por permisos.

- El texto del tooltip sigue §2 (específico, responde *¿cuándo SÍ podré usarlo?*). Para
  permisos el patrón es **`"No cuenta con permisos para <acción concreta>"`**
  (ej. `"No cuenta con permisos para crear numeraciones de emisión"`).
- El tooltip flotante se posiciona según §25 (siempre completamente visible).
- **Defensa en profundidad:** además de deshabilitar en la UI, el método de la acción debe
  reverificar el permiso al inicio y abortar (con toast `info`) si falta — la UI puede ser
  manipulada.

### Detalle de implementación — botón deshabilitado + tooltip

Un `<button disabled>` **no emite eventos de mouse**, así que el `data-tooltip` debe ir en un
**`<span>` envolvente** (que sí los recibe) y el botón lleva `pointer-events-none` para dejar
pasar el hover al span:

```html
<span data-tooltip="No cuenta con permisos para editar numeraciones de emisión">
  <button type="button" disabled
          class="p-1.5 text-gray-300 rounded cursor-not-allowed pointer-events-none">
    <span class="material-icons text-base">edit</span>
  </button>
</span>
```

Botones del **toolbar** (fuera de Tabulator): nacen deshabilitados (gris) con el tooltip en su
`<span>` envolvente y se **habilitan desde el controller** solo si hay permiso (quitando
`disabled`, cambiando el color y removiendo el `data-tooltip`). Referencia:
`numbering_controller.js` (`#enableCreateButton`) + `configurations/numbering/index.html.erb`.

```js
// connect() — habilitar solo con permiso; si no, queda gris + tooltip del HTML
if (this.#hasPerm('Configurations_Numbering_Create')) {
  this.#enableCreateButton(this.btnCreateNumberingTarget, this.btnCreateNumberingWrapTarget);
}

// action pública — reverificar (defensa en profundidad)
openCreateNumbering() {
  if (!this.#hasPerm('Configurations_Numbering_Create')) {
    showToast('No cuenta con permisos para realizar esta acción.', 'info');
    return;
  }
  // ...
}
```

### Excepción

Los **botones de submit dentro de un formulario** que se deshabilitan por **validación**
(campos incompletos), no por permisos, siguen §22/§12 (`disabled:opacity-50` mientras falte
algo). Esta sección aplica al **gating por permisos** de acciones.

---

## 27. Submódulos — PROHIBIDO modificar su código fuente

Todo lo que vive bajo `vendor/clavisco/` (`structures`, `common`, `data_access`, `auth`, …)
es un **git submodule**: otro repositorio, compartido por todos los productos Clavisco.

> **Regla:** nunca crear, editar ni borrar archivos dentro de `vendor/clavisco/*`.
> Eso incluye `lib/`, `test/` y `README.md`. Sin excepciones, ni siquiera para
> "arreglar un bug obvio" o "agregar una clase que falta".

### Por qué

- El commit del producto **no lleva el contenido** del submódulo, solo un puntero a un SHA.
  Un cambio local queda fuera del PR: nadie lo revisa y nadie lo recibe. Quien clone el repo
  y haga `git submodule update` obtiene el código original → **la app no arranca** si el
  producto empezó a depender de algo que solo existía en la copia local.
- Es código compartido y de seguridad: un cambio pensado para este producto puede romper
  otro sin que nadie lo note hasta producción.
- El working tree del submódulo se revierte con un `submodule update` — el trabajo se pierde
  en silencio.

### Qué hacer cuando el submódulo no ofrece lo que se necesita

1. **Implementarlo del lado de la app**, envolviendo lo que el submódulo sí expone
   (un método privado en el controller, un service object, una subclase). Es el patrón
   adaptador: el producto se acomoda, el submódulo no se toca.
2. **Anotar la deuda en `TODOS.md`**, en la sección *Submódulos*, describiendo el cambio que
   hace falta aguas arriba: repo, archivo, método y qué debería recibir/devolver.
3. **Dejar un comentario en el código de la app** que apunte a esa entrada, para que el
   workaround se pueda borrar el día que el submódulo lo soporte.

```ruby
# ✅ CORRECTO — el submódulo arma la URL sin id_token_hint; se agrega acá.
#    Ver TODOS.md → Submódulos → cl-auth-ruby.
def provider_logout_url(return_to, id_token_hint)
  url = oidc_client(redirect_uri: nil).logout_url(return_to: return_to)
  # ...
end

# ❌ INCORRECTO — editar vendor/clavisco/auth/lib/clavisco/auth/oidc_client.rb
#    para que logout_url acepte id_token_hint.
```

### Verificación obligatoria antes de dar por terminado un cambio

```bash
git submodule foreach --quiet 'git status --porcelain | grep . && echo "SUCIO: $name" || true'
# No debe imprimir nada. Cualquier salida significa que se tocó un submódulo.
```

Si ya se modificó uno por error: `git -C vendor/clavisco/<x> checkout -- .` y borrar a mano
los archivos sin trackear que se hayan creado.

### Actualizar un submódulo sí es válido — pero es otra tarea

Mover el puntero a un commit nuevo (`git -C vendor/clavisco/auth fetch && git checkout <sha>`)
es legítimo **cuando el cambio ya fue mergeado en el repo del submódulo**. Lo prohibido es
editar sus archivos desde el producto.

---

## 28. Endpoints migrados a Rails — convención de nombrado REST

El API .NET nombra sus endpoints con el verbo dentro del path y en PascalCase
(`GET /api/User/GetUserInfo`, `PATCH /api/User/profile-info`,
`POST /api/Connections/validate-user-credentials`, `GET /api/Permission/GetPermsByUser`).
**Esos nombres no se copian al migrar.** Cada endpoint que pasa a Rails se renombra a REST;
el nombre viejo sobrevive únicamente mientras el endpoint siga cayendo en el catch-all del
proxy (`match '/api/*path', to: 'proxy#forward'`).

### Reglas

1. **El verbo va en el método HTTP, nunca en el path.**
   `GET /api/companies`, no `GET /api/Companies/GetCompanies`.
   Si el nombre del path contiene `Get`, `Update`, `Patch`, `Create`, `Delete`, `Validate`,
   `Search` o `By`, está mal.
2. **El path nombra un recurso, en `snake_case` y en plural.**
   `/api/sap_credential_validations`, no `/api/validate-user-credentials`.
   Ni PascalCase (`/api/User`) ni kebab-case (`/api/profile-info`).
3. **Recurso singular cuando siempre es uno solo y sale de la sesión** — se declara con
   `resource` (sin `s`) y **no lleva id**: `resource :profile` → `GET|PATCH /api/profile`.
   Que el id no viaje es la garantía de que nadie lee ni escribe el registro ajeno.
4. **Una acción que no es CRUD se modela como el recurso que produce.**
   Validar credenciales crea una *validación* → `POST /api/sap_credential_validations`
   (`only: [:create]`). No se inventan actions sueltas tipo `post 'sap/validate'`.
5. **`companyId` no viaja como parámetro.** La compañía activa vive en la session cookie
   (§2.4 del estándar) y la lee el servidor: `GET /api/permissions`, no
   `GET /api/permissions?companyId=3`. **Excepción:** cuando la pantalla deja elegir
   explícitamente contra qué compañía operar y esa puede no ser la activa — ahí sí va en el
   cuerpo, y el controller **debe** validar que esté asignada al usuario
   (`Company.assigned_to(Current.user.id).find_by(id: ...)`), como hacen
   `Api::SessionsController` y `Api::SapCredentialValidationsController`.
6. **Los ids ajenos tampoco viajan.** Si el recurso es del usuario en sesión, se resuelve con
   `Current.user`; un `Id` que llegue en el body se ignora.
7. **El cuerpo y la respuesta JSON siguen en PascalCase** (`SapUser`, `Data`, `Code`,
   `Message`). Eso es contrato con el frontend y con `ApiResponse` — lo que se normaliza es
   la **URL**, no las llaves del JSON.
8. **La ruta nueva va dentro de `namespace :api`, arriba del catch-all del proxy.** Ese orden
   es lo que hace que el endpoint migrado le gane al reenvío al .NET.

### Tabla de traducción (endpoints ya migrados)

| API .NET | Rails |
|---|---|
| `GET /api/Companies/GetCompanies?ComercialName=&...` | `GET /api/companies` |
| `GET /api/Permission/GetPermsByUser?companyId=N` | `GET /api/permissions` |
| `GET /api/User/GetUserInfo` | `GET /api/profile` |
| `PATCH /api/User/profile-info` | `PATCH /api/profile` |
| `POST /api/Connections/validate-user-credentials` | `POST /api/sap_credential_validations` |
| (nuevo — la compañía activa era `sessionStorage`) | `PUT /api/session/company` |

### Patrón

```ruby
# config/routes.rb — ✅ CORRECTO
namespace :api do
  resources :companies, only: [:index]              # GET  /api/companies
  resource  :profile,   only: %i[show update]       # GET|PATCH /api/profile
  resources :sap_credential_validations, only: [:create]
end

# ❌ INCORRECTO — se copió el nombre del .NET
namespace :api do
  get  'User/GetUserInfo',                   to: 'users#get_user_info'
  post 'Connections/validate-user-credentials', to: 'connections#validate'
end
```

### Del lado del JS

Al migrar un endpoint hay que **actualizar todos los `fetch` que lo llaman** — si queda uno
apuntando al nombre viejo, sigue cayendo al proxy y al .NET (que hoy responde 401, ver
`TODOS.md`) sin ningún error visible.

```bash
# Antes de dar por migrado un endpoint: no debe quedar ninguna referencia al nombre viejo
grep -rn "GetUserInfo\|profile-info" app/javascript
```

Los endpoints nativos usan la session cookie: en su `#apiFetch` **no** se arma header
`Authorization` — basta `getApiHeaders()` de `vendor/clavisco/core`.

---

## 29. Acceso a SAP — SIEMPRE por `Clavisco::ServiceLayer::Client`

Todo llamado a SAP Business One pasa por el submódulo
`vendor/clavisco/service_layer` (`ClavisCo/cl-sap-servicelayer-ruby`).
**Está prohibido hablar HTTP a mano con el Service Layer** — sin Faraday, sin `Net::HTTP`,
sin `HTTParty`, ni siquiera para un solo `/Login`.

> **Regla del estándar** (CLAVISCO-PLATFORM-STANDARDS §2.7): *«Nunca crear sesiones SAP por
> request. Usar el session pool singleton del Client.»*

```ruby
client = Clavisco::ServiceLayer::Client.new(
  base_url:         company.sap_connection.sl_url,
  company_db:       company.sap_db_code,
  username:         user.sap_user,
  password:         user.sap_password,
  session_owner_id: Current.user.id     # llave del pool: owner|company_db|username
)

client.get('BusinessPartners', params: { '$top' => 10 })
client.post('Orders', body: payload)
client.patch('Orders(123)', body: payload)
client.delete('Orders(123)')
```

### De dónde salen `base_url` y `company_db`

**Nunca de variables de entorno.** El ejemplo de §2.7 usa `SAP_SL_URL`/`SAP_COMPANY_DB` porque
asume un solo servidor; este producto es multi-compañía, así que:

| Dato | Fuente |
|---|---|
| `base_url` | `connections.sl_url` (vía `companies.connection_id`) |
| `company_db` | `companies.sap_db_code` |
| `username` / `password` | `users.sap_user` / `users.sap_password` (ver deuda en `TODOS.md`: el estándar los quiere en `sap_licenses`) |

### El pool, y por qué no se cierra la sesión

El Client se autentica solo en el primer request y guarda la sesión en un `LoadBalancer`
singleton con la llave `session_owner_id|company_db|username`. **No llamar `logout` al terminar
una operación:** eso vuelve a "una sesión por request", justo lo que la regla prohíbe. La sesión
se reutiliza y expira sola (20 min).

### Errores

`Clavisco::ServiceLayer::Client::ServiceLayerError` y sus subclases
(`AuthenticationError`, `SessionExpiredError`, `NotFoundError`) llevan `status_code`,
`sap_error_code` y `sap_message`. Al mostrarle el motivo al usuario, usar `sap_message` y
quitar el prefijo del cliente (`SL Login failed: …`) — le sirve el error de SAP, no en qué capa
se detectó.

### La contraseña de SAP se guarda cifrada

`users.sap_password` lleva `encrypts` (ActiveRecord Encryption) — cifrado **reversible**, no
un digest: el Service Layer exige la contraseña en claro para el `/Login`.

```ruby
class User < ApplicationRecord
  encrypts :sap_password   # cifra al escribir, descifra al leer, transparente
end
```

Tres reglas que cuestan caro si se olvidan:

1. **`encrypts` solo actúa al escribir el atributo.** Una fila insertada por fuera del modelo
   (SQL directo, importación, seed) se queda en texto plano y nadie avisa. Si se agrega una
   columna cifrada sobre datos que ya existen, hay que migrarlos — ver
   `db/migrate/20260812110000_encrypt_existing_sap_passwords.rb` como patrón: leer el crudo
   con SQL, serializar con `type_for_attribute(...).serialize` y escribir con `UPDATE`.
   Reasignar el atributo con el mismo valor **no** dispara el UPDATE (dirty tracking no ve
   cambio).
2. **`support_unencrypted_data = false`.** Leer una fila en claro levanta en vez de devolverla.
   No volver a ponerlo en `true` para "arreglar" un error de lectura: ese error está avisando
   que hay un dato sin cifrar.
3. **Todo campo sensible nuevo va también a `filter_parameters`**
   (`config/initializers/filter_parameter_logging.rb`). Cifrar la columna no sirve si el valor
   queda escrito en `log/*.log` — que es exactamente lo que pasaba con `SapPass`.
4. **Nunca ponerle `limit:` a una columna cifrada pensando en el largo del dato.** Lo guardado
   es un sobre JSON (`{"p":…,"h":{"iv":…,"at":…}}`): ~70 caracteres fijos más 4/3 del texto
   original. Una contraseña de 50 chars ocupa **138**. SQLite ignora el largo de `varchar`, así
   que hoy no molesta, pero si la base se muda a una que sí lo respeta hay que dimensionar
   contra el cifrado, no contra el dato. Las validaciones de largo del modelo sí miran el texto
   original (`validates :sap_password, length: { maximum: 50 }`), que es lo correcto.

El cifrado es **no determinista**: el mismo valor produce un texto distinto cada vez, porque el
IV es aleatorio. Consecuencia: no se puede buscar por esa columna (`where(sap_password: x)`
nunca encuentra nada) ni ponerle un índice único. Si algún día hace falta buscar por un campo
cifrado, se declara `encrypts :campo, deterministic: true`.

### Referencia

`app/services/sap/credential_validator.rb` es el consumidor de ejemplo en este proyecto.
Ojo con su rodeo documentado: el Client no expone un `login` suelto, así que para *solo*
validar credenciales hay que forzar la autenticación con un GET de sondeo y desambiguar con el
pool. Está anotado en `TODOS.md` como deuda del submódulo — **no copiar ese patrón** para
operaciones normales, que simplemente llaman `get`/`post`/`patch`/`delete`.
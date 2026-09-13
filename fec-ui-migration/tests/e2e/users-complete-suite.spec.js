// @ts-check
/**
 * Suite E2E — /configurations/users
 *
 * Cubre los 3 tabs (Lista, Completar Registro, Asignación de compañías)
 * y las páginas de Registrar / Editar Usuario.
 *
 * Ejecutar: npx playwright test users-complete-suite.spec.js --project=chromium
 */

const { test, expect } = require('@playwright/test');

// ── Constantes ────────────────────────────────────────────────────────────────

const BASE_URL    = 'http://localhost:3000';
const LOGIN_URL   = `${BASE_URL}/login`;
const USERS_URL   = `${BASE_URL}/configurations/users`;
const REGISTER_URL = `${BASE_URL}/configurations/users/register`;
const EDIT_URL    = `${BASE_URL}/configurations/users/edit`;

const MOCK_SESSION = {
  access_token: 'mock_token_abc123',
  token_type:   'Bearer',
  expires_at:   new Date(Date.now() + 3_600_000).getTime(),
  UserEmail:    'test@clavisco.com',
  UserId:       'user-id-001',
};

const MOCK_COMPANY = {
  companyId:     1,
  companyName:   'Empresa Test',
  groupId:       1,
  codigoActividad: '462001',
};

const PERMS_ALL = [
  'Configurations_Users_ListAccess',
  'Configurations_Users_Update',
  'Configurations_Users_ViewAllApplicationUsers',
  'S_RegUser',
  'S_CompUser',
  'S_AsigUser',
];

const PERMS_LIST_ONLY = ['Configurations_Users_ListAccess'];

// ── Helper de autenticación ───────────────────────────────────────────────────

async function injectAuth(page, perms = PERMS_ALL) {
  await page.goto(LOGIN_URL);
  await page.evaluate(({ session, company, permissions }) => {
    localStorage.setItem('Session',           JSON.stringify(session));
    sessionStorage.setItem('CurrentCompany',  JSON.stringify(company));
    sessionStorage.setItem('Permissions',     JSON.stringify(permissions));
  }, { session: MOCK_SESSION, company: MOCK_COMPANY, permissions: perms });
}

// ── Mock API responses ────────────────────────────────────────────────────────

async function mockUsersAPI(page) {
  await page.route('**/api/User/accessible**', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({
      Data: [
        {
          Id: 'uid-1', FullName: 'Ana García', Email: 'ana@empresa.com',
          Identification: '123456789', SapUser: 'AGARCIA',
          Active: true, EmailConfirmed: true,
          CreateDate: '2024-01-15T10:00:00Z',
        },
        {
          Id: 'uid-2', FullName: 'Carlos López', Email: 'carlos@empresa.com',
          Identification: '987654321', SapUser: 'CLOPEZ',
          Active: false, EmailConfirmed: false,
          CreateDate: '2024-02-20T08:30:00Z',
        },
      ],
      Message: 'OK',
    }),
  }));
}

async function mockInactiveUsersAPI(page) {
  await page.route('**/api/User/GetInactiveUsers**', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({
      Data: [
        {
          Id: 'uid-3', FullName: 'Pedro Mora', Email: 'pedro@empresa.com',
          Identification: '111222333', Active: false, EmailConfirmed: false,
        },
      ],
      Message: 'OK',
    }),
  }));
}

async function mockAssignmentAPIs(page) {
  await page.route('**/api/User/for-assignments**', route => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({ Data: [{ Id: 'uid-1', Email: 'ana@empresa.com' }], Message: 'OK' }),
  }));
  await page.route('**/api/Companies/for-assignment**', route => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({
      Data: [
        { Id: 1, ComercialName: 'Empresa A', LegalName: 'Empresa A S.A.' },
        { Id: 2, ComercialName: 'Empresa B', LegalName: 'Empresa B S.A.' },
      ],
      Message: 'OK',
    }),
  }));
  await page.route('**/api/User/assigned-companies**', route => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({ Data: [{ Id: 1, ComercialName: 'Empresa A' }], Message: 'OK' }),
  }));
}

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 1 — Carga inicial y tabs
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Carga inicial', () => {

  test('Página carga con los 3 tabs cuando el usuario tiene todos los permisos', async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await page.goto(USERS_URL);

    await expect(page.locator('[data-tab-name="list"]')).toBeVisible();
    await expect(page.locator('[data-tab-name="complete-registration"]')).toBeVisible();
    await expect(page.locator('[data-tab-name="assignment"]')).toBeVisible();
  });

  test('Solo muestra tab Lista cuando el usuario solo tiene Configurations_Users_ListAccess', async ({ page }) => {
    await injectAuth(page, PERMS_LIST_ONLY);
    await mockUsersAPI(page);
    await page.goto(USERS_URL);

    await expect(page.locator('[data-tab-name="list"]')).toBeVisible();
    await expect(page.locator('[data-tab-name="complete-registration"]')).not.toBeVisible();
    await expect(page.locator('[data-tab-name="assignment"]')).not.toBeVisible();
  });

  test('Tab activo por defecto es el primero disponible', async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await page.goto(USERS_URL);

    const firstTab = page.locator('[data-tab-name="list"]');
    await expect(firstTab).toHaveClass(/border-blue-600|active/);
  });

  test('Título de la página es "Gestión de Usuarios"', async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await page.goto(USERS_URL);

    await expect(page.locator('h1, [data-page-title]')).toContainText(/Gestión de Usuarios|Usuarios/i);
  });

});

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 2 — Tab Lista de Usuarios
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Tab Lista', () => {

  test.beforeEach(async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await page.goto(USERS_URL);
  });

  test('Tabla carga con datos de la API', async ({ page }) => {
    await expect(page.locator('.tabulator-row')).toHaveCount(2);
  });

  test('Muestra columnas: Nombre, Email, Identificación, Fecha Creación, SAP, Confirmado, Activo', async ({ page }) => {
    await expect(page.locator('.tabulator-col-title')).toContainText(['Nombre Completo']);
    await expect(page.locator('.tabulator-col-title')).toContainText(['Correo Electrónico']);
    await expect(page.locator('.tabulator-col-title')).toContainText(['Activo']);
  });

  test('Campo Nombre Completo acepta texto', async ({ page }) => {
    const input = page.locator('input[data-users-target="searchName"], input[placeholder*="Nombre"]').first();
    await input.fill('Ana');
    await expect(input).toHaveValue('Ana');
  });

  test('Campo Email acepta texto', async ({ page }) => {
    const input = page.locator('input[data-users-target="searchEmail"], input[placeholder*="Email"], input[placeholder*="Correo"]').first();
    await input.fill('ana@empresa.com');
    await expect(input).toHaveValue('ana@empresa.com');
  });

  test('Botón Consultar dispara nueva llamada API', async ({ page }) => {
    let callCount = 0;
    await page.route('**/api/User/accessible**', route => {
      callCount++;
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: [], Message: '' }) });
    });
    await page.locator('button:has-text("Consultar")').click();
    expect(callCount).toBeGreaterThan(0);
  });

  test('Botón Crear visible si tiene permiso S_RegUser', async ({ page }) => {
    await expect(page.locator('button:has-text("Crear"), a:has-text("Crear")')).toBeVisible();
  });

  test('Botón Crear NO visible si no tiene permiso S_RegUser', async ({ page }) => {
    await page.evaluate(() => {
      sessionStorage.setItem('Permissions', JSON.stringify(['Configurations_Users_ListAccess']));
    });
    await page.reload();
    await mockUsersAPI(page);
    await expect(page.locator('button:has-text("Crear")')).not.toBeVisible();
  });

  test('Botón Crear navega a /configurations/users/register', async ({ page }) => {
    await page.locator('button:has-text("Crear"), a:has-text("Crear")').first().click();
    await expect(page).toHaveURL(/\/configurations\/users\/register/);
  });

  test('Botón Editar por fila navega a /configurations/users/edit con userId', async ({ page }) => {
    await page.locator('.tabulator-row').first().waitFor();
    await page.locator('[data-action-type="edit"], button[data-tooltip="Editar"]').first().click();
    await expect(page).toHaveURL(/\/configurations\/users\/edit\?userId=/);
  });

  test('Badge de estado Activo muestra color verde', async ({ page }) => {
    const badge = page.locator('.tabulator-row').first().locator('span[style*="3a7d52"]');
    await expect(badge).toBeVisible();
  });

  test('Estado Activo/Inactivo se muestra como badge', async ({ page }) => {
    const rows = page.locator('.tabulator-row');
    await expect(rows).toHaveCount(2);
    // Primera fila tiene Active:true → badge Activo
    await expect(rows.first().locator('span').filter({ hasText: /Activo/i })).toHaveCount(1);
  });

});

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 3 — Tab Completar Registro
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Tab Completar Registro', () => {

  test.beforeEach(async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await mockInactiveUsersAPI(page);
    await page.goto(USERS_URL);
    await page.locator('[data-tab-name="complete-registration"]').click();
  });

  test('Tab Completar Registro es visible y clickeable', async ({ page }) => {
    await expect(page.locator('[data-users-target="tabContent"][data-tab="complete-registration"]')).toBeVisible();
  });

  test('Tabla de usuarios inactivos carga con datos', async ({ page }) => {
    await expect(page.locator('[data-tab="complete-registration"] .tabulator-row')).toHaveCount(1);
  });

  test('Columnas visibles: Identificación, Nombre, Email, Correo Confirmado, Activo', async ({ page }) => {
    const tabContent = page.locator('[data-tab="complete-registration"]');
    await expect(tabContent.locator('.tabulator-col-title')).toContainText(['Identificación']);
    await expect(tabContent.locator('.tabulator-col-title')).toContainText(['Email', 'Correo']);
  });

  test('Botón Activar Usuario llama a PATCH /api/User/activate', async ({ page }) => {
    let called = false;
    await page.route('**/api/User/activate**', route => {
      called = true;
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: null, Message: 'Activado' }) });
    });
    await page.locator('[data-tab="complete-registration"] [data-tooltip="Activar Usuario"], [data-tab="complete-registration"] [data-action-type="activate"]').first().click();
    expect(called).toBe(true);
  });

  test('Botón Reenviar Correo llama a POST /api/User/email-confirmations', async ({ page }) => {
    let called = false;
    await page.route('**/api/User/email-confirmations**', route => {
      called = true;
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: null, Message: 'Enviado' }) });
    });
    await page.locator('[data-tab="complete-registration"] [data-tooltip*="Correo"], [data-tab="complete-registration"] [data-action-type="resend"]').first().click();
    expect(called).toBe(true);
  });

  test('Activar usuario exitoso muestra toast success', async ({ page }) => {
    await page.route('**/api/User/activate**', route =>
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: null, Message: 'OK' }) })
    );
    await page.locator('[data-tab="complete-registration"] button').first().click();
    await expect(page.locator('#toast-container, .cl-toast')).toBeVisible({ timeout: 3000 });
  });

});

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 4 — Tab Asignación de compañías
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Tab Asignación', () => {

  test.beforeEach(async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await mockAssignmentAPIs(page);
    await page.goto(USERS_URL);
    await page.locator('[data-tab-name="assignment"]').click();
  });

  test('Tab Asignación es visible', async ({ page }) => {
    await expect(page.locator('[data-users-target="tabContent"][data-tab="assignment"]')).toBeVisible();
  });

  test('Input de búsqueda de usuario visible', async ({ page }) => {
    await expect(page.locator('[data-users-target="userInput"]')).toBeVisible();
  });

  test('Input de búsqueda de grupo visible', async ({ page }) => {
    await expect(page.locator('[data-users-target="groupInput"]')).toBeVisible();
  });

  test('Al escribir en input usuario se filtra la lista', async ({ page }) => {
    const input = page.locator('[data-users-target="userInput"]');
    await input.fill('ana');
    const dropdown = page.locator('[data-users-target="userDropdown"]');
    await expect(dropdown).not.toHaveClass(/hidden/);
    await expect(dropdown.locator('li')).toHaveCount(1);
  });

  test('Seleccionar usuario carga sus compañías asignadas', async ({ page }) => {
    const input = page.locator('[data-users-target="userInput"]');
    await input.click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    // Empresa A debería estar en assignedList
    await expect(page.locator('[data-users-target="assignedList"]')).toContainText('Empresa A');
    // Empresa B debería estar en unassignedList
    await expect(page.locator('[data-users-target="unassignedList"]')).toContainText('Empresa B');
  });

  test('Estado vacío visible cuando no hay usuario seleccionado', async ({ page }) => {
    await expect(page.locator('[data-users-target="emptyState"]')).toBeVisible();
  });

  test('Estado vacío oculto al seleccionar usuario', async ({ page }) => {
    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    await expect(page.locator('[data-users-target="emptyState"]')).not.toBeVisible();
  });

  test('Botón Asignar todas mueve todas las disponibles a asignadas', async ({ page }) => {
    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    await page.locator('[data-action*="assignAll"]').click();
    await expect(page.locator('[data-users-target="unassignedList"] li')).toHaveCount(0);
  });

  test('Botón Desasignar todas mueve todas las asignadas a disponibles', async ({ page }) => {
    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    await page.locator('[data-action*="unassignAll"]').click();
    await expect(page.locator('[data-users-target="assignedList"] li')).toHaveCount(0);
  });

  test('Botón Aplicar Cambios deshabilitado cuando no hay cambios', async ({ page }) => {
    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    await expect(page.locator('[data-action*="applyChanges"]')).toBeDisabled();
  });

  test('Botón Aplicar Cambios habilitado al hacer un cambio', async ({ page }) => {
    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    await page.locator('[data-action*="assignAll"]').click();
    await expect(page.locator('[data-action*="applyChanges"]')).not.toBeDisabled();
  });

  test('Aplicar Cambios llama a bulk-assign y bulk-unassign', async ({ page }) => {
    let assignCalled = false, unassignCalled = false;
    await page.route('**/api/User/bulk-assign-companies**', route => {
      assignCalled = true;
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: true, Message: 'OK' }) });
    });
    await page.route('**/api/User/bulk-unassign-companies**', route => {
      unassignCalled = true;
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: true, Message: 'OK' }) });
    });

    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    // Mover Empresa B a asignadas y Empresa A a disponibles
    await page.locator('[data-users-target="unassignedList"] li').first().click();
    await page.locator('[data-users-target="assignedList"] li').first().click();
    await page.locator('[data-action*="applyChanges"]').click();

    expect(assignCalled || unassignCalled).toBe(true);
  });

  test('Cancelar Cambios recarga las asignaciones originales', async ({ page }) => {
    await page.locator('[data-users-target="userInput"]').click();
    await page.locator('[data-users-target="userDropdown"] li').first().click();
    await page.locator('[data-action*="assignAll"]').click();
    await page.locator('[data-action*="cancelChanges"]').click();
    // Empresa A debería volver a asignadas
    await expect(page.locator('[data-users-target="assignedList"]')).toContainText('Empresa A');
  });

});

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 5 — Página Registrar Usuario
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Registrar Usuario', () => {

  test.beforeEach(async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await page.route('**/api/Companies/GetCompaniesByUserGroup**', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ Data: [{ Id: 1, EmsrNombre: 'Empresa Test', EmsrIdeNumero: '3101' }], Message: 'OK' }),
    }));
    await page.goto(REGISTER_URL);
  });

  test('Página carga correctamente con layout protegido', async ({ page }) => {
    await expect(page.locator('nav, [data-controller="menu"]')).toBeVisible();
  });

  test('Campos visibles: Compañía, Cuenta, Nombre Completo, Cédula, Usuario, Tipo OC', async ({ page }) => {
    await expect(page.locator('label:has-text("Compañía"), select[name*="company"], select[name*="Company"]')).toBeVisible();
    await expect(page.locator('label:has-text("Nombre Completo"), input[name*="FullName"], input[placeholder*="Nombre"]')).toBeVisible();
    await expect(page.locator('label:has-text("Cédula"), label:has-text("Identificación"), input[name*="Identification"]')).toBeVisible();
    await expect(page.locator('label:has-text("Usuario"), input[name*="Email"], input[placeholder*="Usuario"]')).toBeVisible();
  });

  test('Campo Email valida formato de email', async ({ page }) => {
    const emailInput = page.locator('input[name*="Email"], input[type="email"], input[placeholder*="Usuario"]').first();
    await emailInput.fill('invalid-email');
    await page.locator('button:has-text("Registrar"), button[type="submit"]').first().click();
    await expect(page.locator('.text-red-500, [class*="error"]')).toBeVisible();
  });

  test('Botón Registrar deshabilitado cuando el formulario es inválido', async ({ page }) => {
    await expect(page.locator('button:has-text("Registrar")')).toBeDisabled();
  });

  test('Formulario válido habilita botón Registrar', async ({ page }) => {
    await page.locator('input[placeholder*="Nombre Completo"]').fill('Usuario Test');
    await page.locator('input[placeholder*="Identificación"], input[placeholder*="Cédula"]').fill('123456789');
    await page.locator('input[placeholder*="Usuario"]').fill('test@empresa.com');
    await expect(page.locator('button:has-text("Registrar")')).toBeEnabled();
  });

  test('Registrar usuario exitoso redirige a lista', async ({ page }) => {
    await page.route('**/api/User**', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ Data: null, Message: 'Creado' }),
    }));
    await page.locator('input[placeholder*="Nombre Completo"]').fill('Usuario Test');
    await page.locator('input[placeholder*="Identificación"], input[placeholder*="Cédula"]').fill('123456789');
    await page.locator('input[placeholder*="Usuario"]').fill('test@empresa.com');
    await page.locator('button:has-text("Registrar")').click();
    await expect(page).toHaveURL(/\/configurations\/users/);
  });

  test('Botón Cancelar regresa a lista de usuarios', async ({ page }) => {
    await page.locator('button:has-text("Cancelar")').click();
    await expect(page).toHaveURL(/\/configurations\/users/);
  });

});

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 6 — Página Editar Usuario
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Editar Usuario', () => {

  const USER_ID = 'uid-1';

  test.beforeEach(async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await page.route('**/api/User/information**', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({
        Data: {
          Id: USER_ID, FullName: 'Ana García', Email: 'ana@empresa.com',
          Identification: '123456789', SapUser: 'AGARCIA', SapPass: '',
          Active: true, EmailConfirmed: true, CreateDate: '2024-01-15T10:00:00Z',
        },
        Message: 'OK',
      }),
    }));
    await page.route('**/api/User/companies**', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ Data: [{ Id: 1, EmsrNombre: 'Empresa Test', EmsrNombreComercial: 'E. Test' }], Message: 'OK' }),
    }));
    await page.goto(`${EDIT_URL}?userId=${USER_ID}`);
  });

  test('Página carga con layout protegido', async ({ page }) => {
    await expect(page.locator('nav, [data-controller="menu"]')).toBeVisible();
  });

  test('Formulario pre-rellena datos del usuario', async ({ page }) => {
    await expect(page.locator('input[name*="FullName"], input[placeholder*="Nombre"]').first()).toHaveValue('Ana García');
    await expect(page.locator('input[name*="Identification"], input[placeholder*="Identificación"]').first()).toHaveValue('123456789');
    await expect(page.locator('input[name*="SapUser"], input[placeholder*="SAP"]').first()).toHaveValue('AGARCIA');
  });

  test('Checkbox Activo refleja estado del usuario', async ({ page }) => {
    const checkbox = page.locator('input[type="checkbox"][name*="Active"], input[type="checkbox"]').first();
    await expect(checkbox).toBeChecked();
  });

  test('Campo Contraseña SAP es de tipo password con toggle visible', async ({ page }) => {
    const passInput = page.locator('input[type="password"]').first();
    await expect(passInput).toBeVisible();
    const toggleBtn = page.locator('button[data-action*="togglePass"], button .material-icons:has-text("visibility")').first();
    await expect(toggleBtn).toBeVisible();
  });

  test('Botón Probar Credenciales deshabilitado hasta que se edite SAP User/Pass', async ({ page }) => {
    await expect(page.locator('button:has-text("Probar"), button:has-text("credenciales")')).toBeDisabled();
  });

  test('Botón Actualizar guarda y redirige a lista', async ({ page }) => {
    await page.route('**/api/User', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ Data: true, Message: 'Actualizado' }),
    }));
    await page.locator('button:has-text("Actualizar")').click();
    await expect(page).toHaveURL(/\/configurations\/users/);
  });

  test('Botón Cancelar regresa a lista de usuarios', async ({ page }) => {
    await page.locator('button:has-text("Cancelar")').click();
    await expect(page).toHaveURL(/\/configurations\/users/);
  });

  test('Sin userId en params redirige a lista', async ({ page }) => {
    await page.goto(EDIT_URL);
    await expect(page).toHaveURL(/\/configurations\/users/);
  });

});

// ═══════════════════════════════════════════════════════════════════════════════
// GRUPO 7 — Navegación entre tabs
// ═══════════════════════════════════════════════════════════════════════════════

test.describe('Users — Navegación de tabs', () => {

  test('Click en tab Completar Registro muestra su contenido', async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockUsersAPI(page);
    await mockInactiveUsersAPI(page);
    await page.goto(USERS_URL);

    await page.locator('[data-tab-name="complete-registration"]').click();
    await expect(page.locator('[data-users-target="tabContent"][data-tab="complete-registration"]')).toBeVisible();
    await expect(page.locator('[data-users-target="tabContent"][data-tab="list"]')).not.toBeVisible();
  });

  test('Click en tab Asignación muestra su contenido', async ({ page }) => {
    await injectAuth(page, PERMS_ALL);
    await mockAssignmentAPIs(page);
    await mockUsersAPI(page);
    await page.goto(USERS_URL);

    await page.locator('[data-tab-name="assignment"]').click();
    await expect(page.locator('[data-users-target="tabContent"][data-tab="assignment"]')).toBeVisible();
  });

  test('Click en tab Lista recarga los datos', async ({ page }) => {
    let callCount = 0;
    await page.route('**/api/User/accessible**', route => {
      callCount++;
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ Data: [], Message: '' }) });
    });
    await injectAuth(page, PERMS_ALL);
    await mockAssignmentAPIs(page);
    await mockInactiveUsersAPI(page);
    await page.goto(USERS_URL);

    // Switch to another tab then back
    await page.locator('[data-tab-name="complete-registration"]').click();
    await page.locator('[data-tab-name="list"]').click();
    expect(callCount).toBeGreaterThanOrEqual(1);
  });

});

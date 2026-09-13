// @ts-check
const { test, expect } = require('@playwright/test');

const BASE_URL = 'http://localhost:3000';
const PAGE_URL = `${BASE_URL}/configurations/user-profile`;

// ─── Datos de fixture ─────────────────────────────────────────────────────────
const USER_INFO = {
  Id: 'user-uuid-123',
  Identification: '123456789',
  FullName: 'Test User',
  Email: 'test@example.com',
  EmailConfirmed: true,
  UserName: 'testuser',
  PasswordHash: 'hashed',
  Active: true,
  CreateDate: '2024-01-01T00:00:00Z',
  Owner: false,
  SapUser: 'SAPUser01',
  SapPass: '',
  DocNumberPreference: '1',
};


const COMPANIES_DATA = [
  { Id: 10, EmsrNombreComercial: 'Empresa ABC', EmsrNombre: 'Empresa ABC S.A.' },
  { Id: 20, EmsrNombreComercial: '', EmsrNombre: 'Solo Nombre Legal S.A.' },
  { Id: 186, EmsrNombreComercial: 'Centro Comunidad Prod', EmsrNombre: 'Centro Comunidad Prod S.A.' },
];

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Mockea todas las APIs necesarias para la carga inicial de la página.
 * @param {import('@playwright/test').Page} page
 * @param {object} [overrides]
 */
async function mockInitialApis(page, overrides = {}) {
  const userInfo = overrides.userInfo ?? USER_INFO;
  const companies = overrides.companies ?? COMPANIES_DATA;
  const selectedCompanyId = overrides.selectedCompanyId ?? 10;

  await page.route('**/api/User/GetUserInfo', route =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ Data: [userInfo], Message: null }),
    })
  );

  await page.route('**/api/Companies/GetCompanies**', route =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ Data: companies, Message: null }),
    })
  );

  // Inyectar compañía seleccionada en sessionStorage antes de navegar
  await page.addInitScript((companyId) => {
    const data = JSON.stringify({ companyId, companyName: 'Empresa ABC' });
    sessionStorage.setItem('selectedCompany', data);
  }, selectedCompanyId);
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 1: Carga inicial
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — Carga inicial', () => {
  test('La página carga correctamente con título visible', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('user-profile-page')).toBeVisible();
    await expect(page.getByTestId('page-title')).toContainText('Actualización de la Información del Usuario');
  });

  test('El campo SapUser se pre-llena con el valor del usuario', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    const sapUserInput = page.getByTestId('sap-user-input');
    await expect(sapUserInput).toBeVisible();
    await expect(sapUserInput).toHaveValue('SAPUser01');
  });

  test('El campo SapPass empieza vacío', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('sap-pass-input')).toHaveValue('');
  });

  test('El campo SapPass es de tipo password por defecto', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('sap-pass-input')).toHaveAttribute('type', 'password');
  });

  test('El select de compañías se carga con opciones', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    const companySelect = page.getByTestId('company-select');
    await expect(companySelect).toBeVisible();
    const options = companySelect.locator('option');
    await expect(options).toHaveCount(4); // 1 placeholder + 3 compañías
  });

  test('El select de compañías pre-selecciona la compañía actual del storage', async ({ page }) => {
    await mockInitialApis(page, { selectedCompanyId: 10 });
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('company-select')).toHaveValue('10');
  });

  test('El select de compañías está deshabilitado inicialmente', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('company-select')).toBeDisabled();
  });

  test('El campo OCTypeControl NO es visible para compañías fuera del enum', async ({ page }) => {
    await mockInitialApis(page, { selectedCompanyId: 10 });
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('oc-type-section')).not.toBeVisible();
  });

  test('El campo OCTypeControl ES visible para compañía 186 (CentroComunidadProd)', async ({ page }) => {
    await mockInitialApis(page, { selectedCompanyId: 186 });
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('oc-type-section')).toBeVisible();
  });

  test('El campo OCTypeControl ES visible para compañía 1206 (CentroComunidadTest)', async ({ page }) => {
    await mockInitialApis(page, { selectedCompanyId: 1206 });
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('oc-type-section')).toBeVisible();
  });

  test('OCTypeControl se pre-selecciona con DocNumberPreference del usuario', async ({ page }) => {
    await mockInitialApis(page, {
      selectedCompanyId: 186,
      userInfo: { ...USER_INFO, DocNumberPreference: '2' },
    });
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('oc-type-select')).toHaveValue('2');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 2: Toggle visibilidad contraseña
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — Toggle visibilidad contraseña', () => {
  test('Click en toggle cambia el tipo de password a text', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('toggle-password-btn').click();
    await expect(page.getByTestId('sap-pass-input')).toHaveAttribute('type', 'text');
  });

  test('Click doble en toggle vuelve a password', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('toggle-password-btn').click();
    await page.getByTestId('toggle-password-btn').click();
    await expect(page.getByTestId('sap-pass-input')).toHaveAttribute('type', 'password');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 3: credentialsDirty — activación del select y reseteo
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — credentialsDirty tracking', () => {
  test('Modificar SapUser habilita el select de compañías', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-user-input').fill('NuevoUser');
    await expect(page.getByTestId('company-select')).not.toBeDisabled();
  });

  test('Modificar SapPass habilita el select de compañías', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-pass-input').fill('NuevoPass');
    await expect(page.getByTestId('company-select')).not.toBeDisabled();
  });

  test('El botón "Probar credenciales" permanece deshabilitado sin cambios', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('btn-test-credentials')).toBeDisabled();
  });

  test('Botón "Probar credenciales" se habilita cuando dirty + compañía seleccionada', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-user-input').fill('NuevoUser');
    await page.getByTestId('sap-pass-input').fill('NuevoPass');
    // El select ya tiene valor pre-seleccionado (companyId=10)
    await expect(page.getByTestId('btn-test-credentials')).not.toBeDisabled();
  });

  test('Cambiar la compañía seleccionada resetea credentialsValidated', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    // Simular que ya está validado
    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('Pass');

    await page.route('**/api/Connections/validate-user-credentials', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: true, Message: null }),
      })
    );

    await page.getByTestId('btn-test-credentials').click();
    await expect(page.getByTestId('btn-test-credentials')).toHaveClass(/btn-verified/);

    // Cambiar compañía
    await page.getByTestId('company-select').selectOption('20');
    await expect(page.getByTestId('btn-test-credentials')).not.toHaveClass(/btn-verified/);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 4: Probar credenciales
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — Probar credenciales', () => {
  test('Validación: toast warning si SapUser vacío', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    // Limpiar SapUser y llenar SapPass para activar dirty
    await page.getByTestId('sap-user-input').fill('');
    await page.getByTestId('sap-pass-input').fill('pass123');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('toast-message')).toContainText('Complete el Usuario y Contraseña');
  });

  test('Validación: toast warning si SapPass vacío', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-user-input').fill('User');
    // SapPass queda vacío
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('toast-message')).toContainText('Complete el Usuario y Contraseña');
  });

  test('Validación: toast warning si no hay compañía seleccionada', async ({ page }) => {
    await mockInitialApis(page, { selectedCompanyId: null });
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('Pass');
    // Deseleccionar compañía
    await page.getByTestId('company-select').selectOption('');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('toast-message')).toContainText('Seleccione una compañía');
  });

  test('Botón muestra "Probando..." durante la validación', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/Connections/validate-user-credentials', async route => {
      await new Promise(r => setTimeout(r, 500));
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: true, Message: null }),
      });
    });

    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('Pass');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('btn-test-credentials')).toContainText('Probando...');
  });

  test('Credenciales válidas → botón verde con "Credenciales verificadas"', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/Connections/validate-user-credentials', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: true, Message: null }),
      })
    );

    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('Pass');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('btn-test-credentials')).toHaveClass(/btn-verified/);
    await expect(page.getByTestId('btn-test-credentials')).toContainText('Credenciales verificadas');
  });

  test('Credenciales inválidas (Data: false) → modal de error', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/Connections/validate-user-credentials', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: false, Message: 'Usuario o contraseña incorrectos' }),
      })
    );

    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('WrongPass');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('modal-title')).toContainText('Credenciales inválidas');
  });

  test('Error de red al validar → modal de error', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/Connections/validate-user-credentials', route =>
      route.fulfill({ status: 500, body: 'Internal Server Error' })
    );

    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('Pass');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('modal-error')).toBeVisible();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 5: Botón Actualizar — habilitación
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — Botón Actualizar: lógica de habilitación', () => {
  test('Botón habilitado en carga inicial (form válido, no dirty)', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await expect(page.getByTestId('btn-update')).not.toBeDisabled();
  });

  test('Botón deshabilitado si SapUser está vacío (form inválido)', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-user-input').fill('');
    await expect(page.getByTestId('btn-update')).toBeDisabled();
  });

  test('Botón deshabilitado si credentialsDirty y no validado', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.getByTestId('sap-user-input').fill('NuevoUser');
    // No se han probado las credenciales → deshabilitado
    await expect(page.getByTestId('btn-update')).toBeDisabled();
  });

  test('Botón habilitado después de credenciales validadas', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/Connections/validate-user-credentials', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: true, Message: null }),
      })
    );

    await page.getByTestId('sap-user-input').fill('User');
    await page.getByTestId('sap-pass-input').fill('Pass');
    await page.getByTestId('btn-test-credentials').click();

    await expect(page.getByTestId('btn-update')).not.toBeDisabled();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 6: Flujo completo de actualización
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — Flujo de actualización', () => {
  test('Actualizar sin tocar credenciales: PATCH se llama con payload correcto', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    let patchBody = null;
    await page.route('**/api/User/profile-info', async route => {
      if (route.request().method() === 'PATCH') {
        patchBody = JSON.parse(route.request().postData() || '{}');
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ Data: { Success: true }, Message: null }),
        });
      }
    });

    await page.getByTestId('btn-update').click();

    expect(patchBody).not.toBeNull();
    expect(patchBody.SapUser).toBe('SAPUser01');
    expect(patchBody.SapPass).toBe('');
  });

  test('Actualización exitosa muestra toast de éxito', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/User/profile-info', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: { Success: true }, Message: null }),
      })
    );

    await page.getByTestId('btn-update').click();
    await expect(page.getByTestId('toast-message')).toContainText('actualizada con éxito');
  });

  test('Actualización exitosa recarga los datos del usuario', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    let getCallCount = 0;
    await page.route('**/api/User/GetUserInfo', route => {
      getCallCount++;
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: [USER_INFO], Message: null }),
      });
    });

    await page.route('**/api/User/profile-info', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: { Success: true }, Message: null }),
      })
    );

    await page.getByTestId('btn-update').click();
    await page.waitForTimeout(300);

    // Debe haberse llamado al menos 2 veces: carga inicial + recarga post-actualización
    expect(getCallCount).toBeGreaterThanOrEqual(2);
  });

  test('Error en PATCH muestra toast de error', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/User/profile-info', route =>
      route.fulfill({
        status: 500,
        contentType: 'application/json',
        body: JSON.stringify({ Message: 'Error interno del servidor' }),
      })
    );

    await page.getByTestId('btn-update').click();
    await expect(page.getByTestId('toast-error')).toBeVisible();
  });

  test('Flujo completo: editar credenciales → validar → actualizar', async ({ page }) => {
    await mockInitialApis(page);
    await page.goto(PAGE_URL);

    await page.route('**/api/Connections/validate-user-credentials', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: true, Message: null }),
      })
    );

    let patchBody = null;
    await page.route('**/api/User/profile-info', async route => {
      patchBody = JSON.parse(route.request().postData() || '{}');
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: { Success: true }, Message: null }),
      });
    });

    // 1. Editar credenciales
    await page.getByTestId('sap-user-input').fill('NuevoSapUser');
    await page.getByTestId('sap-pass-input').fill('NuevoPass123');

    // 2. Verificar que Actualizar está bloqueado
    await expect(page.getByTestId('btn-update')).toBeDisabled();

    // 3. Probar credenciales
    await page.getByTestId('btn-test-credentials').click();
    await expect(page.getByTestId('btn-test-credentials')).toHaveClass(/btn-verified/);

    // 4. Actualizar habilitado
    await expect(page.getByTestId('btn-update')).not.toBeDisabled();

    // 5. Actualizar
    await page.getByTestId('btn-update').click();

    expect(patchBody.SapUser).toBe('NuevoSapUser');
    expect(patchBody.SapPass).toBe('NuevoPass123');
    await expect(page.getByTestId('toast-message')).toContainText('actualizada con éxito');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 7: OCTypeControl
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — OCTypeControl', () => {
  test('OCType select tiene opciones "Con numero de OC" y "Sin numero de OC"', async ({ page }) => {
    await mockInitialApis(page, { selectedCompanyId: 186 });
    await page.goto(PAGE_URL);

    const options = page.getByTestId('oc-type-select').locator('option');
    await expect(options).toHaveCount(3); // placeholder + 2 opciones
  });

  test('OCTypeControl se incluye en el PATCH si está visible', async ({ page }) => {
    await mockInitialApis(page, {
      selectedCompanyId: 186,
      userInfo: { ...USER_INFO, DocNumberPreference: '1' },
    });
    await page.goto(PAGE_URL);

    let patchBody = null;
    await page.route('**/api/User/profile-info', async route => {
      patchBody = JSON.parse(route.request().postData() || '{}');
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: { Success: true }, Message: null }),
      });
    });

    await page.getByTestId('oc-type-select').selectOption('2');
    await page.getByTestId('btn-update').click();

    expect(patchBody.DocNumberPreference).toBe('2');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 8: Error en carga inicial
// ─────────────────────────────────────────────────────────────────────────────
test.describe('User Profile — Error en carga inicial', () => {
  test('Error en GetUserInfo muestra modal de error', async ({ page }) => {
    await page.route('**/api/User/GetUserInfo', route =>
      route.fulfill({ status: 500, body: 'Internal Server Error' })
    );
    await page.route('**/api/Companies/GetCompanies**', route =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ Data: [], Message: null }),
      })
    );

    await page.goto(PAGE_URL);
    await expect(page.getByTestId('modal-error')).toBeVisible();
  });
});

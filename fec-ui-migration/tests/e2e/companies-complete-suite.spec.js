// @ts-check
/**
 * Suite E2E: Companies — migración Angular → Rails
 * Ruta: /configurations/companies
 *
 * Cubre:
 *   - Auth guard
 *   - Index: búsqueda paginada, tabla, badges de estado, estrella favorita
 *   - Favorita: modal confirmación → POST api/companies/{id}/favorite
 *   - Editar: navega a /:id/edit (con permiso F_ModifyCompany)
 *   - Crear: navega a /new (con permiso F_CreateCompany)
 *   - Paginación: cambio de tamaño, prev/next
 *   - Create/Edit: todos los campos del formulario por sección
 *   - Validaciones identificación por tipo
 *   - Toggle de contraseña (CertPin, TokenPass)
 *   - EmailCC dinámico (add/remove)
 *   - Códigos de actividad dinámico (solo edición)
 *   - UseFactProv habilita/deshabilita sapForm
 *   - Tolerancias XML y mapeo de monedas
 *   - Estados vacíos y error de API
 */

const { test, expect } = require('@playwright/test')

const BASE_URL   = 'http://localhost:3000'
const INDEX_URL  = `${BASE_URL}/configurations/companies`
const CREATE_URL = `${BASE_URL}/configurations/companies/new`
const EDIT_URL   = `${BASE_URL}/configurations/companies/1/edit`
const LOGIN_URL  = `${BASE_URL}/login`

// ─── Mock data ────────────────────────────────────────────────────────────────

const MOCK_SESSION = {
  access_token: 'mock-token-companies',
  token_type:   'Bearer',
  expires_at:   Date.now() + 3_600_000,
  UserEmail:    'testuser@clavisco.com',
  UserId:       'user-001',
}

const MOCK_COMPANY = {
  companyId:   '42',
  companyName: 'Empresa Test SA',
  groupId:     '1',
}

const MOCK_PERMISSIONS_CREATE = ['F_CreateCompany', 'F_ModifyCompany']

const MOCK_PERMISSIONS_NONE = []

const MOCK_COMPANIES = [
  {
    Id: 1, EmsrNombre: 'Empresa Legal SA', EmsrNombreComercial: 'Empresa Comercial',
    EmsrIdeNumero: '123456789', Favorite: true, Active: true, QtyRolAssign: 2,
    MaxQtyRowsFetch: 12,
  },
  {
    Id: 2, EmsrNombre: 'Beta Legal SRL', EmsrNombreComercial: 'Beta Comercial',
    EmsrIdeNumero: '987654321', Favorite: false, Active: false, QtyRolAssign: 0,
    MaxQtyRowsFetch: 12,
  },
]

const MOCK_COMPANIES_RESPONSE = { Data: MOCK_COMPANIES, Error: false, Message: null }
const MOCK_EMPTY_RESPONSE     = { Data: [],             Error: false, Message: null }

const MOCK_SAP_CONNECTIONS = {
  Data: [{ Id: 10, Server: 'SAP-Server-01' }],
  Error: false, Message: null,
}

const MOCK_COMPANY_DETAIL = {
  Data: {
    Id: 1,
    EmsrNombre:           'Empresa Legal SA',
    EmsrNombreComercial:  'Empresa Comercial',
    EmsrIdeTipo:          '01',
    EmsrIdeNumero:        '123456789',
    CodigoActividad:      '123456',
    NameToEmail:          1,
    GroupId:              1,
    ShortName:            'ELS',
    FreightCharges:       1,
    Registrofiscal8707:   '',
    SAPConnectionId:      10,
    DBSap:                'DBSAP_TEST',
    IsExternal:           false,
    Active:               true,
    AdditionalInformation: 'Info adicional',
    EmailCC:              'test@test.com;cc@test.com',
    CertPin:              '1234',
    CertPath:             'C:\\certs\\123456789.p12',
    CertExpireDate:       '2025-12-31T00:00:00',
    TokenUsr:             '123456789',
    Logo:                 'C:\\logos\\logo.png',
    FEPrintFormat:        'C:\\formats\\format.rpt',
    UseFactProv:          false,
    SendReceptAndApInv:   false,
    NumSerieProv:         null,
    NumSerieFactProv:     null,
    DefaultTaxForXML:     '',
    DefaultWareHouse:     '',
    XmlToleranceAmounts:  [],
  },
  Error: false, Message: null,
}

const MOCK_ACTIVITY_CODES = {
  Data: [{ Code: '123456', Name: 'Actividad principal' }],
  Error: false, Message: null,
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

async function injectAuth(page, perms = MOCK_PERMISSIONS_CREATE) {
  await page.goto(LOGIN_URL)
  await page.evaluate(({ session, company, permissions }) => {
    localStorage.setItem('Session',          JSON.stringify(session))
    sessionStorage.setItem('CurrentCompany', JSON.stringify(company))
    sessionStorage.setItem('Permissions',    JSON.stringify(permissions))
  }, { session: MOCK_SESSION, company: MOCK_COMPANY, permissions: perms })
}

async function mockCompaniesApi(page, response = MOCK_COMPANIES_RESPONSE) {
  await page.route('**/api/Companies/GetCompanies**', route =>
    route.fulfill({ json: response })
  )
}

async function mockInitialData(page) {
  await page.route('**/api/Connections/for-assignment**', route =>
    route.fulfill({ json: MOCK_SAP_CONNECTIONS })
  )
}

async function mockCompanyDetail(page) {
  await page.route('**/api/companies/1**', route =>
    route.fulfill({ json: MOCK_COMPANY_DETAIL })
  )
  await page.route('**/api/warehouse**', route =>
    route.fulfill({ json: { Data: [], Error: false } })
  )
  await page.route('**/api/Tax**', route =>
    route.fulfill({ json: { Data: [], Error: false } })
  )
  await page.route('**/api/Companies/1/currencies**', route =>
    route.fulfill({ json: { Data: [], Error: false } })
  )
  await page.route('**/api/Companies/1/currency-map**', route =>
    route.fulfill({ json: { Data: [], Error: false } })
  )
  await page.route('**/api/Companies/1/activity-codes**', route =>
    route.fulfill({ json: MOCK_ACTIVITY_CODES })
  )
}

// ─── Suite: Index — Carga inicial ─────────────────────────────────────────────

test.describe('Companies Index — Carga inicial', () => {
  test('Página carga con formulario de búsqueda', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="companies-page"]')).toBeVisible()
    await expect(page.locator('[data-testid="search-legal-name"]')).toBeVisible()
    await expect(page.locator('[data-testid="search-comercial-name"]')).toBeVisible()
    await expect(page.locator('[data-testid="search-identification"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-search"]')).toBeVisible()
  })

  test('Tabla se renderiza con columnas correctas', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const headers = page.locator('[data-testid="companies-table"] thead th')
    await expect(headers.nth(0)).toContainText('Nombre Legal')
    await expect(headers.nth(1)).toContainText('Nombre Comercial')
    await expect(headers.nth(2)).toContainText('Identificación')
    await expect(headers.nth(3)).toContainText('Compañía Favorita')
    await expect(headers.nth(4)).toContainText('Activa')
    await expect(headers.nth(5)).toContainText('Acciones')
  })

  test('Tabla muestra datos de las compañías', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const rows = page.locator('[data-testid="companies-tbody"] tr')
    await expect(rows).toHaveCount(2)
    await expect(rows.first()).toContainText('Empresa Legal SA')
    await expect(rows.nth(1)).toContainText('Beta Legal SRL')
  })

  test('Paginación visible con opciones 5, 10, 15', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="pagination"]')).toBeVisible()
    const opts = page.locator('[data-testid="page-size-select"] option')
    await expect(opts).toHaveCount(3)
    await expect(opts.nth(0)).toHaveValue('5')
    await expect(opts.nth(1)).toHaveValue('10')
    await expect(opts.nth(2)).toHaveValue('15')
  })

  test('Estado vacío cuando API devuelve lista vacía', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page, MOCK_EMPTY_RESPONSE)
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="empty-state"]')).toBeVisible()
  })
})

// ─── Suite: Index — Permisos ──────────────────────────────────────────────────

test.describe('Companies Index — Permisos', () => {
  test('Botón Crear visible con permiso F_CreateCompany', async ({ page }) => {
    await injectAuth(page, MOCK_PERMISSIONS_CREATE)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="btn-create-company"]')).toBeVisible()
  })

  test('Botón Crear oculto sin permiso F_CreateCompany', async ({ page }) => {
    await injectAuth(page, MOCK_PERMISSIONS_NONE)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="btn-create-company"]')).toBeHidden()
  })

  test('Botón Crear navega a /new', async ({ page }) => {
    await injectAuth(page, MOCK_PERMISSIONS_CREATE)
    await mockCompaniesApi(page)
    await mockInitialData(page)
    await page.goto(INDEX_URL)

    await page.click('[data-testid="btn-create-company"]')
    await expect(page).toHaveURL(CREATE_URL)
  })
})

// ─── Suite: Index — Tabla y badges ────────────────────────────────────────────

test.describe('Companies Index — Tabla y badges', () => {
  test('Badge Activo para empresa activa', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const firstRow = page.locator('[data-testid="companies-tbody"] tr').first()
    const badge    = firstRow.locator('[data-testid="status-badge"]')
    await expect(badge).toContainText('Activo')
  })

  test('Badge Inactivo para empresa inactiva', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const secondRow = page.locator('[data-testid="companies-tbody"] tr').nth(1)
    const badge     = secondRow.locator('[data-testid="status-badge"]')
    await expect(badge).toContainText('Inactivo')
  })

  test('Estrella favorita visible en empresa favorita', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const firstRow     = page.locator('[data-testid="companies-tbody"] tr').first()
    const favoriteCell = firstRow.locator('[data-testid="favorite-cell"]')
    await expect(favoriteCell.locator('.material-icons')).toBeVisible()
    await expect(favoriteCell.locator('.material-icons')).toContainText('star')
  })

  test('Estrella NO visible en empresa no favorita', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const secondRow    = page.locator('[data-testid="companies-tbody"] tr').nth(1)
    const favoriteCell = secondRow.locator('[data-testid="favorite-cell"]')
    await expect(favoriteCell.locator('.material-icons')).toHaveCount(0)
  })

  test('Botón favorita visible en cada fila', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const rows = page.locator('[data-testid="companies-tbody"] tr')
    for (let i = 0; i < 2; i++) {
      await expect(rows.nth(i).locator('[data-testid="btn-favorite"]')).toBeVisible()
    }
  })

  test('Botón editar visible en cada fila', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const rows = page.locator('[data-testid="companies-tbody"] tr')
    for (let i = 0; i < 2; i++) {
      await expect(rows.nth(i).locator('[data-testid="btn-edit"]')).toBeVisible()
    }
  })
})

// ─── Suite: Index — Favorita ──────────────────────────────────────────────────

test.describe('Companies Index — Favorita', () => {
  test('Clic en favorita (con asignaciones) abre modal de confirmación', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const firstRow = page.locator('[data-testid="companies-tbody"] tr').first()
    await firstRow.locator('[data-testid="btn-favorite"]').click()

    // Modal de confirmación
    await expect(page.locator('text=¿Desea establecer esta compañía como favorita?')).toBeVisible()
  })

  test('Cancelar favorita cierra modal', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const firstRow = page.locator('[data-testid="companies-tbody"] tr').first()
    await firstRow.locator('[data-testid="btn-favorite"]').click()
    await page.locator('text=Cancelar').click()

    await expect(page.locator('text=¿Desea establecer esta compañía como favorita?')).toBeHidden()
  })

  test('Confirmar favorita hace POST y recarga', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)

    let favoriteCallCount = 0
    await page.route('**/api/companies/1/favorite', route => {
      favoriteCallCount++
      route.fulfill({ json: { Data: true, Error: false, Message: null } })
    })

    await page.goto(INDEX_URL)

    const firstRow = page.locator('[data-testid="companies-tbody"] tr').first()
    await firstRow.locator('[data-testid="btn-favorite"]').click()
    await page.locator('button:text("Confirmar")').click()
    await page.waitForTimeout(500)

    expect(favoriteCallCount).toBe(1)
  })

  test('Empresa sin asignaciones muestra toast de info al clic favorita', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    // Segunda fila: QtyRolAssign = 0
    const secondRow = page.locator('[data-testid="companies-tbody"] tr').nth(1)
    await secondRow.locator('[data-testid="btn-favorite"]').click()

    await expect(page.locator('[data-testid="toast"]')).toBeVisible()
    await expect(page.locator('[data-testid="toast"]')).toContainText('no posee asignaciones')
  })
})

// ─── Suite: Index — Editar ────────────────────────────────────────────────────

test.describe('Companies Index — Editar', () => {
  test('Botón editar con permiso navega a /:id/edit', async ({ page }) => {
    await injectAuth(page, MOCK_PERMISSIONS_CREATE)
    await mockCompaniesApi(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(INDEX_URL)

    const firstRow = page.locator('[data-testid="companies-tbody"] tr').first()
    await firstRow.locator('[data-testid="btn-edit"]').click()
    await expect(page).toHaveURL(`${BASE_URL}/configurations/companies/1/edit`)
  })

  test('Botón editar sin permiso muestra toast info', async ({ page }) => {
    await injectAuth(page, MOCK_PERMISSIONS_NONE)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    const firstRow = page.locator('[data-testid="companies-tbody"] tr').first()
    await firstRow.locator('[data-testid="btn-edit"]').click()

    await expect(page.locator('[data-testid="toast"]')).toBeVisible()
    await expect(page.locator('[data-testid="toast"]')).toContainText('no posee los permisos')
  })
})

// ─── Suite: Index — Paginación ────────────────────────────────────────────────

test.describe('Companies Index — Paginación', () => {
  test('Botón anterior deshabilitado en página 1', async ({ page }) => {
    await injectAuth(page)
    await mockCompaniesApi(page)
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="btn-prev-page"]')).toBeDisabled()
  })

  test('Cambiar tamaño de página hace nueva llamada API', async ({ page }) => {
    await injectAuth(page)
    let callCount = 0
    await page.route('**/api/Companies/GetCompanies**', route => {
      callCount++
      route.fulfill({ json: MOCK_COMPANIES_RESPONSE })
    })
    await page.goto(INDEX_URL)

    const initialCount = callCount
    await page.selectOption('[data-testid="page-size-select"]', '10')
    await page.waitForTimeout(300)
    expect(callCount).toBeGreaterThan(initialCount)
  })

  test('Búsqueda hace nueva llamada y resetea a página 1', async ({ page }) => {
    await injectAuth(page)
    let lastParams = ''
    await page.route('**/api/Companies/GetCompanies**', route => {
      lastParams = route.request().url()
      route.fulfill({ json: MOCK_COMPANIES_RESPONSE })
    })
    await page.goto(INDEX_URL)

    await page.fill('[data-testid="search-legal-name"]', 'TestBusqueda')
    await page.click('[data-testid="btn-search"]')
    await page.waitForTimeout(300)

    expect(lastParams).toContain('LegalName=TestBusqueda')
    expect(lastParams).toContain('StartPos=1')
  })
})

// ─── Suite: Index — Error API ──────────────────────────────────────────────────

test.describe('Companies Index — Manejo de errores', () => {
  test('Error de API muestra modal de error', async ({ page }) => {
    await injectAuth(page)
    await page.route('**/api/Companies/GetCompanies**', route =>
      route.fulfill({ json: { Data: null, Error: true, Message: 'Error de servidor' } })
    )
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="error-modal"]')).toBeVisible()
  })

  test('Error de red muestra modal de error', async ({ page }) => {
    await injectAuth(page)
    await page.route('**/api/Companies/GetCompanies**', route => route.abort())
    await page.goto(INDEX_URL)

    await expect(page.locator('[data-testid="error-modal"]')).toBeVisible()
  })
})

// ─── Suite: Create — Navegación y estructura ──────────────────────────────────

test.describe('Companies Create — Estructura', () => {
  test('Página /new carga correctamente', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="company-form-page"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-register"]')).toBeVisible()
  })

  test('Botón Registrar visible en modo crear', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="btn-register"]')).toBeVisible()
  })

  test('Sección Datos Generales visible con todos los campos', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="section-general"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-comercial-name"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-legal-name"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-type"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-identification"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-codigo-actividad"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-name-to-email"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-group-id"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-short-name"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-freight-charges"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-sap-connection"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-db-sap"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-is-external"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-active"]')).toBeVisible()
  })

  test('Sección ATV visible', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="section-atv"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-cert-pin"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-toggle-cert-pin"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-cert-path"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-cert-expire-date"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-token-usr"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-token-pass"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-toggle-token-pass"]')).toBeVisible()
  })

  test('Sección Adicional visible con EmailCC dinámico', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="section-additional"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-additional-info"]')).toBeVisible()
    await expect(page.locator('[data-testid="email-cc-list"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-add-email"]')).toBeVisible()
  })

  test('Sección Adjuntos visible', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="section-attachments"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-logo"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-print-format"]')).toBeVisible()
  })

  test('Sección Factura Proveedor visible', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="section-sap"]')).toBeVisible()
    await expect(page.locator('[data-testid="field-use-fact-prov"]')).toBeVisible()
  })

  test('Sección Códigos de actividad OCULTA en modo crear', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="section-activity-codes"]')).toBeHidden()
  })
})

// ─── Suite: Create — Validaciones identificación ──────────────────────────────

test.describe('Companies Create — Validaciones tipo identificación', () => {
  test('Tipo 01 (Cédula Física): min=9 max=9', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.selectOption('[data-testid="field-type"]', '01')
    const id = page.locator('[data-testid="field-identification"]')
    await expect(id).toHaveAttribute('minlength', '9')
    await expect(id).toHaveAttribute('maxlength', '9')
  })

  test('Tipo 02 (Cédula Jurídica): min=10 max=10', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.selectOption('[data-testid="field-type"]', '02')
    const id = page.locator('[data-testid="field-identification"]')
    await expect(id).toHaveAttribute('minlength', '10')
    await expect(id).toHaveAttribute('maxlength', '10')
  })

  test('Tipo 03 (DIMEX): min=11 max=12', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.selectOption('[data-testid="field-type"]', '03')
    const id = page.locator('[data-testid="field-identification"]')
    await expect(id).toHaveAttribute('minlength', '11')
    await expect(id).toHaveAttribute('maxlength', '12')
  })

  test('Tipo 04 (NITE): min=10 max=10', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.selectOption('[data-testid="field-type"]', '04')
    const id = page.locator('[data-testid="field-identification"]')
    await expect(id).toHaveAttribute('minlength', '10')
    await expect(id).toHaveAttribute('maxlength', '10')
  })
})

// ─── Suite: Create — Toggle de contraseña ─────────────────────────────────────

test.describe('Companies Create — Toggle contraseña', () => {
  test('CertPin inicia como password', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="field-cert-pin"]')).toHaveAttribute('type', 'password')
  })

  test('Toggle CertPin muestra/oculta', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="btn-toggle-cert-pin"]')
    await expect(page.locator('[data-testid="field-cert-pin"]')).toHaveAttribute('type', 'text')


    await page.click('[data-testid="btn-toggle-cert-pin"]')
    await expect(page.locator('[data-testid="field-cert-pin"]')).toHaveAttribute('type', 'password')
  })

  test('TokenPass inicia como password', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="field-token-pass"]')).toHaveAttribute('type', 'password')
  })

  test('Toggle TokenPass muestra/oculta', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="btn-toggle-token-pass"]')
    await expect(page.locator('[data-testid="field-token-pass"]')).toHaveAttribute('type', 'text')

    await page.click('[data-testid="btn-toggle-token-pass"]')
    await expect(page.locator('[data-testid="field-token-pass"]')).toHaveAttribute('type', 'password')
  })
})

// ─── Suite: Create — EmailCC dinámico ─────────────────────────────────────────

test.describe('Companies Create — EmailCC dinámico', () => {
  test('Existe un input email al inicio', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="email-cc-input"]')).toHaveCount(1)
  })

  test('Botón + agrega un nuevo campo email', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="btn-add-email"]')
    await expect(page.locator('[data-testid="email-cc-input"]')).toHaveCount(2)
  })

  test('Botón - en único email muestra error (no elimina)', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="btn-remove-email-0"]')
    await expect(
      page.locator('[data-testid="error-modal"], [data-testid="toast"]')
    ).toBeVisible()
    await expect(page.locator('[data-testid="email-cc-input"]')).toHaveCount(1)
  })

  test('Botón - con 2 emails elimina correctamente', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="btn-add-email"]')
    await page.locator('[data-testid="btn-remove-email-0"]').first().click()
    await expect(page.locator('[data-testid="email-cc-input"]')).toHaveCount(1)
  })
})

// ─── Suite: Create — UseFactProv ──────────────────────────────────────────────

test.describe('Companies Create — Factura Proveedor', () => {
  test('sapFields deshabilitados inicialmente', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="field-num-serie-prov"]')).toBeDisabled()
  })

  test('UseFactProv habilita sapFields', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="field-use-fact-prov"]')
    await expect(page.locator('[data-testid="field-num-serie-prov"]')).toBeEnabled()
  })

  test('SendReceptAndApInv oculto inicialmente', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="field-send-recept"]')).toBeHidden()
  })

  test('SendReceptAndApInv visible tras activar UseFactProv', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="field-use-fact-prov"]')
    await expect(page.locator('[data-testid="field-send-recept"]')).toBeVisible()
  })

  test('Agregar tolerancia XML añade fila', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="field-use-fact-prov"]')
    const initial = await page.locator('[data-testid="xml-tolerance-row"]').count()
    await page.click('[data-testid="btn-add-tolerance"]')
    await expect(page.locator('[data-testid="xml-tolerance-row"]')).toHaveCount(initial + 1)
  })

  test('Agregar mapeo de moneda añade fila', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await page.click('[data-testid="field-use-fact-prov"]')
    const initial = await page.locator('[data-testid="currency-mapping-row"]').count()
    await page.click('[data-testid="btn-add-currency-mapping"]')
    await expect(page.locator('[data-testid="currency-mapping-row"]')).toHaveCount(initial + 1)
  })
})

// ─── Suite: Create — Botón Registrar ─────────────────────────────────────────

test.describe('Companies Create — Botón Registrar', () => {
  test('Botón deshabilitado sin datos', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)

    await expect(page.locator('[data-testid="btn-register"]')).toBeDisabled()
  })

  test('Botón habilitado con datos válidos', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await page.goto(CREATE_URL)
    await page.waitForTimeout(500)

    await page.fill('[data-testid="field-comercial-name"]', 'Empresa Test')
    await page.fill('[data-testid="field-legal-name"]',    'Empresa Test SA')
    await page.fill('[data-testid="field-identification"]', '123456789')
    await page.fill('[data-testid="field-codigo-actividad"]', '123456')
    await page.fill('[data-testid="field-short-name"]', 'ETS')
    await page.fill('[data-testid="field-db-sap"]', 'DBTEST')
    await page.selectOption('[data-testid="field-sap-connection"]', '10')

    await expect(page.locator('[data-testid="btn-register"]')).not.toBeDisabled()
  })
})

// ─── Suite: Edit — Estructura ─────────────────────────────────────────────────

test.describe('Companies Edit — Estructura', () => {
  test('Página /edit carga correctamente', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)

    await expect(page.locator('[data-testid="company-form-page"]')).toBeVisible()
  })

  test('Modo edición: botón Registrar OCULTO', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(500)

    await expect(page.locator('[data-testid="btn-register"]')).toBeHidden()
  })

  test('Modo edición: botones Actualizar por sección visibles', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(500)

    await expect(page.locator('[data-testid="btn-save-general"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-save-additional"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-save-atv"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-save-attachments"]')).toBeVisible()
    await expect(page.locator('[data-testid="btn-save-activity-codes"]')).toBeVisible()
  })

  test('Sección Códigos de actividad VISIBLE en modo edición', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(500)

    await expect(page.locator('[data-testid="section-activity-codes"]')).toBeVisible()
  })

  test('Datos generales se pre-populan desde API', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)

    await expect(page.locator('[data-testid="field-comercial-name"]'))
      .toHaveValue('Empresa Comercial')
    await expect(page.locator('[data-testid="field-legal-name"]'))
      .toHaveValue('Empresa Legal SA')
    await expect(page.locator('[data-testid="field-identification"]'))
      .toHaveValue('123456789')
  })

  test('ATV se pre-popula con pin y token de usuario', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)

    await expect(page.locator('[data-testid="field-cert-pin"]')).toHaveValue('1234')
    await expect(page.locator('[data-testid="field-token-usr"]')).toHaveValue('123456789')
  })

  test('EmailCC pre-populado con múltiples correos', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)

    await expect(page.locator('[data-testid="email-cc-input"]')).toHaveCount(2)
  })

  test('Códigos de actividad pre-cargados desde API', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)

    await expect(page.locator('[data-testid="activity-code-row"]')).toHaveCount(1)
  })

  test('Botón agregar código de actividad añade fila', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)

    const initial = await page.locator('[data-testid="activity-code-row"]').count()
    await page.click('[data-testid="btn-add-activity-code"]')
    await expect(page.locator('[data-testid="activity-code-row"]')).toHaveCount(initial + 1)
  })
})

// ─── Suite: Edit — Guardar por sección ────────────────────────────────────────

test.describe('Companies Edit — Guardar por sección', () => {
  test('Actualizar datos generales hace PATCH con action=1', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)

    let patchUrl = ''
    await page.route('**/api/Companies**', route => {
      if (route.request().method() === 'PATCH') {
        patchUrl = route.request().url()
        route.fulfill({ json: { Data: true, Error: false, Message: null } })
      } else {
        route.continue()
      }
    })

    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)
    await page.click('[data-testid="btn-save-general"]')
    await page.waitForTimeout(500)

    expect(patchUrl).toContain('action=1')
    await expect(page.locator('[data-testid="toast"]')).toBeVisible()
    await expect(page.locator('[data-testid="toast"]')).toContainText('generales actualizados')
  })

  test('Actualizar datos adicionales hace PATCH con action=5', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)

    let patchUrl = ''
    await page.route('**/api/Companies**', route => {
      if (route.request().method() === 'PATCH') {
        patchUrl = route.request().url()
        route.fulfill({ json: { Data: true, Error: false, Message: null } })
      } else {
        route.continue()
      }
    })

    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)
    await page.click('[data-testid="btn-save-additional"]')
    await page.waitForTimeout(500)

    expect(patchUrl).toContain('action=5')
    await expect(page.locator('[data-testid="toast"]')).toBeVisible()
    await expect(page.locator('[data-testid="toast"]')).toContainText('adicional actualizada')
  })
})

// ─── Suite: Edit — Validación certificado ─────────────────────────────────────

test.describe('Companies Edit — Validación ATV', () => {
  test('CertPath que no coincide con identificación muestra error al guardar ATV', async ({ page }) => {
    await injectAuth(page)
    await mockInitialData(page)
    await mockCompanyDetail(page)
    await page.goto(EDIT_URL)
    await page.waitForTimeout(800)

    await page.evaluate(() => {
      const input = document.querySelector('[data-testid="field-cert-path"]')
      if (input) {
        input.removeAttribute('readonly')
        input.value = 'certificado-erroneo.p12'
      }
    })

    await page.click('[data-testid="btn-save-atv"]')
    await expect(page.locator('[data-testid="toast"]')).toBeVisible()
    await expect(page.locator('[data-testid="toast"]')).toContainText('no coincide')
  })
})

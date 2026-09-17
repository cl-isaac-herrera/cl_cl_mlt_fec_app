# Clavisco Reusable Components

This directory contains migrated @clavisco components from the Angular application.

## Purpose

These are **reusable libraries** used across multiple Clavisco projects, not EMA-specific code.

## Structure

```
vendor/clavisco/
├── index.js                    # Main entry point - exports all modules
├── core/                       # Core utilities and structures
│   └── index.js                # Storage, API helpers, utility functions
├── linker/                     # Pub/Sub event communication
│   └── index.js                # publish, subscribe, flow
├── table/                      # Data table component
│   ├── index.js                # Module exports
│   └── controllers/            # Stimulus controller
├── search-modal/               # Search modal component
│   ├── index.js                # Module exports
│   └── controllers/            # Stimulus controller
├── payment-modal/              # Payment modal component
│   ├── index.js                # Module exports
│   └── controllers/            # Stimulus controller
├── overlay/                    # Modal/overlay service
│   └── index.js                # open, close, showLoading
├── menu/                       # Menu service
│   └── index.js                # Navigation utilities
├── login/                      # Authentication service
│   └── index.js                # login, logout, checkAuth
├── notification-center/        # Notification center
│   └── index.js                # Notification management
├── pinpad/                     # Pinpad integration
│   └── index.js                # Payment terminal service
├── dynamics-udfs-presentation/ # UDF display components
│   └── index.js                # UDF rendering utilities
├── dynamics-udfs-console/      # UDF admin console
│   └── index.js                # UDF CRUD operations
└── rptmng-menu/                # Report manager
    └── index.js                # Report generation/export
```

## Migrated Components

| Component | Status | Description |
|-----------|--------|-------------|
| ✅ core | Done | Storage, API headers, utility functions |
| ✅ linker | Done | Pub/Sub communication between components |
| ✅ table | Done | Data table with pagination, sorting, selection |
| ✅ search-modal | Done | Modal search with API integration |
| ✅ payment-modal | Done | Payment processing modal |
| ✅ overlay | Done | Modal/overlay service |
| ✅ menu | Done | Menu navigation service |
| ✅ login | Done | OAuth2 authentication |
| ✅ notification-center | Done | Notification management |
| ✅ pinpad | Done | Pinpad/terminal integration |
| ✅ dynamics-udfs-presentation | Done | UDF display and editing |
| ✅ dynamics-udfs-console | Done | UDF admin management |
| ✅ rptmng-menu | Done | Report generation and export |

## Usage from EMA Code

### JavaScript (Stimulus Controllers)

```javascript
// Import specific functions
import { Storage, getApiHeaders, apiRequest } from 'vendor/clavisco/core'
import { publish, subscribe } from 'vendor/clavisco/linker'
import Swal from 'sweetalert2' // notificaciones y confirmaciones (CLAVISCO-PLATFORM-STANDARDS §5.1)
import { open, close, showLoading, hideLoading } from 'vendor/clavisco/overlay'
import { login, logout, checkAuth } from 'vendor/clavisco/login'

// Or import entire modules
import * as Core from 'vendor/clavisco/core'
```

### Stimulus Controllers Registration

```javascript
// app/javascript/controllers/index.js
import TableController from 'vendor/clavisco/table/controllers/table_controller'
import SearchModalController from 'vendor/clavisco/search-modal/controllers/search_modal_controller'

application.register('table', TableController)
application.register('search-modal', SearchModalController)
```

### ERB Views

```erb
<!-- Use in views with data-controller -->
<div data-controller="table"
     data-table-records-value="<%= @records.to_json %>"
     data-table-columns-value="<%= @columns.to_json %>">
</div>
```

## API Reference

### Core (`vendor/clavisco/core`)

- `Storage` - LocalStorage wrapper with JSON parsing
- `getApiHeaders()` - Get standard API headers with auth
- `apiRequest(url, options)` - Make authenticated API request
- `clPrint(message, type)` - Formatted console logging
- `getError(error)` - Extract error message from objects
- `downloadBase64File(base64, name, type, ext)` - Download file
- `printBase64File({base64File, blobType, onNewWindow})` - Print file

### Linker (`vendor/clavisco/linker`)

- `publish(event)` - Publish event to all subscribers
- `subscribe(view, callback)` - Subscribe to events for a view
- `flow(callback)` - Subscribe to all events

### Alerts

Ya no viven acá. CLAVISCO-PLATFORM-STANDARDS §5.1 manda usar SweetAlert2 directo, sin wrapper
propio — `import Swal from 'sweetalert2'` y `Swal.fire({...})`. Ver `CLAUDE.md` §7/§16 en el
root del proyecto para la receta exacta de toast/confirmación.

### Overlay (`vendor/clavisco/overlay`)

- `open(modalId, options)` - Open modal by ID
- `close(modalId, result)` - Close modal
- `closeAll()` - Close all open modals
- `showLoading(message)` - Show loading overlay
- `hideLoading()` - Hide loading overlay

### Login (`vendor/clavisco/login`)

- `login(username, password)` - Authenticate user
- `logout()` - Log out user
- `checkAuth()` - Check authentication status
- `getUser()` - Get current user
- `getCompany()` - Get current company
- `hasPermission(code)` - Check user permission

## Future: Git Submodules

In Phase 2, each component directory will be extracted to its own git repository and added back as a git submodule. This allows:

- Reuse across multiple projects
- Independent versioning
- Shared maintenance

The import paths will remain the same, ensuring no code changes are needed.

// Entry point para la aplicación FEC
// Importmap carga automáticamente los controllers registrados en controllers/index.js

import '@hotwired/turbo-rails'
import Swal from 'sweetalert2'
import 'controllers'

// CLAVISCO-PLATFORM-STANDARDS §5.1 — un link/botón con data-turbo-confirm="..." dispara por
// default el confirm() feo del navegador. Se reconfigura una sola vez, a nivel de app, para
// que use el mismo modal de SweetAlert2 que el resto de la app (ver CLAUDE.md §16). `Turbo` es
// global (expuesto por @hotwired/turbo-rails en window.Turbo), igual que en el resto del
// código de este proyecto (Turbo.visit, etc.) — no requiere import propio.
Turbo.config.forms.confirm = (message) =>
  Swal.fire({
    title: message,
    icon: 'warning',
    showCancelButton: true,
    confirmButtonText: 'Confirmar',
    cancelButtonText: 'Cancelar'
  }).then(({ isConfirmed }) => isConfirmed)

# frozen_string_literal: true

module Configurations
  # EmailSendersController — Bandejas de correo de envío.
  #
  # Replica el tab "Bandeja de Correos" del `/emailInbox` de Angular
  # (`EmailInboxConfigComponent`). El otro tab de esa pantalla
  # (`EmailInboxAssigmentComponent`, "Asignación de Bandejas a Compañías") NO se
  # migró: la bandeja de cada compañía se elige en la sección "Datos Generales"
  # de su propio formulario — ver el comentario de cabecera de
  # `app/javascript/controllers/email_senders_controller.js`.
  #
  # La tabla, el panel lateral y la prueba de credenciales los maneja Stimulus
  # (`email_senders_controller.js`) contra `/api/email_configs`.
  class EmailSendersController < ApplicationController
    layout 'protected'

    def index; end
  end
end

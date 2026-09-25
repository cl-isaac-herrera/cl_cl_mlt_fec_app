# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Companies::GeneralController', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }
  let(:sap)  { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1') }
  let(:acme) do
    Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME',
                    issuer_id_number: '3101822733', email_cc: 'copia@acme.cr',
                    purchase_invoice_series: 7, default_warehouse: 'PRIN')
  end

  # Las ocho claves de la sección. Son el contrato entre el `GET` y el `PATCH`
  # de este mismo controller: si una se agrega en un lado y no en el otro, el
  # formulario muestra un campo que el guardado ignora y el usuario no se
  # entera.
  #
  # El bloque del emisor ante Hacienda (`EmsrNombre`, `EmsrIdeTipo`,
  # `CodigoActividad`, `EmsrRegistroFiscal8707`, y el espejo `Name`/
  # `EmsrIdeNumero`) se partió a su propia sección — ver
  # `company_legal_data_spec.rb`. Esta sección no habla con SAP en absoluto,
  # ni para leer ni para guardar.
  GENERAL_KEYS = %w[
    Active SendRejectedDocuments ConnectionId EmailConfigId ReceptionMailboxId SapDb
    EmailSenderType FreightType
  ].freeze

  def sign_in_with(*permission_names)
    grant_permissions(user, *permission_names, company: acme)
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  def get_section
    get "/api/companies/#{acme.id}/general"
  end

  def patch_section(payload)
    patch "/api/companies/#{acme.id}/general", params: payload, as: :json
  end

  describe 'GET /api/companies/:company_id/general' do
    describe 'autorización' do
      it 'responde 401 sin sesión' do
        get_section

        expect(response).to have_http_status(:unauthorized)
      end

      it 'exige Configurations_Companies_Update' do
        sign_in_with('Configurations_Companies_ListAccess')

        get_section

        expect(response).to have_http_status(:forbidden)
      end

      it 'también alcanza con Configurations_Companies_UpdateInAllCompanies (de instalación)' do
        grant_permissions(user, 'Configurations_Companies_UpdateInAllCompanies',
                         'Configurations_Companies_ViewAllApplicationCompanies')
        sign_in(user, company: acme)

        get_section

        expect(response).to have_http_status(:ok)
      end

      it 'responde 404 con un id que no existe' do
        sign_in_with('Configurations_Companies_Update')

        get '/api/companies/999999/general'

        expect(response).to have_http_status(:not_found)
      end

      it 'responde 404 con una compañía fuera de su alcance' do
        ajena = Company.create!(name: 'Ajena S.A.')
        sign_in_with('Configurations_Companies_Update')

        get "/api/companies/#{ajena.id}/general"

        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'lectura' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'no habla con SAP' do
        expect(Sap::UserClient).not_to receive(:for)
        expect(Sap::CompanyClient).not_to receive(:for)

        get_section

        expect(response).to have_http_status(:ok)
      end

      it 'devuelve las ocho claves de la sección' do
        get_section

        expect(body_data.keys).to match_array(GENERAL_KEYS)
      end

      it 'devuelve los valores actuales de la compañía' do
        acme.update!(sap_db: 'SBO_LECTURA', email_sender_type: 2)

        get_section

        expect(body_data).to include('SapDb' => 'SBO_LECTURA', 'EmailSenderType' => 2)
      end
    end
  end

  describe 'PATCH /api/companies/:company_id/general' do
    describe 'autorización' do
      it 'responde 401 sin sesión' do
        patch "/api/companies/#{acme.id}/general", params: { SapDb: 'X' }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'exige Configurations_Companies_Update' do
        sign_in_with('Configurations_Companies_ListAccess')

        patch_section(SapDb: 'SBO_OTRA')

        expect(response).to have_http_status(:forbidden)
        expect(acme.reload.sap_db).to eq('SBO_ACME')
      end

      # Alcanza con el permiso de INSTALACIÓN (docs/PLAN-ROLES-POR-ALCANCE.md), sin
      # que el usuario tenga rol de compañía ni esté asignado a `acme` — de ahí
      # que también necesite `ViewAllApplicationCompanies` para que
      # `find_visible_company` la encuentre.
      it 'también alcanza con Configurations_Companies_UpdateInAllCompanies (de instalación)' do
        grant_permissions(user, 'Configurations_Companies_UpdateInAllCompanies',
                         'Configurations_Companies_ViewAllApplicationCompanies')
        sign_in(user, company: acme)

        patch_section(SapDb: 'SBO_INSTALACION')

        expect(response).to have_http_status(:ok)
        expect(acme.reload.sap_db).to eq('SBO_INSTALACION')
      end

      it 'responde 404 con un id que no existe' do
        sign_in_with('Configurations_Companies_Update')

        patch '/api/companies/999999/general', params: { SapDb: 'X' }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      # El alcance es el mismo de la lectura: sin "ver todas", una compañía ajena no
      # existe para este usuario, y por eso es 404 y no 403.
      it 'responde 404 con una compañía fuera de su alcance' do
        ajena = Company.create!(name: 'Ajena S.A.')
        sign_in_with('Configurations_Companies_Update')

        patch "/api/companies/#{ajena.id}/general", params: { SapDb: 'X' }, as: :json

        expect(response).to have_http_status(:not_found)
        expect(ajena.reload.sap_db).to be_nil
      end
    end

    describe 'guardado' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'actualiza los campos de la sección' do
        otra = Connection.create!(name: 'SAP Prod', sl_url: 'https://prod.test:50000/b1s/v1')

        patch_section(
          Active: false, SendRejectedDocuments: true,
          ConnectionId: otra.id, SapDb: 'SBO_NUEVA',
          EmailSenderType: 2, FreightType: 2
        )

        expect(response).to have_http_status(:ok)
        expect(acme.reload).to have_attributes(
          is_active: false, send_rejected_documents: true,
          connection_id: otra.id, sap_db: 'SBO_NUEVA',
          email_sender_type: 2, freight_type: 2
        )
      end

      # El default de la columna es `false`: avisar solo de lo aceptado. Apagar el
      # check tiene que poder volver a ese estado, no quedarse encendido porque
      # `false` "parece vacío".
      it 'vuelve a excluir los rechazados al apagar el check' do
        acme.update!(send_rejected_documents: true)

        patch_section(SendRejectedDocuments: false)

        expect(response).to have_http_status(:ok)
        expect(acme.reload.send_rejected_documents).to be(false)
        expect(body_data['SendRejectedDocuments']).to be(false)
      end

      it 'devuelve la sección como quedó guardada, con el mensaje' do
        patch_section(SapDb: '  SBO_NUEVA  ')

        expect(body_data['SapDb']).to eq('SBO_NUEVA')
        expect(body['Message']).to eq('Datos generales actualizados con éxito.')
      end

      it 'no borra lo que la petición no mencionó' do
        patch_section(SapDb: 'SBO_NUEVA')

        expect(acme.reload).to have_attributes(name: 'ACME S.A.', issuer_id_number: '3101822733')
      end

      it 'no habla con SAP' do
        expect(Sap::UserClient).not_to receive(:for)
        expect(Sap::CompanyClient).not_to receive(:for)

        patch_section(SapDb: 'SBO_NUEVA')

        expect(response).to have_http_status(:ok)
      end

      it 'acepta desasignar la conexión de SAP' do
        patch_section(ConnectionId: nil)

        expect(acme.reload.connection_id).to be_nil
      end
    end

    # Lo que hace que los botones sean independientes de verdad y no solo en la
    # pantalla: este endpoint no puede tocar nada de otra sección, ni siquiera si
    # viene en el cuerpo.
    describe 'aislamiento entre secciones' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'ignora los campos que pertenecen a otras secciones' do
        patch_section(
          SapDb: 'SBO_NUEVA',
          # Sección "Datos Legales de la Compañía"
          Name: 'ACME Global', EmsrNombre: 'ACME Global S.A.',
          # Sección "Adicional"
          EmailCC: 'otro@acme.cr',
          # Sección "Hacienda (ATV)"
          CertPin: '9999', TokenUsr: 'atv', CertPath: 'C:\\otro.p12',
          # Sección "Factura a proveedor"
          PurchInvSeriesNum: 99, DefaultWarehouse: 'OTRO',
          # Ni una columna que no existe
          Uuid: 'reescrito'
        )

        expect(response).to have_http_status(:ok)
        expect(acme.reload).to have_attributes(
          name: 'ACME S.A.',
          sap_db: 'SBO_NUEVA',
          email_cc: 'copia@acme.cr',
          purchase_invoice_series: 7,
          default_warehouse: 'PRIN',
          cert_pin: nil,
          token_user: nil
        )
        expect(acme.uuid).to be_present
        expect(acme.uuid).not_to eq('reescrito')
      end
    end

    describe 'validación' do
      before { sign_in_with('Configurations_Companies_Update') }

      # Sin la validación del modelo esto reventaba contra la llave foránea y
      # llegaba como un 500 en vez de un mensaje.
      it 'rechaza una conexión de SAP que no existe, sin reventar' do
        patch_section(ConnectionId: 999_999)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('La conexión de SAP no corresponde a una conexión existente')
      end
    end

    # La bandeja de correo es de dónde SALEN los correos de la compañía
    # (`companies.email_config_id`). Antes de este campo la columna no la escribía
    # nadie y toda compañía quedaba sin poder enviar.
    describe 'bandeja de correo' do
      let(:inbox) do
        EmailConfig.create!(email: 'ventas@acme.com', host: 'smtp.test', port: 587,
                            password: 's3cr3t')
      end

      before { sign_in_with('Configurations_Companies_Update') }

      it 'asigna la bandeja' do
        patch_section(EmailConfigId: inbox.id)

        expect(response).to have_http_status(:ok)
        expect(acme.reload.email_config_id).to eq(inbox.id)
        expect(body_data['EmailConfigId']).to eq(inbox.id)
      end

      # Vaciar el select ES desasignar: "sin bandeja" es un estado válido, la
      # compañía simplemente no envía todavía.
      it 'desasigna la bandeja con null' do
        acme.update!(email_config: inbox)

        patch_section(EmailConfigId: nil)

        expect(response).to have_http_status(:ok)
        expect(acme.reload.email_config_id).to be_nil
      end

      # Sin la validación del modelo esto sería un 500 de la llave foránea.
      it 'rechaza una bandeja inexistente con un mensaje, no con un 500' do
        patch_section(EmailConfigId: 999_999)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('La bandeja de correo no corresponde a una bandeja de correo activa')
      end

      # Asignar una dada de baja dejaría a la compañía sin poder enviar en
      # silencio: `Company#email_config` devuelve nil por el default_scope.
      it 'rechaza una bandeja dada de baja' do
        inbox.update!(is_active: false)

        patch_section(EmailConfigId: inbox.id)

        expect(response).to have_http_status(:unprocessable_content)
        expect(acme.reload.email_config_id).to be_nil
      end
    end

    # La bandeja de RECEPCIÓN es de dónde `MailReceptionJob` lee los documentos
    # de los proveedores (`companies.reception_mailbox_id`). Mismo criterio de
    # validación que la de correo (§38): opcional, `unscoped` no aplica.
    describe 'bandeja de recepción' do
      let(:inbox) do
        ReceptionMailbox.create!(mail_server: 'imap.acme.test', email: 'facturas@acme.com',
                                 port: 993, password: 's3cr3t')
      end

      before { sign_in_with('Configurations_Companies_Update') }

      it 'asigna la bandeja' do
        patch_section(ReceptionMailboxId: inbox.id)

        expect(response).to have_http_status(:ok)
        expect(acme.reload.reception_mailbox_id).to eq(inbox.id)
        expect(body_data['ReceptionMailboxId']).to eq(inbox.id)
      end

      it 'desasigna la bandeja con null' do
        acme.update!(reception_mailbox: inbox)

        patch_section(ReceptionMailboxId: nil)

        expect(response).to have_http_status(:ok)
        expect(acme.reload.reception_mailbox_id).to be_nil
      end

      it 'rechaza una bandeja inexistente con un mensaje, no con un 500' do
        patch_section(ReceptionMailboxId: 999_999)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body['Message']).to eq('La bandeja de recepción no corresponde a una bandeja de recepción activa')
      end

      it 'rechaza una bandeja dada de baja' do
        inbox.update!(is_active: false)

        patch_section(ReceptionMailboxId: inbox.id)

        expect(response).to have_http_status(:unprocessable_content)
        expect(acme.reload.reception_mailbox_id).to be_nil
      end
    end

    # El PATCH acepta y devuelve las mismas ocho claves que el `GET`. No es
    # automático —la lista de arriba se mantiene a mano— pero deja el contrato
    # en un solo lugar y falla si alguno de los dos lados deja de exponer un
    # campo (ver también "lectura" en el describe del `GET`, más arriba).
    describe 'contrato con la lectura' do
      before { sign_in_with('Configurations_Companies_Update') }

      it 'acepta y devuelve las mismas ocho claves que el GET' do
        inbox = EmailConfig.create!(email: 'ventas@acme.com', host: 'smtp.test',
                                    port: 587, password: 's3cr3t')
        reception_inbox = ReceptionMailbox.create!(mail_server: 'imap.acme.test', email: 'facturas@acme.com',
                                                   port: 993, password: 's3cr3t')
        payload = {
          'Active' => true, 'SendRejectedDocuments' => true,
          'ConnectionId' => sap.id,
          'EmailConfigId' => inbox.id,
          'ReceptionMailboxId' => reception_inbox.id,
          'SapDb' => 'SBO_NUEVA', 'EmailSenderType' => 2, 'FreightType' => 2
        }
        # El payload de este ejemplo tampoco puede quedarse corto respecto a la lista.
        expect(payload.keys).to match_array(GENERAL_KEYS)

        patch_section(payload)

        expect(response).to have_http_status(:ok)
        expect(body_data.keys).to match_array(GENERAL_KEYS)
      end
    end
  end
end

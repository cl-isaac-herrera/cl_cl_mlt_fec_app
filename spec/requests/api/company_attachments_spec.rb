# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PATCH /api/companies/:company_id/attachments', type: :request do
  let(:user) { User.create!(email: 'admin@example.com') }
  let(:role) { Role.create!(name: 'Configurador') }
  let(:sap)  { Connection.create!(name: 'SAP QA', sl_url: 'https://sap.test:50000/b1s/v1') }

  # La raíz de archivos se apunta a una carpeta descartable ANTES de que se cree
  # la compañía: sus rutas de partida tienen que quedar adentro, o el borrado del
  # anterior no aplicaría y el ejemplo probaría otra cosa.
  let!(:files_root) { use_temporary_files_root }

  let(:acme) do
    Company.create!(name: 'ACME S.A.', sap_connection: sap, sap_db: 'SBO_ACME',
                    issuer_legal_name: 'ACME Sociedad Anónima', issuer_id_type: '02',
                    issuer_id_number: '3101822733', economic_activity_code: '7020',
                    logo_path: stored_path('viejo-logo.png'),
                    print_format_path: stored_path('viejo-formato.rpt'),
                    cert_path: stored_path('cert.p12'), cert_pin: '1234',
                    token_user: 'atv@hacienda.go.cr', token_password: 'secreto-atv')
  end

  # Las dos claves de la sección. Son el contrato entre la lectura
  # (`GET /api/companies/:id`) y este PATCH: si una se agrega en un lado y no en
  # el otro, el formulario muestra un campo que el guardado ignora y el usuario no
  # se entera. Los dos ejemplos de "contrato" de más abajo lo verifican.
  ATTACHMENT_KEYS = %w[LogoFileName PrintFormatFileName].freeze

  # Bytes cualesquiera: nadie los abre ni los interpreta. El `0x1a` está a
  # propósito — es el EOF de DOS, y si algún handle quedara en modo texto la
  # escritura cortaría ahí.
  let(:logo_bytes)   { "\x89PNG\r\n\x1a\nlogo-de-acme".b }
  let(:format_bytes) { "CRYSTAL\x1areporte-de-acme".b }

  def stored_path(name, id_number: '3101822733')
    File.join(files_root, id_number, name)
  end

  def write_stored!(path, contents = 'anterior')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
    path
  end

  def sign_in_with(*permission_names)
    UsersByCompany.create!(user: user, company: acme)
    UserRole.create!(user: user, role: role, company: acme)
    permission_names.each do |name|
      RolePermission.create!(role: role, permission: Permission.find_or_create_by!(name: name))
    end
    sign_in(user, company: acme)
  end

  def body      = JSON.parse(response.body)
  def body_data = body['Data']

  # Multipart: los dos campos de la sección son archivos, así que el cuerpo no es
  # JSON.
  def patch_section(payload)
    patch "/api/companies/#{acme.id}/attachments", params: payload
  end

  def logo_upload(filename: 'logo-acme.png')
    uploaded_file(logo_bytes, filename: filename, type: 'image/png')
  end

  def format_upload(filename: 'formato-acme.rpt')
    uploaded_file(format_bytes, filename: filename, type: 'application/x-rpt')
  end

  describe 'autorización' do
    it 'responde 401 sin sesión' do
      patch "/api/companies/#{acme.id}/attachments", params: { Logo: logo_upload }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'exige Configurations_Companies_Update' do
      sign_in_with('Configurations_Companies_ListAccess')

      patch_section(Logo: logo_upload)

      expect(response).to have_http_status(:forbidden)
      expect(acme.reload.logo_path).to eq(stored_path('viejo-logo.png'))
    end

    it 'responde 404 con un id que no existe' do
      sign_in_with('Configurations_Companies_Update')

      patch '/api/companies/999999/attachments', params: { Logo: logo_upload }

      expect(response).to have_http_status(:not_found)
    end

    # El alcance es el mismo de la lectura: sin "ver todas", una compañía ajena no
    # existe para este usuario, y por eso es 404 y no 403.
    it 'responde 404 con una compañía fuera de su alcance' do
      ajena = Company.create!(name: 'Ajena S.A.', issuer_id_number: '3101999999',
                              logo_path: stored_path('ajeno.png', id_number: '3101999999'))
      sign_in_with('Configurations_Companies_Update')

      patch "/api/companies/#{ajena.id}/attachments", params: { Logo: logo_upload }

      expect(response).to have_http_status(:not_found)
      expect(ajena.reload.logo_path).to eq(stored_path('ajeno.png', id_number: '3101999999'))
    end
  end

  describe 'guardado de los archivos' do
    before { sign_in_with('Configurations_Companies_Update') }

    # `{FILES_BASE_PATH}/{cédula}/logo.{extensión}`: la carpeta la arma la cédula
    # y el nombre es fijo.
    it 'escribe el logo en la carpeta de la cédula y guarda su ruta' do
      patch_section(Logo: logo_upload)

      expect(response).to have_http_status(:ok)
      expect(acme.reload.logo_path).to eq(stored_path('logo.png'))
      expect(File.binread(stored_path('logo.png'))).to eq(logo_bytes)
    end

    it 'escribe el formato de impresión y guarda su ruta' do
      patch_section(PrintFormat: format_upload)

      expect(response).to have_http_status(:ok)
      expect(acme.reload.print_format_path).to eq(stored_path('formato-acme.rpt'))
      expect(File.binread(stored_path('formato-acme.rpt'))).to eq(format_bytes)
    end

    it 'acepta los dos en la misma petición' do
      patch_section(Logo: logo_upload, PrintFormat: format_upload)

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        logo_path:         stored_path('logo.png'),
        print_format_path: stored_path('formato-acme.rpt')
      )
    end

    it 'devuelve la sección como quedó guardada, con el mensaje' do
      patch_section(Logo: logo_upload, PrintFormat: format_upload)

      expect(body_data).to eq('LogoFileName'        => 'logo.png',
                              'PrintFormatFileName' => 'formato-acme.rpt')
      expect(body['Message']).to eq('Adjuntos actualizados con éxito.')
    end

    # Es lo que hace que los dos botones de la pantalla sean independientes de
    # verdad: guardar el logo no puede tocar el formato, porque el formulario
    # muestra su nombre pero no vuelve a subir el archivo.
    it 'la parte ausente deja la otra columna como estaba' do
      patch_section(Logo: logo_upload)

      expect(acme.reload.print_format_path).to eq(stored_path('viejo-formato.rpt'))
    end

    # Un PATCH sin partes no se distingue de "el usuario no cambió nada": mismo
    # criterio que las otras dos secciones migradas.
    it 'sin archivos no cambia nada y responde 200' do
      patch_section({})

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        logo_path:         stored_path('viejo-logo.png'),
        print_format_path: stored_path('viejo-formato.rpt')
      )
    end

    # El logo NO conserva el nombre con el que se subió: la carpeta de la
    # compañía tiene un solo logo, con un nombre predecible.
    it 'guarda el logo como logo.{extensión}, sin importar cómo se llamaba' do
      patch_section(Logo: logo_upload(filename: 'Logo Corporativo v3 (final).PNG'))

      expect(acme.reload.logo_path).to eq(stored_path('logo.png'))
      expect(File).to exist(stored_path('logo.png'))
      expect(body_data['LogoFileName']).to eq('logo.png')
    end

    it 'respeta la extensión que traía el archivo' do
      patch_section(Logo: logo_upload(filename: 'lo-que-sea.jpeg'))

      expect(acme.reload.logo_path).to eq(stored_path('logo.jpeg'))
    end

    # El nombre fijo también cierra el traversal por el nombre del archivo: no
    # queda nada del valor que mandó el cliente.
    it 'ignora las carpetas que venga en el nombre del logo' do
      patch_section(Logo: logo_upload(filename: '../../../etc/logo.png'))

      expect(acme.reload.logo_path).to eq(stored_path('logo.png'))
    end

    # El formato de impresión SÍ conserva su nombre —puede decir de qué documento
    # es—, pero limpiado antes de tocar el disco.
    it 'limpia el nombre del formato de impresión antes de que toque el disco' do
      patch_section(PrintFormat: format_upload(filename: '../../formato de la compañía.rpt'))

      expect(acme.reload.print_format_path).to eq(stored_path('formato_de_la_compa_a.rpt'))
      expect(File).to exist(stored_path('formato_de_la_compa_a.rpt'))
    end
  end

  describe 'reemplazo del archivo anterior' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'borra el anterior recién cuando el nuevo ya está guardado' do
      viejo = write_stored!(stored_path('viejo-logo.png'))

      patch_section(Logo: logo_upload)

      expect(File).not_to exist(viejo)
      expect(File).to exist(stored_path('logo.png'))
    end

    # Con el nombre fijo, recargar el logo con la misma extensión da la MISMA
    # ruta: se sobrescribe en su lugar, y borrar "la anterior" borraría la nueva.
    it 'no borra el archivo cuando la ruta no cambió' do
      acme.update!(logo_path: stored_path('logo.png'))
      write_stored!(stored_path('logo.png'))

      patch_section(Logo: logo_upload)

      expect(File.binread(stored_path('logo.png'))).to eq(logo_bytes)
    end

    # Cambiar de extensión sí cambia la ruta: sin este borrado la carpeta quedaría
    # con `logo.png` y `logo.jpeg`, y solo uno de los dos referenciado.
    it 'borra el logo anterior al cambiar de extensión' do
      acme.update!(logo_path: stored_path('logo.png'))
      write_stored!(stored_path('logo.png'))

      patch_section(Logo: logo_upload(filename: 'otro.jpeg'))

      expect(acme.reload.logo_path).to eq(stored_path('logo.jpeg'))
      expect(File).not_to exist(stored_path('logo.png'))
    end

    # Pasa con una compañía importada: su ruta apunta al disco del servidor .NET,
    # que esta aplicación no administra. Borrar ahí sería destruir el archivo que
    # el servicio de correo está usando.
    it 'no toca el anterior si está fuera de la raíz configurada' do
      afuera = Dir.mktmpdir('fuera-de-la-raiz')
      ajeno  = write_stored!(File.join(afuera, 'logo-del-net.png'))
      acme.update!(logo_path: ajeno)

      patch_section(Logo: logo_upload)

      expect(File).to exist(ajeno)
      expect(acme.reload.logo_path).to eq(stored_path('logo.png'))
    ensure
      FileUtils.remove_entry(afuera) if afuera
    end
  end

  describe 'archivos que no sirven' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'rechaza un logo con extensión que no corresponde' do
      patch_section(Logo: uploaded_file(logo_bytes, filename: 'logo.gif', type: 'image/gif'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Seleccione un logo con extensión válida (.jpg, .jpeg o .png).')
      expect(acme.reload.logo_path).to eq(stored_path('viejo-logo.png'))
      expect(File).not_to exist(stored_path('logo.gif'))
    end

    it 'rechaza un formato de impresión que no es .rpt' do
      patch_section(PrintFormat: uploaded_file(format_bytes, filename: 'formato.pdf'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to eq('Seleccione un formato de impresión con extensión válida (.rpt).')
      expect(acme.reload.print_format_path).to eq(stored_path('viejo-formato.rpt'))
    end

    # El tope se baja en vez de subir 2 MB de relleno: el `UploadedFile` que
    # recibe el servidor lo arma el parser multipart, así que no se le puede
    # falsear el tamaño desde acá.
    it 'rechaza un logo que supera el tamaño máximo' do
      stub_const('Attachments::LogoStore::MAX_BYTES', 4)

      patch_section(Logo: logo_upload)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('supera el tamaño máximo')
      expect(File).not_to exist(stored_path('logo.png'))
      expect(acme.reload.logo_path).to eq(stored_path('viejo-logo.png'))
    end

    it 'exige que la compañía tenga número de identificación' do
      acme.update_columns(issuer_id_number: nil)

      patch_section(Logo: logo_upload)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['Message']).to include('número de identificación')
    end

    # El logo se escribe primero y el formato falla después: el logo no lo apunta
    # ninguna fila, así que no se puede quedar tirado en el disco.
    it 'no deja a medias el archivo que sí se pudo escribir' do
      patch_section(Logo: logo_upload, PrintFormat: uploaded_file(format_bytes, filename: 'formato.doc'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(File).not_to exist(stored_path('logo.png'))
      expect(acme.reload).to have_attributes(
        logo_path:         stored_path('viejo-logo.png'),
        print_format_path: stored_path('viejo-formato.rpt')
      )
    end
  end

  # Cada botón "Actualizar" escribe SOLO lo suyo. Lo que venga de otra sección se
  # ignora en silencio, incluso si el cliente lo manda.
  describe 'aislamiento entre secciones' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'ignora los campos de las otras secciones' do
      patch_section(Logo: logo_upload, Name: 'Otro Nombre', SapDb: 'SBO_OTRA',
                    TokenUsr: 'otro@hacienda.go.cr', CertPin: '9999',
                    EmsrIdeNumero: '3101000000', Active: 'false')

      expect(response).to have_http_status(:ok)
      expect(acme.reload).to have_attributes(
        name:             'ACME S.A.',
        sap_db:           'SBO_ACME',
        token_user:       'atv@hacienda.go.cr',
        cert_pin:         '1234',
        issuer_id_number: '3101822733',
        is_active:        true
      )
    end

    # Las dos columnas guardan la ruta absoluta que otro proceso abre; el
    # formulario solo muestra el nombre. Aceptarlas del cuerpo dejaba `logo.png` a
    # secas en una columna que se lee como ruta.
    it 'ignora las rutas si vienen en el cuerpo' do
      patch_section(LogoPath: 'C:\\ruta\\inventada\\logo.png',
                    PrintFormatPath: 'C:\\ruta\\inventada\\formato.rpt')

      expect(acme.reload).to have_attributes(
        logo_path:         stored_path('viejo-logo.png'),
        print_format_path: stored_path('viejo-formato.rpt')
      )
    end
  end

  # El contrato de arriba, verificado de los dos lados. No es automático —la lista
  # se mantiene a mano— pero deja el contrato en un solo lugar y falla si alguno
  # de los dos deja de exponer un campo.
  describe 'contrato con la lectura' do
    before { sign_in_with('Configurations_Companies_Update') }

    it 'GET /api/companies/:id devuelve las dos claves de la sección' do
      get "/api/companies/#{acme.id}"

      expect(body_data.keys).to include(*ATTACHMENT_KEYS)
    end

    it 'el PATCH devuelve esas mismas dos claves' do
      patch_section(Logo: logo_upload, PrintFormat: format_upload)

      expect(response).to have_http_status(:ok)
      expect(body_data.keys).to match_array(ATTACHMENT_KEYS)
    end

    # El formulario muestra el nombre del archivo, no la ruta: dónde lo guardó el
    # servidor no es asunto de la pantalla.
    it 'la lectura devuelve el nombre y nunca la ruta' do
      get "/api/companies/#{acme.id}"

      expect(body_data).to include('LogoFileName'        => 'viejo-logo.png',
                                   'PrintFormatFileName' => 'viejo-formato.rpt')
      expect(response.body).not_to include(files_root)
    end
  end
end

# frozen_string_literal: true

module Api
  module Companies
    # Sección "Datos de Conexión de Hacienda (ATV)" del formulario de compañías.
    #
    # Un endpoint por sección, igual que `GeneralController`: en la pantalla cada
    # sección tiene su botón "Actualizar" y su loader, así que a nivel de proceso
    # también son independientes. Este PATCH escribe **solo** los campos de su
    # sección y no puede tocar los datos generales ni los adjuntos ni siquiera si
    # vinieran en el cuerpo.
    #
    # Reemplaza el `PATCH /api/Companies?groupId=N&action=2` del .NET, que mandaba
    # las 42 columnas de las dos tablas del legado en cada guardado.
    #
    # ## El cuerpo es multipart, no JSON
    #
    # Porque la sección incluye el certificado digital. `file` es opcional: sin él
    # se guardan solo las credenciales y el certificado queda como está.
    #
    # ## Los dos secretos
    #
    # `cert_pin` (el PIN del .p12) y `token_password` (la contraseña del ATV) están
    # cifrados en la base con ActiveRecord Encryption (ver `Company`) y **nunca
    # salen en la respuesta**: lo único que se devuelve es `HasCertPin` /
    # `HasTokenPass`, que le alcanza al formulario para distinguir "no hay PIN
    # configurado" de "hay uno y no se muestra".
    #
    # Como el campo se le muestra vacío al usuario, el cliente manda la clave
    # **solo si la tocó**:
    #
    # | Cuerpo                | Efecto                        |
    # |-----------------------|-------------------------------|
    # | sin la clave          | queda como está               |
    # | `CertPin = "1234"`    | se reemplaza                  |
    # | `CertPin = ""`        | se borra (queda `NULL`)       |
    #
    # Sin esa regla, guardar la sección para cambiar el token de usuario borraría
    # el PIN por el solo hecho de que el input se pinta vacío.
    #
    # ## `cert_path` y `cert_expires_at` NO los manda el cliente
    #
    # Los dos salen del archivo:
    #
    # - la ruta la arma `Certificates::Store` con la raíz configurada y la cédula;
    # - el vencimiento sale de abrir el `.p12` con su PIN.
    #
    # Aceptarlos del cuerpo tenía dos problemas concretos. La fecha se podía
    # escribir a mano para posponer la alarma de vencimiento del home. Y la ruta es
    # lo que el **servicio de firma** abre para firmar los XML: el formulario
    # muestra solo el nombre del archivo, así que guardar lo que venía en pantalla
    # dejaba `cert.p12` a secas en una columna que el firmador lee como ruta, y esa
    # compañía dejaba de poder emitir.
    class TaxAuthorityController < AuthorizedController
      # El alcance lo comparte con la lectura (`GET /api/companies/:id`): si no
      # resolvieran el mismo conjunto, el formulario abriría una compañía que este
      # guardado después rechaza (`CLAUDE.md` §28).
      include VisibleCompanies

      # El permiso se resuelve ANTES de buscar el registro: si se hiciera al
      # revés, un 404 le confirmaría a quien no tiene permiso qué ids existen.
      before_action :authorize_action
      before_action :load_company

      # PATCH /api/companies/:company_id/tax_authority
      #
      # Cuerpo multipart: `TokenUsr`, `CertPin`, `TokenPass` y, opcionalmente,
      # `file` con el certificado.
      def update
        previous_path = @company.cert_path

        begin
          certificate = certificate_attributes
        rescue Certificates::Error => e
          return render_error(e.message)
        end

        unless @company.update(tax_authority_params.merge(certificate))
          # La fila no cambió: el archivo que se acaba de escribir no lo apunta
          # nadie, así que no se deja tirado en el disco.
          store.remove(certificate[:cert_path])
          return render_invalid
        end

        # El anterior recién se borra cuando el nuevo ya está en disco y la fila
        # apunta a él. Al revés, un fallo a mitad de camino dejaba a la compañía
        # sin certificado y sin forma de recuperarlo.
        store.remove(previous_path) if certificate[:cert_path] && previous_path != certificate[:cert_path]

        render json: ApiResponse.success(serialize(@company),
                                         message: 'Datos de Hacienda actualizados con éxito.').to_h
      end

      private

      def authorize_action
        require_permission!('Configurations_Companies_Update')
      end

      def load_company
        @company = find_visible_company(params[:company_id])
      end

      def store = @store ||= Certificates::Store.new(@company)

      def certificate_upload = params[:file]

      # Las credenciales del ATV, y nada más. Lo que venga de otras secciones se
      # ignora en silencio: es lo que hace que los botones sean independientes de
      # verdad y no solo en la pantalla.
      #
      # `client_id` y `grant_type` son columnas de esta misma sección pero no
      # están acá a propósito: no tienen campo en el formulario, así que no hay
      # nada que el usuario pueda editar. Un endpoint que acepta lo que la
      # pantalla no ofrece es una puerta sin puerta.
      #
      # Se copia únicamente lo que vino en la petición, para que un PATCH parcial
      # no borre lo que no mencionó — mismo criterio que `general_params`.
      def tax_authority_params
        attrs = {}
        attrs[:token_user]     = text(:TokenUsr) if params.key?(:TokenUsr)
        attrs[:cert_pin]       = text(:CertPin)  if params.key?(:CertPin)
        attrs[:token_password] = text(:TokenPass) if params.key?(:TokenPass)
        attrs
      end

      # Lo que aporta el archivo, o un hash vacío si no vino ninguno.
      #
      # El orden importa: primero se abre el `.p12` y recién después se escribe en
      # disco, para que un PIN equivocado no deje el archivo tirado en el servidor.
      #
      # @raise [Certificates::Error] PIN que no abre el archivo, cédula faltante,
      #   extensión inválida, disco que falla.
      def certificate_attributes
        return {} if certificate_upload.blank?

        expires_at = read_expiration

        { cert_path: store.save!(certificate_upload), cert_expires_at: expires_at }
      end

      # Con qué PIN se abre el certificado. Si el cuerpo trae `CertPin`, ese —el
      # que se está guardando en esta misma petición—; si no, el que ya tenía la
      # compañía. Al revés, cambiar el certificado y su PIN a la vez fallaría
      # siempre, porque probaría el archivo nuevo con la clave vieja.
      def read_expiration
        pin = params.key?(:CertPin) ? params[:CertPin] : @company.cert_pin
        raise Certificates::Error, 'Ingrese el PIN del certificado para poder guardarlo.' if pin.blank?

        result = Certificates::ExpirationReader.new(file: certificate_upload, pin: pin).call
        raise Certificates::Error, result.error unless result.ok?

        result.expires_at
      end

      # Un campo de texto que llega vacío se guarda como `NULL`, no como `''`: son
      # la misma cosa para el negocio y tener las dos representaciones obliga a
      # preguntar por ambas en cada consulta.
      def text(key) = params[key].to_s.strip.presence

      # Se devuelve la sección tal como quedó guardada, no lo que vino en el
      # cuerpo: el servidor deriva la ruta y la fecha, normaliza los vacíos a
      # `NULL`, y el formulario necesita el estado real para volver a marcar la
      # sección como "sin cambios".
      #
      # `CertFileName` y no `CertPath`: el formulario muestra el nombre del
      # archivo, y la ruta absoluta del servidor no le sirve de nada — es
      # infraestructura, y el cliente ya no puede escribirla.
      #
      # ⚠️ Estas cinco claves tienen que ser las mismas que devuelve
      # `Api::CompaniesController#serialize_detail` para esta sección. Si una se
      # agrega en un lado y no en el otro, el formulario muestra un campo que este
      # PATCH ignora: el usuario lo edita, guarda, y no pasa nada — sin error.
      # `spec/requests/api/company_tax_authority_spec.rb` compara las dos listas.
      def serialize(company)
        {
          CertFileName:   Certificates::Store.file_name(company.cert_path),
          CertExpireDate: company.cert_expires_at,
          TokenUsr:       company.token_user,
          HasCertPin:     company.cert_pin_stored?,
          HasTokenPass:   company.token_password_stored?
        }
      end

      def render_invalid
        render_error(@company.errors.full_messages.to_sentence)
      end

      def render_error(message)
        render json: ApiResponse.error(message).to_h, status: :unprocessable_content
      end
    end
  end
end

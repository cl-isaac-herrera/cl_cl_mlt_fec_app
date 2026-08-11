# frozen_string_literal: true

# AuthController — único punto de autenticación de la aplicación (OIDC).
#
# La app NO tiene formulario de login propio: la identidad la confirma el proveedor
# (Auth0/Keycloak) en su propia página y acá solo se recibe el resultado. El token
# resultante vive en la session cookie de Rails (httpOnly), nunca en localStorage
# — regla no negociable de CLAVISCO-PLATFORM-STANDARDS §2.3.
#
# El proveedor solo autentica. Roles y permisos se leen siempre de la base del
# producto, nunca del proveedor.
class AuthController < ApplicationController
  # Rutas públicas por definición: son las que crean la sesión.
  skip_before_action :require_session
  skip_before_action :verify_authenticity_token, only: :callback

  # GET /login, GET /auth/login
  def login
    return render_oidc_not_configured unless oidc_configured?

    state = SecureRandom.hex(16)
    nonce = SecureRandom.hex(16)
    session[:oidc_state] = state
    session[:oidc_nonce] = nonce

    redirect_to oidc_client.authorization_uri(state: state, nonce: nonce), allow_other_host: true
  end

  # GET /auth/callback
  def callback
    return render_oidc_not_configured unless oidc_configured?

    if params[:state].blank? || params[:state] != session.delete(:oidc_state)
      return render plain: 'Estado inválido', status: :bad_request
    end

    # El nonce se consume acá pase lo que pase: uno viejo no puede quedar dando
    # vueltas para un intento posterior. Se compara contra el claim del id_token
    # más abajo — es lo que prueba que esta respuesta corresponde al login que
    # arrancó este browser y no a uno reenviado (§1.5).
    nonce = session.delete(:oidc_nonce)

    # El proveedor puede volver con un error en lugar de un código: el usuario
    # canceló el login o rechazó la pantalla de consentimiento (access_denied).
    # Sin este guard se intentaba el intercambio igual y reventaba con AttrMissing.
    if params[:error].present?
      Rails.logger.info "[Auth] Login no completado: #{params[:error]} — #{params[:error_description]}"
      return render plain: 'No se completó el inicio de sesión.', status: :unauthorized
    end

    if params[:code].blank?
      return render plain: 'Respuesta inválida del proveedor de identidad.', status: :bad_request
    end

    access_token = oidc_client.exchange_code(params[:code])
    claims       = oidc_client.decode_id_token(access_token.id_token)

    unless nonce_valid?(claims, nonce)
      # La respuesta no pertenece a este login. No se detalla el motivo al
      # usuario — el detalle va al log del servidor (§1.5).
      Rails.logger.warn '[Auth] id_token rechazado: el nonce no corresponde a este login'
      return render plain: 'No se pudo validar el inicio de sesión.', status: :unauthorized
    end

    user = resolve_user(claims)
    unless user
      # El proveedor autenticó a alguien que no está dado de alta en este producto.
      # No se auto-provisiona: los roles/permisos por compañía los asigna un admin.
      Rails.logger.warn "[Auth] Autenticación correcta pero sin cuenta local para #{claims['email'].inspect}"
      return render plain: 'No existe una cuenta para este correo.', status: :unauthorized
    end

    session[:user_id] = user.id
    # Token de acceso en la cookie httpOnly. El ProxyController lo adjunta al llamar
    # al backend; el browser nunca lo ve. Ver §2.3 (session[:legacy_token] es el
    # nombre que usa el estándar para el token del backend heredado).
    session[:access_token] = access_token.access_token.to_s.presence
    session[:user_email]   = user.email
    # El id_token NO va en la cookie: junto al access_token de Keycloak supera los
    # 4 KB del cookie store y Rails corta con CookieOverflow. Se guarda del lado
    # del servidor y en la cookie queda solo una llave corta.
    session[:id_token_key] = store_id_token(access_token.id_token)

    redirect_to root_path
  end

  # GET /auth/logout
  def logout
    return_to = root_url
    # Se consume ANTES de reset_session: después la sesión ya no tiene la llave y
    # el hint se perdería, que es justo lo que deja viva la sesión SSO del proveedor.
    id_token_hint = take_id_token

    logout_url = oidc_configured? ? provider_logout_url(return_to, id_token_hint) : return_to

    # reset_session invalida la sesión completa en vez de borrar llaves una por una
    # (§1.5) — evita dejar residuos de una sesión anterior.
    reset_session

    redirect_to logout_url, allow_other_host: true
  end

  # El id_token solo se necesita para cerrar sesión en el proveedor. Vive en el
  # cache del servidor (dev: memoria; producción: Solid Cache sobre la BD) por si
  # el usuario nunca cierra sesión.
  ID_TOKEN_TTL = 12.hours

  private

  # El id_token tiene que traer el mismo nonce que se mandó al iniciar el login:
  # es lo que prueba que la respuesta corresponde a este browser y no es un replay
  # (§1.5). El submódulo no lo valida, así que se valida acá.
  def nonce_valid?(claims, expected)
    received = claims['nonce'].to_s
    return false if expected.blank? || received.blank?

    ActiveSupport::SecurityUtils.secure_compare(received, expected.to_s)
  end

  def store_id_token(id_token)
    token = id_token.to_s
    return nil if token.empty?

    key = SecureRandom.hex(16)
    Rails.cache.write(id_token_cache_key(key), token, expires_in: ID_TOKEN_TTL)
    key
  end

  # Lo devuelve y lo borra: un id_token ya usado para cerrar sesión no sirve más.
  def take_id_token
    key = session[:id_token_key]
    return nil if key.blank?

    cache_key = id_token_cache_key(key)
    Rails.cache.read(cache_key).tap { Rails.cache.delete(cache_key) }
  end

  def id_token_cache_key(key) = "oidc:id_token:#{key}"

  # Sin `id_token_hint` Keycloak (18+) NO cierra la sesión: muestra una pantalla de
  # confirmación y, si el usuario no la confirma, el SSO sigue vivo y el próximo
  # login entra sin pedir credenciales. El `logout_url` del submódulo no acepta el
  # hint, así que se agrega acá — el submódulo no se toca (CLAUDE.md §27).
  # Ver TODOS.md → Submódulos: el arreglo definitivo va en cl-auth-ruby.
  def provider_logout_url(return_to, id_token_hint)
    url = oidc_client(redirect_uri: nil).logout_url(return_to: return_to)
    return url if id_token_hint.blank? || Rails.application.config.oidc.provider != 'keycloak'

    "#{url}&#{URI.encode_www_form(id_token_hint: id_token_hint)}"
  end

  # Resolución del usuario: primero por `oidc_sub` (el claim `sub`, identificador
  # estable del proveedor y por donde busca Clavisco::Auth::Authenticatable); si no
  # existe, por correo, y se le graba el `sub` en ese primer login.
  #
  # El correo funciona solo como ENLACE inicial: hoy un admin da de alta al usuario
  # sin manera de conocer su `sub` de antemano, así que sin este paso la columna
  # nunca se llenaría y nadie podría entrar.
  #
  # Es TRANSITORIO y está acordado con el autor del estándar (no figura en el
  # documento). Cuando el alta de usuarios se haga desde la aplicación, el usuario se
  # creará en el proveedor OIDC y se guardará el `oidc_sub` desde el inicio: ahí este
  # fallback por correo se elimina y queda solo la búsqueda por `sub`.
  def resolve_user(claims)
    sub = claims['sub'].presence
    user = sub && User.find_by(oidc_sub: sub)
    return user if user

    user = User.find_by(email: claims['email'])
    user&.update!(oidc_sub: sub) if sub && user&.oidc_sub.blank?
    user
  end

  def oidc_configured?
    Rails.application.config.oidc.present?
  end

  # Sin config OIDC el cliente reventaría con NoMethodError sobre nil. Se responde
  # explícito, igual que las otras ramas de error de este controller.
  def render_oidc_not_configured
    Rails.logger.error '[Auth] OIDC sin configurar: falta OIDC_DOMAIN/OIDC_CLIENT_ID/OIDC_CLIENT_SECRET.'
    render plain: 'Autenticación no configurada.', status: :service_unavailable
  end

  def oidc_client(redirect_uri: auth_callback_url)
    Clavisco::Auth::OidcClient.new(Rails.application.config.oidc, redirect_uri: redirect_uri)
  end
end

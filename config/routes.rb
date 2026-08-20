# frozen_string_literal: true

Rails.application.routes.draw do
  # API nativa de Rails. Va ANTES del catch-all del proxy: cada endpoint migrado
  # gana sobre él y deja de reenviarse al .NET. Cuando no quede ninguno, se borran
  # el catch-all y ProxyController.
  #
  # Nombrado REST: el verbo va en el método HTTP, no en el path — `GET /api/companies`
  # en vez de `GET /api/Companies/GetCompanies`.
  namespace :api do
    # `index` es el listado de administración (/configurations/companies): las
    # compañías de la instalación, paginadas, con filtro por nombre y con las
    # dadas de baja incluidas. Reemplaza GET /api/Companies/GetCompanies.
    # `assignable` es la lista dual del tab de asignación de usuarios y reemplaza
    # GET /api/Companies/for-assignment?groupId=N — sin groupId, no hay grupos (§31).
    #
    # Las compañías DEL USUARIO de la sesión no están acá: son
    # GET /api/profile/companies.
    # `show` alimenta el formulario de edición y devuelve dos bloques: las
    # columnas de `companies` y los UDFs de `OADM` leídos desde SAP.
    resources :companies, only: %i[index show] do
      get :assignable, on: :collection

      # UN endpoint por sección del formulario. Cada botón "Actualizar" es
      # independiente en la pantalla y también en el proceso: escribe solo los
      # campos de su sección y no puede pisar los de otra. El reparto de campos
      # vive en `CompanySections`.
      #
      # `resource` singular y sin id: la sección pertenece a la compañía del
      # path, no es una colección (§28). Las otras cuatro secciones se agregan
      # acá cuando se migren (`TODOS.md` → Compañías).
      # `controller:` explícito porque `resource` singular busca el controller en
      # PLURAL (`resource :profile` → `ProfilesController`), y estos nombres de
      # sección son adjetivos: "generals" o "additionals" no significan nada.
      resource :general, only: [:update], module: :companies, controller: 'general'

      # Sección "Datos de Conexión de Hacienda (ATV)". `tax_authority` a secas y
      # no `tax_authority_credentials`: la sección guarda además el certificado
      # y su vencimiento, no solo las credenciales del ATV.
      #
      # El cuerpo es multipart, no JSON: la sección incluye la carga del `.p12`.
      resource :tax_authority, only: [:update], module: :companies,
                               controller: 'tax_authority'

      # Descarga del `.p12` de la compañía. Se puede servir desde acá porque el
      # archivo ya lo guarda esta aplicación; antes vivía en el disco del .NET.
      resource :certificate, only: [:show], module: :companies,
                             controller: 'certificate'
    end

    # `index` son los permisos EFECTIVOS del usuario de la sesión; `catalog` es
    # el catálogo completo que pinta la pantalla de seguridad. Ver la nota del
    # controller: los nombres deberían ser al revés (`TODOS.md` → Seguridad).
    resources :permissions, only: [:index] do
      get :catalog, on: :collection
    end

    # Roles y sus permisos. Reemplazan `GET|POST|PATCH /api/Rol`,
    # `GET /api/Permission/GetPermissionsByRol` y `POST /api/Permission/AssignPermByRol`.
    # El conjunto de permisos de un rol es uno solo: `resource` singular, sin id,
    # y se reemplaza entero con PUT.
    resources :roles, only: %i[index create update] do
      resource :permissions, only: %i[show update], module: :roles
    end

    # Usuarios (tab "Lista de usuarios"). Reemplaza GET /api/User/accessible,
    # GET /api/User/information, POST /api/User y PATCH /api/User.
    # `companies` es la subcolección que alimenta el selector de la prueba de
    # credenciales; `role` es singular porque un usuario tiene UN rol por
    # compañía, y la compañía la pone la sesión, no el path.
    resources :users, only: %i[index show create update] do
      # Los tres son conjuntos que pertenecen al usuario y se reemplazan enteros:
      # `resource` singular (sin id propio) + PUT. Ver CLAUDE.md §28.
      resource :companies,   only: %i[show update], module: :users
      resource :role,        only: %i[show update], module: :users
      resource :permissions, only: %i[show update], module: :users
    end

    # Perfil del usuario de la sesión. Singular: no lleva id porque siempre es el
    # propio. Reemplaza GET /api/User/GetUserInfo y PATCH /api/User/profile-info.
    #
    # `companies` cuelga de acá y no de `/api/companies` porque el conjunto lo
    # define la sesión, no un filtro: son las compañías asignadas al usuario, las
    # que alimentan el selector del toolbar.
    resource :profile, only: %i[show update] do
      resources :companies, only: [:index], module: :profile
    end

    # Alarma de vencimiento del certificado digital, para el toast del home.
    # Reemplaza GET /api/Companies/GetCertExpireDateAlarm?companyId=N.
    #
    # Singular y sin id: la alarma es una sola y es la de la compañía activa, que
    # sale de la sesión y no de un parámetro (§28, reglas 3 y 5). No cuelga de
    # `/api/companies/:id` justamente por eso — con el id en el path, cualquiera
    # podría preguntar por el certificado de una compañía ajena.
    resource :certificate_alarm, only: [:show]

    # Prueba de credenciales de SAP contra el Service Layer de una compañía.
    # Reemplaza POST /api/Connections/validate-user-credentials.
    resources :sap_credential_validations, only: [:create]

    # Lectura del vencimiento de un certificado `.p12` recién elegido, antes de
    # guardarlo. Reemplaza POST /api/Companies/CheckCertExpireDate?CertPin=N —
    # el PIN pasa de la query string al cuerpo. No cuelga de
    # `/api/companies/:id`: el certificado todavía no es de ninguna compañía, y
    # el alta lo usa igual.
    resources :certificate_inspections, only: [:create]

    # Conexiones a servidores SAP. Reemplaza GET/POST/PATCH /api/Connections del
    # .NET; el id de update pasa del cuerpo al path. `assignable` es la
    # subcolección que alimenta el selector del formulario de compañías, y
    # reemplaza GET /api/Connections/for-assignment.
    resources :connections, only: %i[index show create update] do
      get :assignable, on: :collection
    end

    # Consultas al Service Layer (pantalla de mantenimiento). Sin `create` ni
    # `destroy`: el catálogo lo define `db/seeds.rb`, la pantalla solo ajusta el
    # recurso y la query de las consultas que la app ya sabe consumir.
    resources :sl_resources, only: %i[index show update]

    put 'session/company', to: 'sessions#update_company'
  end

  # Todo lo que no migró todavía sigue reenviándose al backend .NET.
  match '/api/*path', to: 'proxy#forward', via: :all

  # Autenticación: la app no tiene formulario propio — /login redirige al proveedor
  # OIDC (ver AuthController). `login_path` es además el destino de require_session.
  get  '/login',   to: 'auth#login', as: :login
  get  '/sign-in', to: redirect('/login')
  get  '/home',      to: 'home#index',      as: :home
  get  '/not-found', to: 'not_found#index', as: :not_found

  get 'auth/login',    to: 'auth#login',    as: :auth_login
  get 'auth/callback', to: 'auth#callback', as: :auth_callback
  get 'auth/logout',   to: 'auth#logout',   as: :auth_logout

  # Verificación de cuenta por OTP (página pública, sin menú).
  # Migrado de Angular: ruta /account-verification/:OTPCode → VerificationEmailComponent.
  get 'account-verification/:otp_code', to: 'account_verifications#show',
      as: :account_verification, constraints: { otp_code: %r{[^/]+} }

  namespace :configurations do
    get 'user-profile',        to: 'user_profile#index', as: :user_profile
    get 'security',            to: 'roles#index',        as: :security
    get 'general',             to: 'general#index',      as: :general
    get 'numbering',           to: 'numbering#index',    as: :numbering
    get 'branches',            to: 'branches#index',     as: :branches
    get 'udfs',                to: 'udfs#index',         as: :udfs

    # Companies
    get 'companies',          to: 'companies#index', as: :companies
    get 'companies/new',      to: 'companies#new',   as: :new_company
    get 'companies/:id/edit', to: 'companies#edit',  as: :edit_company

    # Group
    get 'group', to: 'group#index', as: :group

    # Recursos de Service Layer — mantenimiento de las consultas a SAP.
    get 'sl-resources', to: 'sl_resources#index', as: :sl_resources

    # Connections
    get 'connections',          to: 'connections#index', as: :connections
    get 'connections/new',      to: 'connections#new',   as: :new_connection
    get 'connections/:id/edit', to: 'connections#edit',  as: :edit_connection

    # Mail Parser (procesadores de correo entrante)
    get 'mail-parser', to: 'mail_parser#index', as: :mail_parser

    # Email Senders (bandejas de envío + asignación a compañías)
    # Reemplaza la ruta Angular /emailInbox
    get 'email-senders', to: 'email_senders#index', as: :email_senders

    # Users — Gestión de usuarios. Pantalla única: el alta, la edición y los
    # accesos son paneles laterales del listado. `users/register` y `users/edit`
    # se eliminaron.
    get 'users', to: 'users#index', as: :users
  end

  namespace :documents do
    get 'issued',                 to: 'issued#index',      as: :issued
    get 'receptions',             to: 'receptions#index',  as: :receptions
    get 'receptions/logs',        to: 'receptions_logs#index', as: :receptions_logs
    get 'receptions/:id/create',  to: 'receptions#create', as: :create_reception

    # Creacion de documentos electronicos (FE 01, ND 02, NC 03, FEC 08, REP 10)
    # Reemplaza la ruta Angular /createDocument/:docType
    get ':type/create', to: 'create#index', as: :create_document,
        constraints: { type: /01|02|03|08|10/ }

    # Reporte de correos enviados
    get 'emails', to: 'emails#index', as: :emails
  end

  get 'documents-reports',   to: 'documents/reports#index',              as: :documents_reports

  # Rutas exclusivas para especificar el comportamiento de Api::BaseController y
  # Api::AuthorizedController (ver spec/requests/api/). No existen fuera de test.
  if Rails.env.test?
    get '__test/authorized/checked',   to: 'authorized_controller_test#checked'
    get '__test/authorized/unchecked', to: 'authorized_controller_test#unchecked'
    get '__test/base/whoami',          to: 'base_controller_test#whoami'
    post '__test/session',             to: 'test_session#create'
  end

  # Sin sesión, require_session redirige a /login → proveedor OIDC.
  root to: 'home#index'
end

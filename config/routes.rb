# frozen_string_literal: true

Rails.application.routes.draw do
  # API nativa de Rails. Va ANTES del catch-all del proxy: cada endpoint migrado
  # gana sobre él y deja de reenviarse al .NET. Cuando no quede ninguno, se borran
  # el catch-all y ProxyController.
  #
  # Nombrado REST: el verbo va en el método HTTP, no en el path — `GET /api/companies`
  # en vez de `GET /api/Companies/GetCompanies`.
  namespace :api do
    resources :companies,   only: [:index]
    resources :permissions, only: [:index]

    # Perfil del usuario de la sesión. Singular: no lleva id porque siempre es el
    # propio. Reemplaza GET /api/User/GetUserInfo y PATCH /api/User/profile-info.
    resource :profile, only: %i[show update]

    # Prueba de credenciales de SAP contra el Service Layer de una compañía.
    # Reemplaza POST /api/Connections/validate-user-credentials.
    resources :sap_credential_validations, only: [:create]

    # Conexiones a servidores SAP. Reemplaza GET/POST/PATCH /api/Connections del
    # .NET; el id de update pasa del cuerpo al path. `assignable` es la
    # subcolección que alimenta el selector del formulario de compañías, y
    # reemplaza GET /api/Connections/for-assignment.
    resources :connections, only: %i[index show create update] do
      get :assignable, on: :collection
    end

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

    # Connections
    get 'connections',          to: 'connections#index', as: :connections
    get 'connections/new',      to: 'connections#new',   as: :new_connection
    get 'connections/:id/edit', to: 'connections#edit',  as: :edit_connection

    # Mail Parser (procesadores de correo entrante)
    get 'mail-parser', to: 'mail_parser#index', as: :mail_parser

    # Email Senders (bandejas de envío + asignación a compañías)
    # Reemplaza la ruta Angular /emailInbox
    get 'email-senders', to: 'email_senders#index', as: :email_senders

    # Users — Gestión de usuarios (Lista, Completar Registro, Asignación)
    get 'users',          to: 'users#index',    as: :users
    get 'users/register', to: 'users#register', as: :users_register
    get 'users/edit',     to: 'users#edit',     as: :users_edit
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

// Registro de Stimulus controllers
// Convencion: archivo home_controller.js -> data-controller="home"

import { application } from 'controllers/application'

import AuthGuardController       from 'controllers/auth_guard_controller'
import HomeController            from 'controllers/home_controller'
import MenuController            from 'controllers/menu_controller'
import CompanySelectorController from 'controllers/company_selector_controller'
import UserProfileController     from 'controllers/user_profile_controller'
import RolesController          from 'controllers/roles_controller'
import GeneralConfigsController  from 'controllers/general_configs_controller'
import CompaniesController        from 'controllers/companies_controller'
import CompanyFormController      from 'controllers/company_form_controller'
import ConnectionsController      from 'controllers/connections_controller'
import ConnectionFormController   from 'controllers/connection_form_controller'
import NumberingController        from 'controllers/numbering_controller'
import GroupController            from 'controllers/group_controller'
import BranchesController         from 'controllers/branches_controller'
import DocumentsIssuedController   from 'controllers/documents_issued_controller'
import DocumentsReportsController    from 'controllers/documents_reports_controller'
import DocumentsReceptionController  from 'controllers/documents_reception_controller'
import DocumentsReceptionsController      from 'controllers/documents_receptions_controller'
import DocumentsReceptionCreateController from 'controllers/documents_reception_create_controller'
import DocumentsCreateController          from 'controllers/documents_create_controller'
import MailParserController               from 'controllers/mail_parser_controller'
import ReceptionLogsController           from 'controllers/reception_logs_controller'
import EmailSendersController             from 'controllers/email_senders_controller'
import DocumentsEmailsController          from 'controllers/documents_emails_controller'
import SessionSyncController             from 'controllers/session_sync_controller'
import UsersController                  from 'controllers/users_controller'
import UsersRegisterController          from 'controllers/users_register_controller'
import UsersEditController              from 'controllers/users_edit_controller'
import UdfsController                  from 'controllers/udfs_controller'
import AccountVerificationController   from 'controllers/account_verification_controller'
import UserMenuController              from 'controllers/user_menu_controller'

application.register('account-verification', AccountVerificationController)
application.register('auth-guard',        AuthGuardController)
application.register('home',              HomeController)
application.register('menu',              MenuController)
application.register('company-selector',  CompanySelectorController)
application.register('user-profile',      UserProfileController)
application.register('roles',             RolesController)
application.register('general-configs',   GeneralConfigsController)
application.register('companies',         CompaniesController)
application.register('company-form',      CompanyFormController)
application.register('connections',       ConnectionsController)
application.register('connection-form',   ConnectionFormController)
application.register('numbering',         NumberingController)
application.register('group',             GroupController)
application.register('branches',          BranchesController)
application.register('documents-issued',  DocumentsIssuedController)
application.register('documents-reports',    DocumentsReportsController)
application.register('documents-reception',  DocumentsReceptionController)
application.register('documents-receptions',       DocumentsReceptionsController)
application.register('documents-reception-create', DocumentsReceptionCreateController)
application.register('documents-create',           DocumentsCreateController)
application.register('mail-parser',     MailParserController)
application.register('reception-logs',  ReceptionLogsController)
application.register('email-senders',   EmailSendersController)
application.register('documents-emails',  DocumentsEmailsController)
application.register('session-sync',    SessionSyncController)
application.register('users',           UsersController)
application.register('users-register',  UsersRegisterController)
application.register('users-edit',      UsersEditController)
application.register('udfs',            UdfsController)
application.register('user-menu',       UserMenuController)

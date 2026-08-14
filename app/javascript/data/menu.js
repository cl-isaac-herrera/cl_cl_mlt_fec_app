export default [
  {
    key: 'home',
    label: 'Inicio',
    icon: 'house',
    route: '/home',
    visible: true,
    nodes: []
  },
  {
    key: 'documents',
    label: 'Documentos',
    icon: 'folder_open',
    route: null,
    visible: false,
    requiredPermission: 'M_Documents',
    nodes: [
      { key: 'issued_documents',    label: 'Emitidos',                    route: '/documents/issued',           requiredPermission: 'Documents_Issued_ViewDocuments' },
      { key: 'accept_documents',    label: 'Recepcionados',               route: '/documents/receptions',       requiredPermission: 'Documents_Reception_ViewDocuments' },
      { key: 'accept_documents_gt', label: 'Aceptación documentos GT',    route: '/documents/gt/receptions',    requiredPermission: 'S_AcceptDocsGT' },
      { key: 'mailParser',          label: 'Logs de recepciones',         route: '/documents/receptions/logs', requiredPermission: 'S_MailParserLogs' },
      { key: 'email_report',        label: 'Historial de correos',        route: '/documents/emails',           requiredPermission: 'S_EmailReport' },
      { key: 'createFE',            label: 'Emitir Factura Electrónica',  route: '/documents/01/create',        requiredPermission: 'S_CreateDocsFE' },
      { key: 'createND',            label: 'Emitir Nota de Débito',       route: '/documents/02/create',        requiredPermission: 'S_CreateDocsND' },
      { key: 'createNC',            label: 'Emitir Nota de Crédito',      route: '/documents/03/create',        requiredPermission: 'S_CreateDocsNC' },
      { key: 'createFEC',           label: 'Emitir Factura de Compra',    route: '/documents/08/create',        requiredPermission: 'S_CreateDocsFEC' },
      { key: 'createREP',           label: 'Emitir Recibo de Pago',       route: '/documents/10/create',        requiredPermission: 'S_CreateDocsREP' }
    ]
  },
  {
    key: 'reports',
    label: 'Reportes',
    icon: 'print',
    route: '/documents-reports',
    visible: false,
    requiredPermission: ['S_DocumentReport'],
    nodes: []
  },
  {
    key: 'settings',
    label: 'Configuración',
    icon: 'settings_suggest',
    route: null,
    visible: false,
    requiredPermission: 'M_Config',
    nodes: [
      { key: 'user-profile',     label: 'Perfil de usuario',              route: '/configurations/user-profile' },
      { key: 'company',          label: 'Compañías',                      route: '/configurations/companies',      requiredPermission: 'S_Company' },
      { key: 'connections',      label: 'Conexiones',                     route: '/configurations/connections',    requiredPermission: 'Configurations_Connections_Access' },
      { key: 'slResources',      label: 'Recursos Service Layer',         route: '/configurations/sl-resources',   requiredPermission: 'Configurations_SlResources_Access' },
      { key: 'udfs',             label: 'Campos definidos por usuario',   route: '/configurations/udfs',           requiredPermission: 'S_Udfs', requiredCompanyFlag: 'UseFactProv' },
      { key: 'users',            label: 'Usuarios',                       route: '/configurations/users',          requiredPermission: 'Configurations_Users_Access' },
      { key: 'groups',           label: 'Grupos',                         route: '/configurations/group',          requiredPermission: 'S_Groups' },
      { key: 'numbering',        label: 'Numeración',                     route: '/configurations/numbering',      requiredPermission: 'S_Numbering' },
      { key: 'Rol',              label: 'Seguridad',                      route: '/configurations/security',       requiredPermission: 'Configurations_Security_Access' },
      { key: 'sucursal',         label: 'Sucursal',                       route: '/configurations/branches',       requiredPermission: 'S_Sucursal' },
      { key: 'wizardSetup',      label: 'Asistente de configuración',     route: '/wizard-setup',                  requiredPermission: 'Configurations_WizardSetup_Access' },
      { key: 'mailParserConfig', label: 'Bandejas de recepción',          route: '/configurations/mail-parser',    requiredPermission: ['Configurations_MailParser_ViewConfigurations', 'Configurations_MailParser_ViewAllConfigurationsInApplication'] },
      { key: 'emailInbox',       label: 'Bandejas de emisión',            route: '/configurations/email-senders',  requiredPermission: 'Configurations_EmailInbox_Access' },
      { key: 'userHelp',         label: 'Enlaces de documentación',       route: '/user-help',                     requiredPermission: 'Configurations_UserHelp_Access' },
      { key: 'generalConfigs',   label: 'Generales',                      route: '/configurations/general',        requiredPermission: 'Configurations_General_Access' }
    ]
  },
  {
    key: 'textFilesLogs',
    label: 'Logs',
    icon: 'terminal',
    route: '/logs',
    visible: false,
    requiredPermission: 'Logs_Access',
    nodes: []
  },
  {
    key: 'logout',
    label: 'Cerrar sesión',
    icon: 'logout',
    route: '/login',
    visible: true,
    nodes: []
  }
]

# frozen_string_literal: true

# Mueve `companies.client_id` y `companies.grant_type` a `settings` y elimina
# las columnas.
#
# ── Por qué ──────────────────────────────────────────────────────────────────
# Las dos columnas nunca tuvieron campo en el formulario (`Api::Companies::
# TaxAuthorityController#tax_authority_params`, `TODOS.md` → Compañías): nada
# en la UI las escribe, así que quedaban congeladas en lo que trajera la
# importación. El comentario del legacy explica por qué —
# `CLVS_FE.Models/Configuracion/Company.cs:50`, citado en
# `20260817220000_create_environments.rb`—: `client_id` vale `"api-stag"` en
# pruebas y `"api-prod"` en producción, y `grant_type` es siempre `"password"`.
# Son datos del AMBIENTE de Hacienda contra el que emite la instalación, no de
# cada compañía — la misma razón por la que ya se migraron las tres URIs y el
# número de resolución en
# `20260905120000_move_environment_config_to_settings.rb`. Con una instalación
# por cliente (`CLAUDE.md` §31), "el ambiente" es configuración de la
# instalación: exactamente lo que resuelve `settings` (§36). Se agregan al
# mismo grupo `HACIENDA_FE`.
#
# Confirmado con grep sobre `app/` y `config/`: ningún controller, serializer
# ni vista lee estas columnas — el único rastro era el test de aislamiento de
# `company_tax_authority_spec.rb`, que se actualiza en el mismo cambio.
class MoveHaciendaClientCredentialsToSettings < ActiveRecord::Migration[8.1]
  GROUP = 'HACIENDA_FE'

  # `grant_type` no es una elección del operador: Hacienda solo acepta la
  # variante `"password"` del OAuth Resource Owner Password Credentials Grant,
  # así que nace con ese valor (`fixed_value`, igual que `db/seeds.rb`).
  # `client_id` SÍ varía por instalación (`"api-stag"` en pruebas, `"api-prod"`
  # en producción) y nace en blanco — lo escribe el operador.
  #
  # code                       description                                                        is_visible  fixed_value
  SETTINGS = [
    ['HACIENDA_FE_CLIENT_ID',  'Client ID de Hacienda para el token OAuth (api-stag / api-prod)', true],
    ['HACIENDA_FE_GRANT_TYPE', 'Grant type de Hacienda para el token OAuth (password)',           true, 'password']
  ].freeze

  # Modelo mínimo y propio, y no `Company`/`Setting` de la app: los dos cambian
  # con el tiempo (este mismo cambio le quita las columnas al primero) y el
  # `default_scope` de baja lógica escondería justo las filas que hay que leer.
  class MigrationCompany < ActiveRecord::Base
    self.table_name = 'companies'
  end

  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'settings'
    encrypts :value
  end

  def up
    MigrationSetting.reset_column_information
    create_settings
    migrate_existing_values

    remove_column :companies, :client_id
    remove_column :companies, :grant_type
  end

  # Irreversible a propósito, igual que `20260905120000`: revertirla recrearía
  # las columnas vacías en todas las compañías salvo la primera de la que se
  # tomó el valor, sin forma de saber cuál lo tenía originalmente.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Upsert por `code`, igual que `db/seeds.rb`: si esta migración corre dos
  # veces, no duplica la fila. `fixed_value` deja a `HACIENDA_FE_GRANT_TYPE`
  # creado con `"password"`; `HACIENDA_FE_CLIENT_ID` no lo lleva y nace vacío.
  def create_settings
    SETTINGS.each do |code, description, is_visible, fixed_value|
      record = MigrationSetting.unscoped.find_or_initialize_by(code: code)
      record.group_code  = GROUP
      record.description = description
      record.is_visible  = is_visible
      record.is_active   = true
      record.value       = fixed_value if fixed_value
      record.save!
    end
  end

  # Defensivo: sin consumidor ni formulario, pero una compañía importada del
  # .NET puede traer el valor. Se toma la primera que tenga algo escrito —
  # nunca hubo más de un ambiente por instalación real, así que cualquier
  # valor presente es el mismo para todas. Para `grant_type` solo importa si
  # trajo algo DISTINTO de `"password"`, el `fixed_value` que ya dejó
  # `create_settings`; en la práctica el legacy nunca guardó otra cosa.
  def migrate_existing_values
    write_setting('HACIENDA_FE_CLIENT_ID', first_present(:client_id))
    write_setting('HACIENDA_FE_GRANT_TYPE', first_present(:grant_type))
  end

  def first_present(column)
    MigrationCompany.where.not(column => [nil, '']).order(:id).first&.public_send(column)
  end

  def write_setting(code, value)
    return if value.blank?

    MigrationSetting.find_by!(code: code).update!(value: value)
  end
end

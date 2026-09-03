require 'rails_helper'

RSpec.describe ExternalDb::Config do
  # Un driver que existe de verdad en el servidor: `#validate_driver!` compara
  # contra los registrados, y usar uno inventado haría fallar todos los ejemplos
  # por el motivo equivocado.
  let(:sql_driver)  { 'ODBC Driver 17 for SQL Server' }
  let(:hana_driver) { 'HDBODBC' }

  let(:sql_values) do
    { 'ENGINE' => 'SQL', 'DRIVER' => sql_driver, 'SERVER' => 'CLSQL01',
      'DATABASE' => 'CL_DOCS', 'USER' => 'fec_ro', 'PASSWORD' => 'secret' }
  end

  let(:hana_values) do
    { 'ENGINE' => 'HANA', 'DRIVER' => hana_driver, 'SERVER' => 'clhna721',
      'PORT' => '30015', 'DATABASE' => 'CL_DOCS', 'USER' => 'FEC_RO', 'PASSWORD' => 'secret' }
  end

  def build_config(values)
    described_class.new(group_code: 'DOCS_DB_ODBC', values: values)
  end

  describe '.load' do
    it 'arma el destino desde los settings del grupo' do
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_ENGINE',   value: 'SQL')
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_DRIVER',   value: sql_driver)
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_SERVER',   value: 'CLSQL01')
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_USER',     value: 'fec_ro')
      create(:setting, group_code: 'DOCS_DB_ODBC', code: 'DOCS_DB_ODBC_PASSWORD', value: 'secret')

      config = described_class.load('DOCS_DB_ODBC')

      expect(config).to have_attributes(engine: 'SQL', server: 'CLSQL01', user: 'fec_ro')
    end
  end

  describe 'ajustes faltantes' do
    # Un solo mensaje con todos: el operador que abre la pantalla por primera vez
    # tiene diez campos que llenar y enterarse de a uno por intento es inútil.
    it 'los nombra todos juntos, con el code completo' do
      expect { build_config('ENGINE' => 'SQL', 'DRIVER' => sql_driver) }
        .to raise_error(ExternalDb::ConfigurationError,
                        /DOCS_DB_ODBC_SERVER, DOCS_DB_ODBC_USER, DOCS_DB_ODBC_PASSWORD/)
    end

    it 'apunta a la pantalla donde se corrigen' do
      expect { build_config({}) }
        .to raise_error(ExternalDb::ConfigurationError, /Configuraciones → Generales/)
    end
  end

  describe 'autenticación integrada de Windows' do
    let(:trusted_values) { sql_values.except('USER', 'PASSWORD').merge('TRUSTED' => 'true') }

    it 'no exige usuario ni contraseña: no hay credenciales que escribir' do
      expect(build_config(trusted_values)).to be_trusted
    end

    it 'los sigue exigiendo cuando está apagada' do
      expect { build_config(sql_values.except('USER', 'PASSWORD')) }
        .to raise_error(ExternalDb::ConfigurationError,
                        /DOCS_DB_ODBC_USER, DOCS_DB_ODBC_PASSWORD/)
    end

    # Lista explícita de valores verdaderos, y no `ActiveModel::Type::Boolean`,
    # que trata como verdadero todo lo que no esté en su lista de falsos: un
    # "no" escrito a mano activaría la autenticación integrada sin que nadie lo
    # note.
    it 'no interpreta como "sí" cualquier texto' do
      expect { build_config(sql_values.except('USER', 'PASSWORD').merge('TRUSTED' => 'no')) }
        .to raise_error(ExternalDb::ConfigurationError, /DOCS_DB_ODBC_USER/)
    end

    %w[true 1 yes sí on].each do |value|
      it "acepta #{value.inspect} como sí" do
        expect(build_config(trusted_values.merge('TRUSTED' => value))).to be_trusted
      end
    end

    # El driver de HANA no tiene `Trusted_Connection`. Activarla ahí conectaría
    # sin usuario y fallaría con un error del driver que no menciona el ajuste.
    it 'la rechaza en HANA, nombrando el ajuste' do
      expect { build_config(hana_values.merge('TRUSTED' => 'true')) }
        .to raise_error(ExternalDb::ConfigurationError, /DOCS_DB_ODBC_TRUSTED.*SAP HANA/m)
    end

    # Cambiar de credenciales a integrada cambia con qué identidad se conecta:
    # el pool tiene que descartar las conexiones abiertas.
    it 'cambia el fingerprint, para que el pool no reutilice la conexión anterior' do
      expect(build_config(trusted_values).fingerprint)
        .not_to eq(build_config(sql_values).fingerprint)
    end
  end

  describe 'el puerto según el motor' do
    # `SERVERNODE` exige `host:puerto` y no hay valor implícito. El puerto de
    # instancia es 3<NN>15 — 30015 para la instancia 00.
    it 'es obligatorio en HANA' do
      expect { build_config(hana_values.except('PORT')) }
        .to raise_error(ExternalDb::ConfigurationError, /DOCS_DB_ODBC_PORT/)
    end

    # El driver de SQL Server asume 1433.
    it 'es opcional en SQL Server' do
      expect(build_config(sql_values.except('PORT')).port).to be_nil
    end

    it 'rechaza uno fuera de rango' do
      expect { build_config(sql_values.merge('PORT' => '99999')) }
        .to raise_error(ExternalDb::ConfigurationError, /no es válido/)
    end

    it 'rechaza uno que no es numérico' do
      expect { build_config(sql_values.merge('PORT' => '30015a')) }
        .to raise_error(ExternalDb::ConfigurationError, /no es válido/)
    end
  end

  describe 'el motor' do
    it 'rechaza uno desconocido' do
      expect { build_config(sql_values.merge('ENGINE' => 'ORACLE')) }
        .to raise_error(ExternalDb::ConfigurationError, /no es válido/)
    end

    it 'tolera minúsculas' do
      expect(build_config(sql_values.merge('ENGINE' => 'sql')).engine).to eq('SQL')
    end
  end

  describe 'el driver' do
    # Es el error más difícil de diagnosticar solo: un nombre mal escrito produce
    # "Data source name not found", que no dice cuál es el correcto.
    it 'rechaza uno que no está instalado y lista los que sí' do
      expect { build_config(sql_values.merge('DRIVER' => 'Driver Inventado')) }
        .to raise_error(ExternalDb::ConfigurationError, /no está instalado.*Instalados:/m)
    end

    it 'no distingue mayúsculas' do
      expect { build_config(sql_values.merge('DRIVER' => sql_driver.upcase)) }.not_to raise_error
    end
  end

  describe '#fingerprint' do
    # Es lo que hace que el pool descarte las conexiones cuando el operador
    # cambia la configuración desde la pantalla.
    it 'cambia con cualquier ajuste, incluida la contraseña' do
      base = build_config(sql_values).fingerprint

      expect(build_config(sql_values.merge('PASSWORD' => 'otra')).fingerprint).not_to eq(base)
      expect(build_config(sql_values.merge('SERVER'   => 'CLSQL02')).fingerprint).not_to eq(base)
    end

    it 'es estable para la misma configuración' do
      expect(build_config(sql_values).fingerprint).to eq(build_config(sql_values).fingerprint)
    end

    # Termina en llaves de hash y en el log: no tiene por qué llevar el secreto.
    it 'no expone la contraseña' do
      expect(build_config(sql_values).fingerprint).not_to include('secret')
    end
  end

  describe '#to_s' do
    it 'describe el destino sin credenciales' do
      str = build_config(sql_values).to_s

      expect(str).to include('SQL', 'CLSQL01', 'CL_DOCS')
      expect(str).not_to include('fec_ro', 'secret')
    end
  end

  describe 'valores por defecto' do
    it 'usa el timeout por defecto cuando no está configurado' do
      expect(build_config(sql_values).query_timeout).to eq(described_class::DEFAULT_QUERY_TIMEOUT)
    end

    it 'respeta el configurado' do
      expect(build_config(sql_values.merge('QUERY_TIMEOUT' => '45')).query_timeout).to eq(45)
    end
  end
end

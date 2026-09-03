require 'rails_helper'

# Este spec es el contrato de las diferencias entre motores que el usuario
# describió y que están vivas en las instalaciones:
#
#   SQL Server │ Server=CLSQL01;Database=CL_DOCS   · puerto con COMA, opcional
#   HANA       │ SERVERNODE=clhna721:30015         · puerto con DOS PUNTOS,
#              │                                     obligatorio, y la base NO
#              │                                     va en el DSN
RSpec.describe ExternalDb::Dialect do
  def config_for(values)
    ExternalDb::Config.new(group_code: 'DOCS_DB_ODBC', values: values)
  end

  let(:sql_base) do
    { 'ENGINE' => 'SQL', 'DRIVER' => 'ODBC Driver 17 for SQL Server',
      'SERVER' => 'CLSQL01', 'DATABASE' => 'CL_DOCS',
      'USER' => 'fec_ro', 'PASSWORD' => 'secret' }
  end

  let(:hana_base) do
    { 'ENGINE' => 'HANA', 'DRIVER' => 'HDBODBC', 'SERVER' => 'clhna721',
      'PORT' => '30015', 'DATABASE' => 'CL_DOCS',
      'USER' => 'FEC_RO', 'PASSWORD' => 'secret' }
  end

  def sql(overrides = {})  = described_class.for(config_for(sql_base.merge(overrides)))
  def hana(overrides = {}) = described_class.for(config_for(hana_base.merge(overrides)))

  describe '.for' do
    it 'resuelve SQL Server' do
      expect(sql).to be_a(ExternalDb::Dialect::SqlServer)
    end

    it 'resuelve HANA' do
      expect(hana).to be_a(ExternalDb::Dialect::Hana)
    end
  end

  describe 'SQL Server' do
    describe '#connection_string' do
      it 'arma el DSN con Database adentro' do
        expect(sql.connection_string).to eq(
          'Driver={ODBC Driver 17 for SQL Server};Server=CLSQL01;' \
          'Database=CL_DOCS;UID=fec_ro;PWD=secret'
        )
      end

      # El nombre del driver lleva espacios y va SIEMPRE entre llaves; que se
      # cierren es lo que hace que el driver manager lo resuelva.
      it 'encierra el driver en llaves balanceadas' do
        expect(sql.connection_string).to start_with('Driver={ODBC Driver 17 for SQL Server};')
      end

      # Con dos puntos el driver lo lee como nombre de instancia y falla con
      # "server not found".
      it 'pega el puerto con COMA' do
        expect(sql('PORT' => '1433').connection_string).to include('Server=CLSQL01,1433;')
      end

      it 'omite Database cuando no está configurada' do
        expect(sql.class.new(config_for(sql_base.except('DATABASE'))).connection_string)
          .not_to include('Database=')
      end

      # Sin esto, una contraseña con `;` parte la cadena y los parámetros que
      # siguen se pierden sin error.
      it 'encierra en llaves una contraseña con caracteres especiales' do
        expect(sql('PASSWORD' => 'p;w=d').connection_string).to end_with('PWD={p;w=d}')
      end

      it 'duplica la llave de cierre que venga en el valor' do
        expect(sql('PASSWORD' => 'a}b;c').connection_string).to end_with('PWD={a}}b;c}')
      end

      it 'agrega los parámetros extra al final' do
        expect(sql('EXTRA_PARAMS' => 'Encrypt=yes;TrustServerCertificate=yes').connection_string)
          .to end_with(';Encrypt=yes;TrustServerCertificate=yes')
      end

      # Con autenticación integrada el driver IGNORA UID/PWD. Se omiten en vez de
      # mandarlos igual: una cadena que los lleva dice una cosa y hace otra, y es
      # lo que hacía perseguir una contraseña cuando esas credenciales nunca se
      # usaron.
      context 'con autenticación integrada' do
        let(:trusted) { sql('TRUSTED' => 'true') }

        it 'manda Trusted_Connection en lugar de UID y PWD' do
          expect(trusted.connection_string).to eq(
            'Driver={ODBC Driver 17 for SQL Server};Server=CLSQL01;' \
            'Database=CL_DOCS;Trusted_Connection=Yes'
          )
        end

        it 'no filtra el usuario ni la contraseña guardados' do
          expect(trusted.connection_string).not_to include('fec_ro', 'secret')
        end
      end
    end

    describe '#qualify' do
      # Base + esquema + objeto. Sin el esquema, `[CL_DOCS].[SP]` es una
      # calificación inválida.
      it 'usa base, esquema y objeto, con dbo por defecto' do
        expect(sql.qualify('SP_DOCS')).to eq('[CL_DOCS].[dbo].[SP_DOCS]')
      end

      it 'respeta el esquema configurado' do
        expect(sql('SCHEMA' => 'reportes').qualify('SP_DOCS'))
          .to eq('[CL_DOCS].[reportes].[SP_DOCS]')
      end
    end

    describe '#call_statement' do
      # `EXEC`, la sintaxis nativa. `CALL` es de HANA y acá no compila.
      it 'usa EXEC con un placeholder por parámetro, separados por coma' do
        expect(sql.call_statement('SP_DOCS', 2))
          .to eq('EXEC [CL_DOCS].[dbo].[SP_DOCS] ?, ?')
      end

      # Un `()` vacío no es "cero argumentos": el driver lo lee como una lista de
      # argumentos presente y rechaza la llamada con "Procedure … has no
      # parameters and arguments were supplied", un mensaje que miente porque no
      # se envió ninguno. En `EXEC` la lista simplemente no está.
      it 'no lleva lista de argumentos en un procedimiento sin parámetros' do
        expect(sql.call_statement('SP_DOCS', 0)).to eq('EXEC [CL_DOCS].[dbo].[SP_DOCS]')
      end
    end

    describe '#paginate' do
      it 'usa OFFSET / FETCH NEXT' do
        expect(sql.paginate('SELECT a FROM t ORDER BY a', limit: 10, offset: 20))
          .to eq('SELECT a FROM t ORDER BY a OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY')
      end

      # OFFSET/FETCH no compila sin ORDER BY, y sin orden determinista las
      # páginas pueden repetir u omitir filas.
      it 'exige ORDER BY' do
        expect { sql.paginate('SELECT a FROM t', limit: 10, offset: 0) }
          .to raise_error(ExternalDb::QueryError, /ORDER BY/)
      end
    end

    it 'sondea con SELECT 1, que acá es válido sin FROM' do
      expect(sql.probe_sql).to eq('SELECT 1')
    end
  end

  describe 'HANA' do
    describe '#connection_string' do
      it 'arma el DSN con SERVERNODE' do
        expect(hana.connection_string).to eq(
          'Driver={HDBODBC};SERVERNODE=clhna721:30015;UID=FEC_RO;PWD=secret'
        )
      end

      # Es la práctica de las instalaciones vivas: la base califica cada consulta
      # (`CALL <db-code>.SP1`), no la cadena de conexión.
      it 'NO mete la base en el DSN' do
        expect(hana.connection_string).not_to include('CL_DOCS')
      end

      it 'pega el puerto con DOS PUNTOS' do
        expect(hana.connection_string).to include('SERVERNODE=clhna721:30015')
      end

      # Para un HANA multi-tenant hay que elegir el tenant; ese caso va por acá y
      # no por un ajuste dedicado.
      it 'permite DATABASENAME por los parámetros extra' do
        expect(hana('EXTRA_PARAMS' => 'DATABASENAME=HDB').connection_string)
          .to end_with(';DATABASENAME=HDB')
      end
    end

    describe '#qualify' do
      # Un solo tramo: en HANA el código de base ES el esquema.
      it 'usa un solo tramo' do
        expect(hana.qualify('SP1')).to eq('CL_DOCS.SP1')
      end

      # HANA pasa a mayúsculas todo identificador sin comillas, así que emitirlo
      # desnudo replica lo que hoy funciona escrito a mano. Entrecomillar
      # `"cl_docs"` apuntaría a un objeto que no existe.
      it 'emite en mayúsculas y sin comillas lo que el operador escriba en minúscula' do
        expect(hana('DATABASE' => 'cl_docs').qualify('sp1')).to eq('CL_DOCS.SP1')
      end

      it 'entrecomilla, respetando la caja, un nombre que lo exige' do
        expect(hana('DATABASE' => 'CL-DOCS').qualify('SP1')).to eq('"CL-DOCS".SP1')
      end

      it 'respeta el esquema configurado por encima de la base' do
        expect(hana('SCHEMA' => 'REPORTES').qualify('SP1')).to eq('REPORTES.SP1')
      end
    end

    describe '#call_statement' do
      it 'usa CALL, la sintaxis nativa de HANA' do
        expect(hana.call_statement('SP1', 1)).to eq('CALL CL_DOCS.SP1(?)')
      end

      # Al revés que SQL Server: acá la lista va SIEMPRE entre paréntesis, aunque
      # esté vacía. Es la gramática de `CALL` en HANA.
      it 'conserva los paréntesis vacíos en un procedimiento sin parámetros' do
        expect(hana.call_statement('SP1', 0)).to eq('CALL CL_DOCS.SP1()')
      end
    end

    describe '#paginate' do
      it 'usa LIMIT / OFFSET' do
        expect(hana.paginate('SELECT a FROM t ORDER BY a', limit: 10, offset: 20))
          .to eq('SELECT a FROM t ORDER BY a LIMIT 10 OFFSET 20')
      end

      # Acá la sintaxis sí compila sin ORDER BY, así que se avisa en vez de
      # cortar.
      it 'avisa en el log si falta ORDER BY, pero no levanta' do
        expect(Rails.logger).to receive(:warn).with(/ORDER BY/)

        expect { hana.paginate('SELECT a FROM t', limit: 10, offset: 0) }.not_to raise_error
      end
    end

    # Un `SELECT 1` a secas, válido en SQL Server, acá es error de sintaxis:
    # HANA exige FROM y `DUMMY` es su tabla de una fila.
    it 'sondea con FROM DUMMY' do
      expect(hana.probe_sql).to eq('SELECT 1 FROM DUMMY')
    end
  end
end

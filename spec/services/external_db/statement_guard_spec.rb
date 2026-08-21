require 'rails_helper'

# ⚠️ Estos ejemplos describen una RED, no una barrera. La garantía de
# solo-lectura son los permisos del usuario de base de datos — ver el encabezado
# de `ExternalDb::StatementGuard`. Acá se fija lo que el chequeo textual sí
# atrapa, y también lo que deliberadamente NO atrapa.
RSpec.describe ExternalDb::StatementGuard do
  def assert(sql) = described_class.assert_read_only!(sql)

  describe 'lo que pasa' do
    it 'un SELECT' do
      expect { assert('SELECT * FROM docs WHERE id = ?') }.not_to raise_error
    end

    it 'un WITH de solo lectura' do
      expect { assert('WITH c AS (SELECT 1 AS a) SELECT a FROM c') }.not_to raise_error
    end

    it 'un SELECT con espacios y saltos por delante' do
      expect { assert("\n  SELECT 1\n") }.not_to raise_error
    end

    it 'un punto y coma final' do
      expect { assert('SELECT 1;') }.not_to raise_error
    end

    # Sin limpiar comentarios, un `-- update` daría falso positivo.
    it 'un comentario que menciona un verbo de escritura' do
      expect { assert('SELECT a FROM t -- ojo: update esto luego') }.not_to raise_error
    end

    it 'un comentario de bloque con un verbo de escritura' do
      expect { assert('SELECT a FROM t /* pendiente: DELETE los viejos */') }.not_to raise_error
    end

    # Una columna que se llame `UPDATED_BY` no es una escritura: los verbos se
    # buscan como palabra completa.
    it 'una columna cuyo nombre contiene un verbo' do
      expect { assert('SELECT UPDATED_BY, CREATED_BY FROM docs') }.not_to raise_error
    end

    it 'un literal que menciona un verbo' do
      expect { assert("SELECT a FROM t WHERE nota = 'hay que hacer un update'") }.not_to raise_error
    end
  end

  describe 'lo que rechaza' do
    it 'una consulta vacía' do
      expect { assert('') }.to raise_error(ExternalDb::ReadOnlyViolation, /vacía/)
      expect { assert(nil) }.to raise_error(ExternalDb::ReadOnlyViolation, /vacía/)
    end

    %w[UPDATE INSERT DELETE MERGE TRUNCATE DROP CREATE ALTER GRANT REVOKE].each do |verb|
      it "una sentencia que abre con #{verb}" do
        expect { assert("#{verb} algo") }
          .to raise_error(ExternalDb::ReadOnlyViolation, /empezar con SELECT o WITH/)
      end
    end

    # El agujero real de permitir `WITH`: en SQL Server
    # `WITH c AS (…) DELETE FROM c` es válido y empieza con WITH. Por eso los
    # verbos se buscan en CUALQUIER posición, no solo al principio.
    it 'un WITH que termina en DELETE' do
      expect { assert('WITH c AS (SELECT id FROM t) DELETE FROM c') }
        .to raise_error(ExternalDb::ReadOnlyViolation, /DELETE/)
    end

    it 'un SELECT con INTO que crea una tabla' do
      expect { assert('SELECT * INTO nueva FROM docs; DROP TABLE docs') }
        .to raise_error(ExternalDb::ReadOnlyViolation)
    end

    it 'más de una sentencia' do
      expect { assert('SELECT 1; SELECT 2') }
        .to raise_error(ExternalDb::ReadOnlyViolation, /más de una sentencia/)
    end

    # `#call` es el camino para invocar un procedimiento; `EXEC` a mano no.
    it 'un EXEC' do
      expect { assert('SELECT 1 FROM t WHERE x = 1 AND EXEC sp_algo = 1') }
        .to raise_error(ExternalDb::ReadOnlyViolation, /#call/)
    end
  end

  describe 'lo que NO atrapa (documentado a propósito)' do
    # Un procedimiento hace lo que quiera y desde acá no hay forma de saberlo.
    # Por eso `Client#call` no pasa por este guard y la garantía son los grants.
    it 'no puede saber si un procedimiento escribe' do
      expect { assert('SELECT * FROM tabla_que_es_una_vista_con_trigger') }.not_to raise_error
    end
  end

  describe '.preview' do
    # El mensaje va al log y puede llegar a una respuesta HTTP: una consulta
    # completa ahí es ruido, y con literales es una filtración.
    it 'recorta y aplana la consulta' do
      expect(described_class.preview("SELECT\n  a,\n  b\nFROM t", limit: 12))
        .to eq('SELECT a, b…')
    end

    it 'deja corta una consulta corta' do
      expect(described_class.preview('SELECT 1')).to eq('SELECT 1')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Qué pasa con la transacción al terminar una sentencia.
#
# Es lo único de `Client` que se puede probar sin una base de datos externa
# levantada, y es justo lo que más importa: el conector abre las conexiones con
# `autocommit = false`, así que este bloque decide si lo que una sentencia tocó
# queda o se deshace. Equivocarlo significa perder documentos reclamados o
# confirmar una escritura que nadie pidió.
RSpec.describe ExternalDb::Client do
  let(:config) do
    ExternalDb::Config.new(
      group_code: 'DOCS_DB_ODBC',
      values: { 'ENGINE' => 'SQL', 'DRIVER' => ExternalDb::Client.installed_drivers.first,
                'SERVER' => 'CLSQL01', 'DATABASE' => 'CL_DOCS',
                'USER' => 'fec_ro', 'PASSWORD' => 'secret' }
    )
  end

  # Doble de la conexión ODBC: se inyecta ya "conectada" para que `#run` no
  # intente abrir nada.
  let(:statement) { instance_double('ODBC::Statement', execute: nil, drop: nil) }
  let(:db)        { instance_double('ODBC::Database', connected?: true, commit: nil, rollback: nil) }

  let(:client) do
    described_class.new(config).tap do |c|
      c.instance_variable_set(:@db, db)
      allow(db).to receive(:prepare).and_return(statement)
    end
  end

  before { allow(statement).to receive(:fetch_hash).and_return(nil) }

  describe '#select' do
    it 'revierte siempre: es la defensa de solo-lectura del conector' do
      client.select('SELECT 1 FROM Docs')

      expect(db).to have_received(:rollback)
      expect(db).not_to have_received(:commit)
    end
  end

  describe '#call' do
    it 'revierte por defecto, igual que una lectura' do
      client.call('SP_REPORTE')

      expect(db).to have_received(:rollback)
      expect(db).not_to have_received(:commit)
    end

    # La excepción explícita: un procedimiento que reclama filas necesita que la
    # marca quede, o la cola nunca avanza.
    it 'confirma cuando se pide commit y la ejecución terminó bien' do
      client.call('SP_PENDIENTES', [], commit: true)

      expect(db).to have_received(:commit)
      expect(db).not_to have_received(:rollback)
    end

    # Confirmar después de un error dejaría la mitad del trabajo hecha, que es
    # peor que no haber hecho nada.
    it 'revierte cuando se pidió commit pero la sentencia falló' do
      allow(statement).to receive(:execute).and_raise(ODBC::Error, 'boom')

      expect { client.call('SP_PENDIENTES', [], commit: true) }
        .to raise_error(ExternalDb::QueryError)

      expect(db).to have_received(:rollback)
      expect(db).not_to have_received(:commit)
    end

    # Al revés que el rollback, que se traga el error: si el commit falla, las
    # filas ya volvieron y el llamador creería que reclamó documentos que en
    # realidad siguen libres.
    it 'levanta si el commit falla, en vez de avisar en el log' do
      allow(db).to receive(:commit).and_raise(ODBC::Error, 'sin transacción')

      expect { client.call('SP_PENDIENTES', [], commit: true) }
        .to raise_error(ExternalDb::QueryError, /no confirmó la transacción/)
    end

    it 'rechaza un nombre de procedimiento que no es un identificador' do
      expect { client.call('SP; DROP TABLE Docs') }
        .to raise_error(ExternalDb::QueryError, /no es un identificador válido/)
    end
  end
end

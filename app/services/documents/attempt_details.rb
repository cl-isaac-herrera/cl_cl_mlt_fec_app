# frozen_string_literal: true

module Documents
  # Historial de intentos de un documento en la cola (`CLAUDE.md` §37).
  #
  #   Documents::AttemptDetails.for(sap_db: 'SBO_ACME', doc_entry: 25, doc_type: '01')
  #   # => [#<Attempt created_at="2026-09-05 10:03:12" status_code=4 details="SAP no respondió">, …]
  #
  # A diferencia de `PendingQueue`, el procedimiento acá es un `SELECT` puro:
  # no reclama ni modifica nada, así que no hace falta `commit: true` — el
  # rollback por defecto del conector (§37) no pierde nada porque no hubo
  # ninguna escritura que confirmar.
  class AttemptDetails
    # Grupo de `settings` con los datos ODBC — el mismo que `PendingQueue`.
    GROUP_CODE = 'DOCS_DB_ODBC'

    # `EXEC …SLT_DOCUMENTATTEMPS @SAPDB, @DocEntry, @DocType` — el mismo par
    # `doc_entry` + `doc_type` que identifica al documento en toda la cola
    # (`doc_entry` NO es único por sí solo, ver `PendingQueue::Entry`).
    PROCEDURE = 'CL_D_CL_MLT_FEC_SLT_DOCUMENTATTEMPS'

    # Un intento de la cola, ya leído. `status_code` es el mismo catálogo
    # `dbo.StatusCodes` que `Documents::PendingQueue::STATUS_*`.
    Attempt = Data.define(:created_at, :status_code, :details)

    class << self
      # @return [Array<Attempt>]
      def for(sap_db:, doc_entry:, doc_type:)
        new(sap_db: sap_db, doc_entry: doc_entry, doc_type: doc_type).call
      end
    end

    def initialize(sap_db:, doc_entry:, doc_type:)
      @sap_db    = sap_db
      @doc_entry = doc_entry
      @doc_type  = doc_type
    end

    # @return [Array<Attempt>] en el orden en que los devolvió el procedimiento.
    def call
      rows = ExternalDb::Pool.with(GROUP_CODE) do |client|
        client.call(PROCEDURE, [sap_db, doc_entry, doc_type])
      end

      rows.map { |raw| build_attempt(raw) }
    end

    private

    attr_reader :sap_db, :doc_entry, :doc_type

    def build_attempt(raw)
      row = Row.new(raw)

      Attempt.new(
        created_at: format_created_at(row['CreatedAt']),
        status_code: row.integer('StatusCode'),
        details: row.string('Details')
      )
    end

    # `CreatedAt` es `datetime2`, así que el driver ODBC lo entrega como
    # `ODBC::TimeStamp` — NO como `Time`/`DateTime` — y su `#to_s` no es la
    # fecha formateada: es `"AAAA-MM-DD HH:MM:SS"` seguido de la fracción de
    # segundo cruda EN NANOSEGUNDOS y sin separador (`"… 813000000"`), que es
    # justo lo que se veía en el panel antes de este método. Se arma el string
    # a mano con sus accesores, al mismo formato de `CLAUDE.md` §5 (sin
    # fracción), para que el JS reciba siempre una fecha que sepa parsear.
    def format_created_at(value)
      case value
      when ODBC::TimeStamp
        format('%04d-%02d-%02d %02d:%02d:%02d',
               value.year, value.month, value.day, value.hour, value.minute, value.second)
      when Time, DateTime then value.strftime('%Y-%m-%d %H:%M:%S')
      when nil then nil
      else value.to_s
      end
    end
  end
end

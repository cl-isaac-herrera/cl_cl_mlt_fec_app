# frozen_string_literal: true

module Documents
  # Documentos que la base de la cola tiene esperando ser emitidos.
  #
  #   Documents::PendingQueue.pending
  #   # => [#<Entry id=1 doc_entry=25 doc_type="01" sap_db="CL_DEMO">, …]
  #
  # Es el paso 2 del flujo de `docs/sync-documents-flow.md`: el Post Transact de
  # SAP inserta una fila por intento y este procedimiento devuelve las que están
  # en `pending`.
  #
  # La conexión va por `ExternalDb::Pool` (`CLAUDE.md` §37) — nunca ODBC a mano—,
  # y el nombre del procedimiento lo califica el dialecto con la base y el esquema
  # configurados, así que la misma llamada sirve contra `[CL_DOCS].[dbo].[SP]` y
  # contra `CL_DOCS.SP`.
  #
  # ⚠️ Esto NO habla con SAP. La base de la cola es una base propia del producto;
  # llegar a la base de compañía de SAP por ODBC saltaría su lógica de negocio y
  # anularía su soporte (§37).
  class PendingQueue
    # Grupo de `settings` con los datos ODBC. Es el mismo que administra
    # Configuraciones → Generales y que prueba el botón "Probar conexión".
    GROUP_CODE = 'DOCS_DB_ODBC'

    # Procedimiento almacenado que devuelve la cola pendiente. Sin parámetros: el
    # filtro por estado vive adentro.
    #
    # ⚠️ NO es una consulta: es un `UPDATE … OUTPUT` que **reclama** las filas.
    #
    #   UPDATE dbo.DocumentsQueue SET StatusCode = 2, UpdatedAt = GETDATE()
    #   OUTPUT inserted.Id, inserted.DocEntry, inserted.DocType, inserted.SAPDB
    #   WHERE StatusCode = 0
    #      OR (StatusCode = 2 AND UpdatedAt <= DATEADD(MINUTE, -10, GETDATE()))
    #
    # Marcar y devolver en una sola operación atómica es lo que impide que dos
    # corridas —o dos workers— tomen el mismo documento. La segunda mitad del
    # `WHERE` es la recuperación: lo que quedó en "procesando" más de diez minutos
    # se considera abandonado y se vuelve a repartir.
    PROCEDURE = 'CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS'

    # Procedimiento que devuelve un documento a la cola con su estado y el motivo.
    #
    #   EXEC …UPT_DOCUMENT @Id, @DocEntry, @DocType, @SAPDB, @Details, @StatusCode
    #
    # Además de actualizar la fila, resuelve el duplicado en espera: si el
    # documento terminó `Sent`, el `OnHold` del mismo comprobante pasa a
    # `Cancelled`; si terminó `Error`, vuelve a `Pending` para que se reintente.
    # Por eso los cuatro identificadores viajan aunque `@Id` ya identifique la
    # fila — el procedimiento los necesita para encontrar al duplicado.
    UPDATE_PROCEDURE = 'CL_D_CL_MLT_FEC_UPT_DOCUMENT'

    # Estados de la cola. Son el catálogo `dbo.StatusCodes` de la base externa
    # (ver `db/external/sql_server/schema.sql`), no una invención de este lado:
    # la columna tiene una llave foránea contra esa tabla.
    STATUS_PENDING    = 0 # registrado por SAP, listo para procesarse
    STATUS_ON_HOLD    = 1 # en espera: otro intento del mismo documento está en curso
    STATUS_PROCESSING = 2 # tomado por una corrida
    STATUS_SENT       = 3 # enviado a Hacienda con éxito
    STATUS_ERROR      = 4 # fallo de validación o error técnico
    STATUS_CANCELLED  = 5 # descartado porque un intento previo ya terminó bien

    # `Details` es `NVARCHAR(MAX)`, así que el tope no lo pide la columna: lo pide
    # el sentido común. Un backtrace entero o el cuerpo de una respuesta de SAP
    # convierten la cola en un depósito de basura y no aportan nada que el log no
    # tenga mejor.
    MAX_DETAILS = 2_000

    # Una fila de la cola. `id` es la fila de la cola (el historial de intentos);
    # `doc_entry` + `doc_type` identifican el documento dentro de la compañía, y
    # `sap_db` dice en cuál.
    #
    # ⚠️ `doc_entry` NO es único por sí solo: es el consecutivo interno de cada
    # tabla de SAP, así que la factura 25 y la nota de crédito 25 existen a la vez.
    # Por eso el par con `doc_type` es la llave, y por eso las consultas de detalle
    # filtran por los dos (ver `db/seeds.rb` → `SL_RESOURCES_OWN`).
    Entry = Data.define(:id, :doc_entry, :doc_type, :sap_db) do
      # ¿El tipo de comprobante es uno que este producto sabe emitir?
      def known_type?
        DocType.valid?(doc_type)
      end

      # Identificación corta para el log. Sin datos del negocio: son ids.
      def to_s
        "cola##{id} #{sap_db}/#{doc_type}/DocEntry #{doc_entry}"
      end
    end

    class << self
      # @return [Array<Entry>]
      def pending
        new.pending
      end

      # @see #mark_error
      def mark_error(entry, details)
        new.mark_error(entry, details)
      end
    end

    # @return [Array<Entry>] en el orden en que los devolvió el procedimiento.
    #
    # `commit: true` porque el procedimiento reclama las filas y esa marca tiene
    # que quedar: el conector revierte por defecto (§37), y sin la excepción el
    # `UPDATE` se deshace al salir. La cola nunca avanzaría, la misma tanda se
    # reprocesaría en cada corrida y —una vez que el flujo llegue al envío— el
    # mismo comprobante se le mandaría a Hacienda una y otra vez.
    def pending
      rows = ExternalDb::Pool.with(GROUP_CODE) { |client| client.call(PROCEDURE, [], commit: true) }

      rows.filter_map { |row| build_entry(row) }
    end

    # Devuelve el documento a la cola como `Error`, con el motivo en `Details`.
    #
    # Es lo que hace visible una falla. Sin esto la fila se queda en `Processing`
    # —el estado en el que la dejó `#pending`— y desde afuera es indistinguible de
    # un documento que se está procesando ahora mismo: no hay dónde leer qué pasó,
    # y el procedimiento la vuelve a repartir a los diez minutos, para siempre.
    #
    # `commit: true` por la misma razón que en `#pending`: sin confirmar, el
    # conector revierte el `UPDATE` al salir (§37) y el estado no quedaría.
    #
    # @param entry [Entry] el documento, tal como lo devolvió la cola.
    # @param details [String] el motivo, en el idioma del operador.
    def mark_error(entry, details)
      ExternalDb::Pool.with(GROUP_CODE) do |client|
        client.call(
          UPDATE_PROCEDURE,
          # Posicionales, en el orden en que el procedimiento los declara:
          # @Id, @DocEntry, @DocType, @SAPDB, @Details, @StatusCode.
          [entry.id, entry.doc_entry, entry.doc_type, entry.sap_db,
           truncate_details(details), STATUS_ERROR],
          commit: true
        )
      end
    end

    private

    def truncate_details(details)
      text = details.to_s.strip
      return text if text.length <= MAX_DETAILS

      "#{text[0, MAX_DETAILS - 1]}…"
    end

    # Una fila sin los datos mínimos se descarta con un aviso en vez de tumbar la
    # corrida entera: el resto de la cola sí se puede procesar, y una fila rota es
    # un problema de quien la insertó.
    #
    # El tipo desconocido NO se descarta acá: la fila está bien formada y el
    # documento existe: lo que no se sabe es cómo armarlo. Se deja pasar para que
    # el llamador lo reporte como lo que es —un tipo sin soporte— y no como una
    # fila corrupta.
    def build_entry(raw)
      row = Row.new(raw)

      id        = row.integer('Id')
      doc_entry = row.integer('DocEntry')
      doc_type  = row.string('DocType')
      sap_db    = row.string('SAPDB')

      if id.nil? || doc_entry.nil? || doc_type.nil? || sap_db.nil?
        Rails.logger.warn(
          "[Documents::PendingQueue] fila incompleta en #{PROCEDURE}, se omite: #{row.to_h.inspect}"
        )
        return nil
      end

      Entry.new(
        id:        id,
        doc_entry: doc_entry,
        # Se guarda el código canónico cuando se lo reconoce (`1` → `01`); si no,
        # el crudo, para que el aviso diga qué llegó realmente.
        doc_type:  DocType.normalize(doc_type) || doc_type,
        sap_db:    sap_db
      )
    end
  end
end

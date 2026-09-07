# frozen_string_literal: true

module Documents
  # Documentos que la base de la cola tiene esperando ser emitidos.
  #
  #   Documents::PendingQueue.pending
  #   # => [#<Entry id=1 doc_entry=25 doc_type="01" sap_db="CL_DEMO">, …]
  #
  # Es el paso 2 del flujo de `docs/sync-documents-flow.md`: el Post Transact de
  # SAP inserta una fila por documento y este procedimiento devuelve las que están
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
  #
  # ── Una sola fila por documento, nunca un duplicado ──────────────────────────
  # El Post Transact (`db/external/sql_server/sap_post_transact_section.sql`)
  # solo encola en `@transaction_type = 'A'` (alta) y el procedimiento que llama
  # inserta nada más si todavía no existe una fila para esa llave — sin importar
  # su estado. Es a propósito: cuando este producto corrige el documento por
  # Service Layer (para reintentarlo), esa escritura también dispara el Post
  # Transact, y antes eso volvía a insertar una fila nueva — un ciclo
  # encolar→emitir→re-encolar del propio arreglo, no del documento real.
  #
  # El motivo de que haga falta reintentar en primer lugar: un documento puede
  # fallar por un dato maestro fuera de sí mismo (el socio de negocio, un
  # impuesto, etc.), y el Post Transact no vuelve a disparar cuando se corrige
  # ESE dato — solo cuando el documento cambia. Sin un reintento que vuelva a
  # consultar la información ya corregida, el documento se queda varado para
  # siempre en `Error`.
  #
  # Por eso `#pending` reintenta `Error` con backoff exponencial (ver
  # `PROCEDURE`) en vez de re-encolar, y cada intento —no solo el último— se
  # guarda en `DocumentAttemptDetails` (ver `UPDATE_PROCEDURE`): es la
  # trazabilidad de cuántas veces se reintentó y por qué falló cada vez.
  #
  # `#pending_check` es la otra mitad del ciclo, que consume `CheckSentDocumentsJob`:
  # los documentos que ya se enviaron (`Sent`) y falta que Hacienda resuelva.
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
    #      OR (StatusCode = 4 AND DATEDIFF(MINUTE, UpdatedAt, GETDATE()) >= POWER(2, Attempts))
    #
    # Marcar y devolver en una sola operación atómica es lo que impide que dos
    # corridas —o dos workers— tomen el mismo documento. La segunda condición es
    # la recuperación de lo que quedó "procesando" más de diez minutos (abandonado,
    # se reparte de nuevo). La tercera es el reintento de `Error` con backoff
    # exponencial: 1 intento → 2 min, 2 → 4 min, 3 → 8 min…, para que un documento
    # que falla por un dato maestro corregido después (ver la nota de la clase)
    # no dependa de que alguien lo re-encole a mano.
    PROCEDURE = 'CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS'

    # Procedimiento que devuelve un documento a la cola con su estado y el motivo.
    #
    #   EXEC …UPT_DOCUMENT @Id, @DocEntry, @DocType, @SAPDB, @Details, @StatusCode
    #
    # Además de actualizar la fila (y sumar el intento a `Attempts`, para el
    # backoff exponencial de `#pending`), guarda el detalle en el historial de
    # intentos (`DocumentAttemptDetails`) en vez de sobrescribir un único
    # campo. `@DocEntry`/`@DocType`/`@SAPDB` quedan en la firma aunque `@Id` ya
    # identifique la fila, por compatibilidad con la firma existente.
    UPDATE_PROCEDURE = 'CL_D_CL_MLT_FEC_UPT_DOCUMENT'

    # Procedimiento que devuelve los documentos `Sent` (3) que hay que volver a
    # consultar contra Hacienda — el paso 1 de `CheckSentDocumentsJob`.
    #
    # ⚠️ A diferencia de `PROCEDURE`, es un `SELECT` puro: no reclama filas. No
    # hace falta — leer el estado en Hacienda es idempotente (a diferencia de
    # reenviar un comprobante), y el propio `WHERE StatusCode = 3` hace que un
    # documento salga solo de esta lista en cuanto `#mark` lo deja en
    # `Accepted`/`Rejected`.
    CHECK_PROCEDURE = 'CL_D_CL_MLT_FEC_SLT_PENDINGCHECKDOCUMENTS'

    # Procedimiento que reencola un documento `Rejected` a pedido del usuario
    # (botón "Reprocesar" de `documents_issued_controller.js`).
    #
    #   EXEC …UPT_REPROCESSDOCUMENT @DocEntry, @SAPDB, @DocType, @Details
    #
    # La validación de que el documento esté en `Rejected` vive DENTRO del SP,
    # no acá: es lo que evita la carrera de dos pestañas reprocesando el mismo
    # documento a la vez. Devuelve el `Id` de la fila cuando sí aplicó, o
    # ningún registro cuando no había nada que reprocesar (ver `#reprocess`).
    REPROCESS_PROCEDURE = 'CL_D_CL_MLT_FEC_UPT_REPROCESSDOCUMENT'

    # Estados de la cola. Son el catálogo `dbo.StatusCodes` de la base externa
    # (ver `db/external/sql_server/schema.sql`), no una invención de este lado:
    # la columna tiene una llave foránea contra esa tabla.
    STATUS_PENDING    = 0 # registrado por SAP, listo para procesarse
    STATUS_PROCESSING = 2 # tomado por una corrida
    # De TRÁNSITO, no final: se envió el comprobante y Hacienda todavía no
    # contestó si lo aceptó o lo rechazó (equivale a "EnHacienda" del legacy).
    STATUS_SENT       = 3
    STATUS_ERROR      = 4 # fallo de validación o error técnico
    STATUS_ACCEPTED   = 6 # Hacienda aceptó el comprobante — final
    STATUS_REJECTED   = 7 # Hacienda rechazó el comprobante — final
    # Reencolado a pedido del usuario sobre un documento `Rejected`. `PROCEDURE`
    # lo toma igual que `Pending` (sin el backoff de `Error`, ver su `WHERE`):
    # es un reintento explícito, no automático.
    STATUS_REPROCESS  = 8

    # `Details` es `NVARCHAR(MAX)`, así que el tope no lo pide la columna: lo pide
    # el sentido común. Un backtrace entero o el cuerpo de una respuesta de SAP
    # convierten la cola en un depósito de basura y no aportan nada que el log no
    # tenga mejor.
    MAX_DETAILS = 2_000

    # Una fila de la cola. `id` identifica al documento dentro de la cola —hay una
    # sola fila por documento, nunca una por intento (ver la nota de la clase); el
    # historial de cada intento se guarda aparte, en `DocumentAttemptDetails`—.
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

      # @return [Array<Entry>] los `Sent` que `CheckSentDocumentsJob` tiene que
      #   volver a consultar contra Hacienda.
      def pending_check
        new.pending_check
      end

      # @see #mark
      def mark_error(entry, details)
        new.mark(entry, status: STATUS_ERROR, details: details)
      end

      # El comprobante quedó en poder de Hacienda y falta su resolución.
      #
      # `details` lleva la URL donde Hacienda la va a publicar (el `Location`
      # del envío): es de tránsito, no un mensaje de error, y es el único dato
      # que la pasada que recoja la resolución va a necesitar para encontrarla.
      def mark_sent(entry, location)
        new.mark(entry, status: STATUS_SENT, details: location)
      end

      # @see #mark
      def mark(entry, status:, details: nil)
        new.mark(entry, status: status, details: details)
      end

      # @see #reprocess
      def reprocess(sap_db:, doc_entry:, doc_type:, details:)
        new.reprocess(sap_db: sap_db, doc_entry: doc_entry, doc_type: doc_type, details: details)
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

      rows.filter_map { |row| build_entry(row, PROCEDURE) }
    end

    # @return [Array<Entry>] en el orden en que los devolvió el procedimiento.
    #
    # Sin `commit: true`: es un `SELECT` puro (ver `CHECK_PROCEDURE`), no hay
    # ningún `UPDATE` que confirmar.
    def pending_check
      rows = ExternalDb::Pool.with(GROUP_CODE) { |client| client.call(CHECK_PROCEDURE, []) }

      rows.filter_map { |row| build_entry(row, CHECK_PROCEDURE) }
    end

    # Devuelve el documento a la cola con su desenlace y el detalle.
    #
    # Es lo que hace visible cómo terminó. Sin esto la fila se queda en
    # `Processing` —el estado en el que la dejó `#pending`— y desde afuera es
    # indistinguible de un documento que se está procesando ahora mismo: no hay
    # dónde leer qué pasó, y el procedimiento la vuelve a repartir a los diez
    # minutos, para siempre.
    #
    # ⚠️ Dejar la fila en `Processing` A PROPÓSITO es una opción válida y es lo
    # que se hace con una falla transitoria (Hacienda caída, un timeout): esos
    # diez minutos son justamente el reintento, y no hay que inventarle otro.
    # Ver `SyncIssuedDocumentsJob#transient`.
    #
    # `commit: true` por la misma razón que en `#pending`: sin confirmar, el
    # conector revierte el `UPDATE` al salir (§37) y el estado no quedaría.
    #
    # @param entry [Entry] el documento, tal como lo devolvió la cola.
    # @param status [Integer] uno de los `STATUS_*`.
    # @param details [String, nil] el motivo o el `Location`, según el estado.
    def mark(entry, status:, details:)
      ExternalDb::Pool.with(GROUP_CODE) do |client|
        client.call(
          UPDATE_PROCEDURE,
          # Posicionales, en el orden en que el procedimiento los declara:
          # @Id, @DocEntry, @DocType, @SAPDB, @Details, @StatusCode.
          [entry.id, entry.doc_entry, entry.doc_type, entry.sap_db,
           truncate_details(details), status],
          commit: true
        )
      end
    end

    # Reencola un documento `Rejected` a pedido del usuario (botón "Reprocesar"
    # de `documents_issued_controller.js` → `Api::DocumentsController#reprocess`).
    #
    # A diferencia de `#mark`, no recibe un `Entry`: quien llama solo tiene lo
    # que trae el listado de SAP (`DocEntry`/`DocType`/`SAPDB`), no el `Id`
    # interno de la cola — la fila se identifica por esos tres campos, igual que
    # `Documents::AttemptDetails`.
    #
    # `commit: true` por la misma razón que `#mark`/`#pending`: el procedimiento
    # SÍ escribe (reencola la fila y registra el intento) y el conector revierte
    # por defecto (§37).
    #
    # @return [Boolean] `true` si había un `Rejected` para reencolar, `false` si
    #   no existía en la cola o ya no estaba en ese estado — la validación real
    #   la hace el SP, esto solo lee si devolvió una fila.
    def reprocess(sap_db:, doc_entry:, doc_type:, details:)
      rows = ExternalDb::Pool.with(GROUP_CODE) do |client|
        client.call(REPROCESS_PROCEDURE, [doc_entry, sap_db, doc_type, truncate_details(details)], commit: true)
      end

      rows.any?
    end

    private

    # `nil` se conserva y no se convierte en cadena vacía: la columna es
    # anulable y `NULL` significa "no hay nada que contar", que es distinto de
    # un detalle en blanco.
    def truncate_details(details)
      return nil if details.nil?

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
    def build_entry(raw, procedure)
      row = Row.new(raw)

      id        = row.integer('Id')
      doc_entry = row.integer('DocEntry')
      doc_type  = row.string('DocType')
      sap_db    = row.string('SAPDB')

      if id.nil? || doc_entry.nil? || doc_type.nil? || sap_db.nil?
        Rails.logger.warn(
          "[Documents::PendingQueue] fila incompleta en #{procedure}, se omite: #{row.to_h.inspect}"
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

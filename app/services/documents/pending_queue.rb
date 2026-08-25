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
    PROCEDURE = 'CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS'

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
    end

    # @return [Array<Entry>] en el orden en que los devolvió el procedimiento.
    def pending
      rows = ExternalDb::Pool.with(GROUP_CODE) { |client| client.call(PROCEDURE) }

      rows.filter_map { |row| build_entry(row) }
    end

    private

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

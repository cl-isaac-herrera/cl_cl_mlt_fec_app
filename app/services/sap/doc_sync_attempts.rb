# frozen_string_literal: true

module Sap
  # Historial de intentos de sincronización de un documento, en la UDT
  # `@CL_FEC_DOCSYNCATTMP` —que el Service Layer expone como el entity set
  # `U_CL_FEC_DOCSYNCATTMP`, el nombre que guarda el catálogo (`db/seeds.rb` →
  # `SL_RESOURCES_DOC_SYNC_ATTEMPTS`)— declarada en
  # `config/sap_schemas/doc_sync_attempts_udt.json`.
  #
  #   Sap::DocSyncAttempts.new(client: client).create(
  #     doc_entry: 25, doc_type: '01', status: Documents::PendingQueue::STATUS_ERROR,
  #     details: 'Hacienda rechazó el comprobante'
  #   )
  #
  # ── Por qué el historial dejó de vivir en la base de la cola ────────────────
  # Antes lo insertaba el propio SP (`CL_D_CL_MLT_FEC_UPT_DOCUMENT` y el de
  # reprocesar) en la tabla `DocumentAttemptDetails`. Ahora la cola externa solo
  # decide CUÁNDO reintentar (`StatusCode` + `Attempts`, ver
  # `Documents::PendingQueue`) y el detalle de cada intento vive en SAP, junto
  # al documento, para que el operador lo vea desde ahí sin entrar a esta base.
  # Es el MISMO reparto que ya tenía el correo de recepción entre
  # `Documents::MailQueue` (cola) y `Sap::MailQueue` (UDT).
  #
  # ── El catálogo de estados es el de la cola, no uno propio ──────────────────
  # `U_Status` declara los 7 valores de `dbo.StatusCodes`
  # (`Documents::PendingQueue::STATUS_*`), incluido el transitorio `Processing`.
  # Al agregar o quitar un estado hay que actualizar sus `ValidValues` — el
  # checklist completo está en `config/sap_schemas/README.md`.
  class DocSyncAttempts
    CREATE_CODE = 'createDocSyncAttempt'
    QUERY_CODE  = 'getDocSyncAttempts'

    # `U_Details` es `db_Memo`, así que el tope no lo pide el campo: lo pide el
    # sentido común. Un backtrace entero o el cuerpo de una respuesta de SAP
    # convierten el historial en un depósito de basura y no aportan nada que el
    # log no tenga mejor. Es el mismo tope que tenía la tabla que reemplaza.
    MAX_DETAILS = 2_000

    # Un intento ya leído. `status_code` es el mismo catálogo que
    # `Documents::PendingQueue::STATUS_*`.
    Attempt = Data.define(:created_at, :status_code, :details)

    # @param client [Clavisco::ServiceLayer::Client] el de la compañía.
    def initialize(client:)
      @client = client
    end

    # Registra un intento. Es un `POST`: cada intento es una fila nueva, nunca
    # un `PATCH` sobre la anterior — el valor del historial es justamente
    # cuántas veces se intentó y con qué desenlace cada vez.
    #
    # @param status [Integer] uno de `Documents::PendingQueue::STATUS_*`.
    # @param details [String, nil] el motivo, el `Location` de Hacienda o quién
    #   pidió el reprocesamiento, según el desenlace. `nil` se conserva y no se
    #   convierte en cadena vacía: el campo es anulable y `NULL` significa "no
    #   hay nada que contar", que es distinto de un detalle en blanco.
    # @return [String, nil] el `Code` que SAP le asignó a la fila nueva.
    def create(doc_entry:, doc_type:, status:, details: nil)
      body = {
        'U_DocEntry'  => doc_entry,
        'U_DocType'   => doc_type,
        'U_Status'    => status,
        'U_Details'   => truncate_details(details),
        'U_CreatedAt' => Time.current.iso8601
      }

      Documents::Row.new(client.post(Sap::ResourceQuery.path_for(CREATE_CODE), body: body)).string('Code')
    end

    # El historial de un documento, del intento más reciente al más viejo — el
    # `$orderby` vive en el catálogo, igual que el `$filter`.
    #
    # `SAPDB` no es parte de la llave (a diferencia del SP que esto reemplaza):
    # la compañía ya la determina la base de SAP contra la que se consulta. El
    # par `DocEntry` + `DocType` sí, porque `doc_entry` no es único por sí solo
    # (ver `Documents::PendingQueue::Entry`).
    #
    # @return [Array<Attempt>]
    def list(doc_entry:, doc_type:)
      rows = Array.wrap(client.get(query_path(doc_entry, doc_type)))

      rows.map do |raw|
        row = Documents::Row.new(raw)

        Attempt.new(
          created_at:  row.string('U_CreatedAt'),
          status_code: row.integer('U_Status'),
          details:     row.string('U_Details')
        )
      end
    end

    private

    attr_reader :client

    def query_path(doc_entry, doc_type)
      Sap::ResourceQuery.path_for(QUERY_CODE, DocEntry: doc_entry, DocType: doc_type)
    end

    def truncate_details(details)
      return nil if details.nil?

      text = details.to_s.strip
      return text if text.length <= MAX_DETAILS

      "#{text[0, MAX_DETAILS - 1]}…"
    end
  end
end

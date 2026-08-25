# frozen_string_literal: true

module Documents
  # Compañías indexadas por su base de datos de SAP, con la conexión ya cargada.
  #
  #   directory = Documents::CompanyDirectory.load
  #   company   = directory.fetch('CL_DEMO')   # => #<Company> o nil
  #
  # Es el punto 2 de `docs/sync-documents-flow.md`: el procedimiento de la cola
  # devuelve documentos de VARIAS compañías mezclados, y cada uno trae su `SAPDB`.
  # Resolver la compañía por documento serían dos consultas (compañía + conexión)
  # por cada fila de la cola; acá se resuelven todas de una sola vez y se guardan
  # en memoria mientras dura el job.
  #
  # ── Se cargan TODAS, no solo las de la tanda ─────────────────────────────────
  # Podría filtrarse por los `SAPDB` que trajo la cola, pero no vale la pena: este
  # producto se despliega **una instancia por cliente** (`CLAUDE.md` §31), así que
  # la tabla tiene las compañías de ese cliente y nada más — decenas, no miles. A
  # cambio, la consulta es una sola y siempre la misma, sin un `IN (…)` que cambia
  # de tamaño en cada corrida.
  #
  # ── El índice es case-insensitive ────────────────────────────────────────────
  # `SAPDB` viene del procedimiento de la cola y `companies.sap_db` lo escribió una
  # persona en un formulario. Que coincidan en la caja es una casualidad que no
  # conviene apostar: si no coinciden, la compañía "no existe" y el documento se
  # queda pendiente para siempre, sin ningún error que lo explique.
  class CompanyDirectory
    class << self
      # @return [CompanyDirectory]
      def load
        new
      end
    end

    def initialize(companies = nil)
      @by_sap_db = index(companies || load_companies)
    end

    # @param sap_db [String] el `SAPDB` que trajo la cola.
    # @return [Company, nil]
    def fetch(sap_db)
      @by_sap_db[normalize(sap_db)]
    end

    # ¿Hay compañía para esta base?
    def key?(sap_db)
      @by_sap_db.key?(normalize(sap_db))
    end

    def size
      @by_sap_db.size
    end

    # Las bases conocidas, para el mensaje de error cuando una no aparece: quien
    # lo lea necesita ver contra qué se comparó.
    def known_databases
      @by_sap_db.values.map(&:sap_db).sort
    end

    private

    # `includes(:sap_connection)` evita el N+1 al armar el cliente de cada
    # documento. El `default_scope` de `SoftDeletable` deja fuera a las compañías
    # dadas de baja, que es lo correcto: una compañía inactiva no emite.
    def load_companies
      Company.includes(:sap_connection).where.not(sap_db: [nil, ''])
    end

    # Ante dos compañías con el mismo `sap_db` gana la primera y se avisa: es una
    # configuración imposible (dos compañías no pueden ser la misma base de SAP) y
    # elegir en silencio mandaría los documentos de una con los datos de la otra.
    def index(companies)
      companies.each_with_object({}) do |company, acc|
        key = normalize(company.sap_db)
        next if key.empty?

        if acc.key?(key)
          Rails.logger.warn(
            "[Documents::CompanyDirectory] #{company.sap_db.inspect} está en más de una compañía " \
            "(#{acc[key].id} y #{company.id}); se usa la #{acc[key].id}."
          )
          next
        end

        acc[key] = company
      end
    end

    def normalize(sap_db)
      sap_db.to_s.strip.downcase
    end
  end
end

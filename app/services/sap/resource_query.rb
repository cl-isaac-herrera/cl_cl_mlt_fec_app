# frozen_string_literal: true

module Sap
  # Resuelve una fila de `sl_resources` a un path del Service Layer.
  #
  # Es el único lugar del producto que traduce "código funcional" → path de SAP.
  # Antes de esto cada flujo escribía el recurso y la query a mano (ver
  # `CredentialValidator`), lo que anulaba el sentido de la tabla: si la consulta
  # se puede editar desde la pantalla pero el flujo la tiene hardcodeada, la
  # edición no cambia nada.
  #
  # ⚠️ NO ejecuta la petición y NO conoce al Client: devuelve el path y el
  # llamador elige el verbo. Es deliberado — el catálogo tiene tanto lecturas
  # (`GetSuppliers`) como escrituras (`Drafts`, `PurchaseInvoices`, los `/Close`),
  # así que una clase que ejecutara tendría que crecer un método por verbo
  # (`#get`, `#post`, `#patch`, `#delete`) y habría que volver a tocarla cada vez
  # que un flujo nuevo necesite otro. Resolver el path es una sola
  # responsabilidad; hablar con SAP ya es la del Client.
  #
  #   client.get(Sap::ResourceQuery.path_for('GetSuppliers'))
  #   client.post(Sap::ResourceQuery.path_for('Drafts'), body: payload)
  #   client.post(Sap::ResourceQuery.path_for('ClosePurchaseOrders', DocumentEntry: 42), body: {})
  #   client.get(Sap::ResourceQuery.path_for('CheckIfExistApInvoice', Clave: '506...'))
  #
  # Cuando hace falta más que el path (paginar, leer el `page_size`), se usa la
  # instancia:
  #
  #   query = Sap::ResourceQuery.new('GetSuppliers')
  #   client.get(query.merge('$top' => query.page_size).path)
  #
  # ⚠️ La query se pega al recurso (`Users?$top=1&...`) y NO se pasa por el
  # `params:` del Client. `Client#get` serializa `params:` con
  # `URI.encode_www_form`, que convierte `$filter=(A eq 'B')` en
  # `%24filter=%28A+eq+%27B%27%29` — con el `$` escapado y los espacios como `+`.
  # La columna guarda la query cruda que el Service Layer espera, así que se manda
  # tal cual: `execute_request` hace `URI("#{base_url}#{resource}")` y ahí los
  # espacios se escapan solos a `%20`, dejando `$`, `=`, `&` y los paréntesis
  # intactos.
  #
  # El submódulo no ofrece nada de esto: `vendor/clavisco/data_access` son solo
  # cuatro concerns (Auditable, CompanyScoped, CurrentContext, SoftDeletable), y
  # ningún submódulo conoce `sl_resources`. Verificado con grep, no asumido.
  class ResourceQuery
    # Base de los tres errores de abajo, para que un llamador pueda distinguir
    # "no se pudo armar el path" de "SAP respondió mal" con un solo rescue. Los
    # tres significan lo mismo para quien llama: el catálogo o los parámetros
    # están mal, así que no hay nada que mandarle a SAP.
    class Error < StandardError; end

    # La consulta no está en el catálogo (o está dada de baja).
    class UnknownResource < Error; end
    # La consulta tiene un marcador que el llamador no ató a ningún valor.
    class MissingBinding < Error; end
    # El valor de un marcador de path no es seguro para interpolar en la URL.
    class UnsafeBinding < Error; end

    # `@Nombre` dentro de `query_params` — se reemplaza por un literal OData.
    QUERY_PLACEHOLDER = /@(\w+)/
    # `#Nombre#` dentro de `resource` — se reemplaza crudo, es parte del path
    # (`PurchaseOrders(#DocumentEntry#)/Close`).
    PATH_PLACEHOLDER = /#(\w+)#/
    # Lo único que se acepta interpolar en el path: sin `/`, `?`, `&` ni espacios,
    # para que un valor no pueda cambiar a qué endpoint se le está pegando.
    SAFE_PATH_VALUE = /\A[\w.-]+\z/

    # @param code [String] `sl_resources.code`
    # @param bindings [Hash] valores de los marcadores, por nombre (`{ Clave: '…' }`)
    def initialize(code, bindings: {})
      @code     = code.to_s
      @bindings = bindings.to_h { |key, value| [key.to_s, value] }
    end

    # Atajo para el caso normal: resolver el path de un tirón.
    #
    #   Sap::ResourceQuery.path_for('ClosePurchaseOrders', DocumentEntry: 42)
    #   # => "PurchaseOrders(42)/Close"
    #
    # @return [String]
    def self.path_for(code, bindings = {})
      new(code, bindings: bindings).path
    end

    # Path completo, listo para pasarle a cualquier verbo del Client.
    # @return [String]
    def path
      @path ||= build_path
    end

    # Recurso con sus marcadores de path resueltos.
    def resource
      @resource ||= substitute_path(record.resource)
    end

    # Query cruda con sus marcadores resueltos.
    def query
      @query ||= serialize(params)
    end

    # La query descompuesta, con la forma que usa el submódulo
    # (`{ '$top' => '1', '$select' => 'UserCode' }`). Sirve para leer una opción
    # puntual o para armar una variante con `#merge`.
    #
    # ⚠️ NO pasar este hash al `params:` de `Client#get`: ese keyword serializa
    # con `URI.encode_www_form` y manda `%24filter=%28A+eq+%27B%27%29` — el `$`
    # escapado (el Service Layer no lo reconoce como opción de sistema) y los
    # espacios como `+`. Verificado sobre las consultas del catálogo. Para eso
    # está `#path`, que serializa crudo.
    #
    # Es un Hash, así que una clave repetida se colapsaría; ninguna de las 22
    # consultas con query del catálogo tiene claves repetidas (verificado), y
    # repetir una opción OData no tiene sentido.
    # @return [Hash{String => String}] en el orden en que estaban escritas
    def params
      @params ||= decompose(substitute_query(record.query_params))
    end

    # Variante de esta consulta con opciones agregadas o sobreescritas, sin tocar
    # el catálogo. Es la forma de aplicar paginación (`$top`/`$skip`) o de acotar
    # un `$select` desde un flujo, en vez de concatenar strings a mano.
    #
    #   Sap::ResourceQuery.new('GetSuppliers').merge('$top' => page_size).path
    #
    # @return [Sap::ResourceQuery] una copia; el receptor queda intacto
    def merge(extra)
      dup.tap do |copy|
        copy.instance_variable_set(:@params, params.merge(extra.to_h { |k, v| [k.to_s, v] }))
        copy.instance_variable_set(:@query, nil)
      end
    end

    # Tamaño de página que definió el catálogo. 0 significa "sin paginación"
    # (ver `SlResource#paginated?`), no "cero filas".
    def page_size = record.page_size

    private

    attr_reader :code, :bindings

    # El path se loguea al resolverse, una sola vez por instancia (`path` está
    # memoizado). Es el único punto donde se puede ver qué se le va a pedir a SAP:
    # el Client solo loguea eventos de sesión, nunca la URI.
    #
    # Nivel `debug` a propósito: por acá pasa toda consulta a SAP, y el path lleva
    # los valores de los marcadores ya interpolados (una clave de documento, un
    # `CardCode`) — no es algo para dejar en el log de producción por defecto.
    def build_path
      built = query.present? ? "#{resource}?#{query}" : resource
      Rails.logger.debug { "[SL][ResourceQuery] #{code} -> #{built}" }
      built
    end

    # El `default_scope` de `SoftDeletable` deja fuera a las dadas de baja, y eso
    # es lo que se quiere: una consulta desactivada no se debe ejecutar.
    def record
      @record ||= SlResource.find_by(code: code) ||
                  raise(UnknownResource, "No existe la consulta de Service Layer '#{code}'.")
    end

    def substitute_query(raw)
      return nil if raw.blank?

      raw.gsub(QUERY_PLACEHOLDER) { odata_literal(binding_for(Regexp.last_match(1))) }
    end

    # Parte la query en pares clave/valor: separa por `&` y por el PRIMER `=`, así
    # que un valor que contenga `=` se conserva entero (`$filter=(A eq B)`).
    # Es la misma regla que usa el panel de edición
    # (`sl_resources_controller.js#splitParams`), para que las dos puntas
    # descompongan igual.
    def decompose(raw)
      return {} if raw.blank?

      raw.split('&').reject { |pair| pair.strip.empty? }.to_h do |pair|
        key, _, value = pair.partition('=')
        [key.strip, value.strip]
      end
    end

    # Vuelve a armar la query CRUDA, sin form-encoding: la columna guarda lo que
    # el Service Layer espera y `URI()` ya escapa por sí solo lo que es ilegal en
    # una URL (los espacios a `%20`), dejando `$`, `=`, `&` y los paréntesis.
    #
    # Una clave sin valor se emite sola, sin `=` colgando.
    def serialize(pairs)
      pairs.map { |key, value| value.to_s.empty? ? key : "#{key}=#{value}" }.join('&')
    end

    def substitute_path(raw)
      raw.to_s.gsub(PATH_PLACEHOLDER) do
        name  = Regexp.last_match(1)
        value = binding_for(name).to_s
        next value if value.match?(SAFE_PATH_VALUE)

        raise UnsafeBinding,
              "El valor de '#{name}' no se puede usar en el path de '#{code}': #{value.inspect}."
      end
    end

    # Un marcador sin valor revienta acá en vez de viajar a SAP: mandar
    # `$filter=(CardCode eq @CardCode)` devuelve un error OData indescifrable, y
    # el problema real es que el llamador se olvidó de un parámetro.
    def binding_for(name)
      return bindings.fetch(name) if bindings.key?(name)

      raise MissingBinding,
            "La consulta '#{code}' espera el parámetro '#{name}' y no se recibió."
    end

    # Literal OData: los strings van entre comillas simples (duplicando las que
    # traiga el valor, que es como OData las escapa) y los números crudos.
    #
    # ⚠️ Duplica `Clavisco::ServiceLayer::OdataFilter#format_value`, que es
    # `private` en el submódulo y no se puede llamar desde acá. El submódulo NO se
    # toca (`CLAUDE.md` §27) — anotado en `TODOS.md` → SAP para borrar este método
    # cuando `format_value` se exponga aguas arriba.
    def odata_literal(value)
      case value
      when nil            then 'null'
      when Numeric        then value.to_s
      when true, false    then value.to_s
      when Time, DateTime then "'#{value.strftime('%Y-%m-%dT%H:%M:%S')}'"
      when Date           then "'#{value.strftime('%Y-%m-%d')}'"
      else "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end
end

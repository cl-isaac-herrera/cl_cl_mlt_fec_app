# frozen_string_literal: true

module Documents
  # Lectura tolerante a la caja de una fila devuelta por ODBC o por el Service
  # Layer.
  #
  # No es una comodidad: el MISMO catálogo de consultas (`sl_resources`) sirve a
  # instalaciones sobre SQL Server y sobre HANA, y HANA devuelve los
  # identificadores en MAYÚSCULAS. Una fila que en SQL Server llega como
  # `{"DocEntry" => 25}` llega en HANA como `{"DOCENTRY" => 25}`, así que leer con
  # `row['DocEntry']` funciona en una instalación y devuelve `nil` en silencio en
  # la otra — que es la peor forma de fallar: el documento se arma igual, con el
  # campo vacío, y se envía así a Hacienda.
  #
  #   row = Documents::Row.new('DOCENTRY' => 25)
  #   row['DocEntry']   # => 25
  #
  # El índice se arma una vez por fila. Para un documento con cien líneas son cien
  # hashes chicos, no un recorrido por cada lectura de campo.
  class Row
    # @param source [Hash, Documents::Row, nil]
    def initialize(source = nil)
      @source = normalize_source(source)
      @index  = @source.each_with_object({}) { |(key, value), acc| acc[key.to_s.downcase] = value }
    end

    # @return [Object, nil] el valor, o nil si la columna no vino.
    def [](name)
      @index[name.to_s.downcase]
    end

    # ¿La columna existe en la fila? Distingue "vino en nil" de "no vino", que es
    # lo que separa un dato vacío de una vista que no expone la columna.
    def key?(name)
      @index.key?(name.to_s.downcase)
    end

    # Texto ya recortado, o nil si está vacío. Los `char(n)` de SQL Server llegan
    # con relleno de espacios y esos espacios terminarían en el XML.
    def string(name)
      value = self[name]
      return nil if value.nil?

      text = value.to_s.strip
      text.empty? ? nil : text
    end

    # Entero, o nil. Un texto que no es un número devuelve nil en vez de 0:
    # `'abc'.to_i` es 0 y ese cero se leería como un dato válido.
    def integer(name)
      value = self[name]
      return value if value.is_a?(Integer)
      return nil if value.nil?

      text = value.to_s.strip
      text.match?(/\A-?\d+\z/) ? text.to_i : nil
    end

    # Decimal exacto, o nil.
    #
    # `BigDecimal` y no `Float`: son montos que se suman para armar el desglose de
    # impuestos y que Hacienda compara contra sus propios totales. En coma
    # flotante, `0.1 + 0.2` no da `0.3` y el comprobante se rechaza por diferencia
    # de centavos.
    def decimal(name)
      value = self[name]
      return value if value.is_a?(BigDecimal)
      return nil if value.nil?

      BigDecimal(value.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end

    def to_h
      @source.dup
    end

    def empty?
      @source.empty?
    end

    private

    def normalize_source(source)
      case source
      when nil  then {}
      when Row  then source.to_h
      when Hash then source
      else source.respond_to?(:to_h) ? source.to_h : {}
      end
    end
  end
end

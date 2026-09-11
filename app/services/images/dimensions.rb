# frozen_string_literal: true

module Images
  # Las medidas intrínsecas de una imagen, leídas de su encabezado.
  #
  #   Images::Dimensions.of('C:/fec/3101822733/logo.png')  # => [1080, 108]
  #
  # Existe para que `Documents::ReceiptMailBody` pueda emitir el `<img>` del
  # logo con atributos `width`/`height` exactos: Outlook usa el motor de Word,
  # que ignora `max-width`/`max-height` de CSS, así que sin ellos un logo de
  # 1080 px de ancho se pinta a tamaño completo y rompe la tarjeta del correo.
  #
  # Solo PNG y JPEG — son los únicos formatos que acepta `Attachments::LogoStore`
  # (`.png`, `.jpg`, `.jpeg`). No se agrega una gema de procesamiento de
  # imágenes para esto: leer el encabezado son los primeros bytes del archivo, y
  # una dependencia nativa (ImageMagick/vips) para averiguar un ancho sería
  # desproporcionada.
  #
  # Nunca levanta: un archivo corrupto, truncado o de otro formato devuelve
  # `nil` y quien llama decide el plan B. Está en la ruta de envío de un correo,
  # y no poder medir un logo no es motivo para no mandar el comprobante.
  module Dimensions
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

    # Marcadores SOF (Start Of Frame) del JPEG, los que declaran el tamaño.
    # Se excluyen 0xC4 (tablas Huffman), 0xC8 (extensión JPEG) y 0xCC (tablas
    # aritméticas): comparten el rango pero no son SOF y su carga no tiene las
    # medidas donde este código las buscaría.
    JPEG_SOF_MARKERS = ((0xC0..0xCF).to_a - [0xC4, 0xC8, 0xCC]).freeze

    module_function

    # @param path [String, Pathname]
    # @return [Array(Integer, Integer), nil] `[ancho, alto]` en píxeles.
    def of(path)
      data = File.binread(path, 256 * 1024)
      return nil if data.nil? || data.empty?

      data.start_with?(PNG_SIGNATURE) ? png(data) : jpeg(data)
    rescue SystemCallError, IOError
      nil
    end

    # IHDR es obligatoriamente el primer chunk del PNG: 8 bytes de firma, 4 de
    # largo, 4 del tipo (`IHDR`), y ahí arrancan ancho y alto, 4 bytes cada uno
    # en big-endian.
    def png(data)
      return nil if data.bytesize < 24
      return nil unless data.byteslice(12, 4) == 'IHDR'

      data.byteslice(16, 8).unpack('N2')
    end
    private_class_method :png

    # El JPEG es una cadena de segmentos `0xFF <marcador> <largo de 2 bytes>
    # <carga>`. Se avanza de segmento en segmento hasta dar con un SOF, cuya
    # carga empieza con 1 byte de precisión, 2 de alto y 2 de ancho.
    def jpeg(data)
      return nil unless data.byteslice(0, 2) == "\xFF\xD8".b

      offset = 2
      while offset < data.bytesize - 9
        # Todo segmento arranca con 0xFF, y puede venir precedido de bytes de
        # relleno 0xFF: se avanza de a uno hasta el primero que no lo sea, que
        # es el marcador.
        if data.getbyte(offset) != 0xFF || data.getbyte(offset + 1) == 0xFF
          offset += 1
          next
        end

        marker = data.getbyte(offset + 1)
        length = data.byteslice(offset + 2, 2).unpack1('n').to_i
        return data.byteslice(offset + 5, 4).unpack('n2').reverse if JPEG_SOF_MARKERS.include?(marker)
        # Un segmento sin largo válido significa que se perdió la sincronía; sin
        # este corte el bucle avanzaría de a 2 bytes hasta el final del archivo.
        return nil if length < 2

        offset += 2 + length
      end

      nil
    end
    private_class_method :jpeg
  end
end

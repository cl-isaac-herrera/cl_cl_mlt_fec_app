# frozen_string_literal: true

module Hacienda
  # Valida el objeto unificado de un comprobante contra las reglas de negocio
  # de Hacienda, antes de generar y firmar su XML.
  #
  #   result = Hacienda::DocumentValidator.new(payload['Document'], doc_type: DocType::FE).call
  #   result.valid?   # => false
  #   result.errors   # => [#<Hacienda::DocumentValidationError …>, …]
  #
  # @param document [Hash] la clave `'Document'` del payload que arma
  #   `Documents::UnifiedBuilder` — NO el payload completo (ese también trae
  #   `DocType` y `SendDocumentHacienda`, que este validador no necesita).
  # @param doc_type [String] código de Hacienda (`DocType::FE`, `DocType::TE`,
  #   `DocType::ND`, `DocType::NC`).
  #
  # ── Origen y alcance ─────────────────────────────────────────────────────
  # Las reglas vienen de `Validations.cs#OwnValidations` del sistema .NET
  # (`legacy/apis/clvsfesync4.3/CLVS_FE.DAO/Validations.cs`), que es UN SOLO
  # método para TODOS los tipos de comprobante: recibe el `DocType` y lo usa
  # para excluir reglas puntuales, nunca para saltarse el bloque entero.
  #
  # Acá se replica esa forma. La regla de migración está en CLAUDE.md §39: una
  # regla que no aplica a un tipo se excluye DENTRO del validador, con el tipo
  # como condición — no salteándose el validador completo, que dejaría pasar
  # sin verificar todas las demás.
  #
  # ── Los siete tipos comparten casi TODAS las reglas — con una excepción ──
  # Las diferencias por tipo, todas con su constante y su cita del legacy:
  #
  #   · Identificación del receptor — exenta en TE/ND/NC, exigida en el resto
  #     (`Validations::HeaderValidator::RECEPTOR_OPCIONAL`, L324 y L329).
  #   · Código de actividad — FEC invierte cuál de los dos es obligatorio
  #     (`HeaderValidator::ACTIVIDAD_*`, L299 y L303): en FEC el contribuyente
  #     inscrito es el RECEPTOR, porque el emisor es el proveedor que no
  #     factura. REP no declara ninguno de los dos en su XSD.
  #   · Tercero en otros cargos — FEC y FEE lo PROHÍBEN en vez de exigirlo
  #     (`Validations::OtherChargeValidator::TERCERO_PROHIBIDO`, L639); REP no
  #     tiene `OtrosCargos` en absoluto.
  #   · `InformacionReferencia` — TE, FEC y FEE no la revisan por dentro; ND,
  #     NC, FEC y REP exigen que exista (`REFERENCIAS_*`, L817 y el XSD).
  #   · `DetalleServicio` — obligatorio en FEC y FEE (`LINEAS_REQUERIDAS`, L289).
  #   · REP es la ÚNICA excepción real a "todos comparten casi todas las
  #     reglas": su `ResumenFactura` no tiene la forma de una venta (sin
  #     `TotalGravado`/`TotalExento`/etc.), así que
  #     `Validations::SummaryTotalsValidator` le corre un bloque de fórmulas
  #     propio en vez del recalculo/cuadre general — ver esa clase.
  #
  # ── Por qué acumula en vez de cortar en el primer error ─────────────────
  # El legacy es fail-fast: el primer `throw` interrumpe todo, así que un
  # documento con diez problemas se corrige de a uno por intento. Acá se
  # corren TODOS los bloques y se devuelven todos los errores de una sola
  # pasada — mejor para quien tiene que corregir el documento en SAP, y no
  # cambia qué documentos pasan o no pasan: solo cuánto tarda enterarse de
  # todo lo que falta.
  #
  # ── Por qué son ocho colaboradores y no un método gigante ────────────────
  # Cada uno vive en `app/services/hacienda/validations/` y cubre un bloque
  # autocontenido del legacy (cabecera, condición de venta, líneas, otros
  # cargos, moneda, totales, referencias). Ninguno conoce a los demás; este
  # orquestador solo los llama en orden y junta lo que devuelven.
  class DocumentValidator
    # Los tipos cuyas reglas están migradas y revisadas una por una contra el
    # legacy. `Documents::Issuer` lo consulta para saber a qué comprobante
    # aplicarle este validador.
    #
    # Es exactamente lo que `Hacienda::XmlBuilder` sabe generar hoy, y no es
    # casualidad: un tipo que se pueda emitir sin poder validarse iría a
    # Hacienda a ciegas. Al agregar uno acá hay que revisar antes cada
    # exclusión por tipo de `Validations.cs` (CLAUDE.md §39).
    VALIDATED_DOC_TYPES = [DocType::FE, DocType::TE, DocType::ND, DocType::NC, DocType::FEC,
                           DocType::FEE, DocType::REP].freeze

    # Tipos cuya `InformacionReferencia` NO se revisa por dentro.
    #
    # El legacy corre ese bloque solo cuando el documento no es `01`, `04`,
    # `08` ni `09` (`Validations.cs` L817; para esos cuatro, ninguna de las dos
    # ramas da verdadero — la segunda pide `DocType == "01"` y a la vez
    # `Situacion != 1`, que es el caso de contingencia). De los tipos que este
    # producto emite hoy, eso deja fuera a TE, FEC y FEE (`09`): si traen una
    # referencia declarada, pasa sin revisarse, que es lo que hace el sistema
    # en producción.
    REFERENCIAS_NO_VALIDADAS = [DocType::TE, DocType::FEC, DocType::FEE].freeze

    # Tipos que EXIGEN al menos una `InformacionReferencia`.
    #
    # Esta regla no sale de `OwnValidations` —ahí la referencia se revisa si
    # viene, pero nadie cuenta cuántas hay— sino del XSD, que es el otro
    # validador que el legacy corre antes (`Validations.cs#ValidateXSD`, con
    # `pathNCXSD`/`pathNDXSD`/`pathFECXSD`): `InformacionReferencia` es
    # `maxOccurs="10"` sin `minOccurs`, o sea mínimo UNA, mientras que en el de
    # factura es `minOccurs="0"`.
    #
    # ⚠️ FEC está en las DOS listas, y no es una contradicción: el XSD exige
    # que la referencia ESTÉ y `OwnValidations` no revisa qué dice. Por eso la
    # presencia se verifica antes y aparte del contenido (`#validate_references`).
    #
    # Tiene sentido de negocio y por eso se replica acá en vez de dejarla para
    # el rechazo de Hacienda: una nota de crédito o de débito existe para
    # corregir OTRO comprobante, una factura de compra documenta una compra a
    # un proveedor que no factura, y un recibo de pago confirma el pago de
    # OTRA factura — sin decir a qué documento apunta, ninguna de las cuatro
    # dice de qué habla. Para REP la exige además el XSD: `InformacionReferencia`
    # no declara `minOccurs`, o sea mínimo una (a diferencia de FEE, que sí la
    # tiene `minOccurs="0"`).
    REFERENCIAS_REQUERIDAS = [DocType::ND, DocType::NC, DocType::FEC, DocType::REP].freeze

    # Tipos que EXIGEN al menos una línea de detalle.
    #
    # `Validations.cs` L289: el legacy lo pide para FEE y FEC, con ese mensaje
    # y en ese orden.
    #
    # En el resto de los tipos `DetalleServicio` es `minOccurs="0"` y un
    # comprobante sin líneas es raro pero legal; en FEC y FEE el XSD lo
    # declara obligatorio (confirmado en los dos schemas).
    LINEAS_REQUERIDAS = [DocType::FEC, DocType::FEE].freeze

    Result = Data.define(:errors) do
      def valid? = errors.empty?
    end

    # ¿Este validador cubre ese tipo de comprobante?
    def self.validates?(doc_type) = VALIDATED_DOC_TYPES.include?(doc_type)

    def initialize(document, doc_type:)
      @document = document
      @doc_type = doc_type
    end

    # @return [Hacienda::DocumentValidator::Result]
    def call
      errors = [
        *Validations::HeaderValidator.new(document, doc_type: doc_type).call,
        *Validations::SalesConditionValidator.new(document).call,
        *Validations::CurrencyValidator.new(document).call,
        *Validations::SummaryTotalsValidator.new(document, doc_type: doc_type).call,
        *validate_lines,
        *validate_other_charges,
        *validate_references
      ]

      Result.new(errors: errors)
    end

    private

    attr_reader :document, :doc_type

    def validate_lines
      lines = document['DetalleServicio'] || []
      return [lineas_requeridas] if lines.empty? && LINEAS_REQUERIDAS.include?(doc_type)

      lines.each_with_index.flat_map do |line, index|
        Validations::LineItemValidator.new(line, index + 1, doc_type: doc_type).call
      end
    end

    # El bloque entero se salta para REP (`Validations.cs` L630): ni su XSD
    # declara `OtrosCargos` ni el legacy revisa nada de eso para ese tipo.
    def validate_other_charges
      return [] if doc_type == DocType::REP

      charges = document['OtrosCargos'] || []
      charges.flat_map do |charge|
        Validations::OtherChargeValidator.new(charge, doc_type: doc_type).call
      end
    end

    # La PRESENCIA y el CONTENIDO son dos preguntas distintas, con fuentes
    # distintas (el XSD y `OwnValidations`), y hay un tipo —FEC— donde las
    # respuestas no coinciden: la referencia es obligatoria y aun así nadie
    # revisa qué dice. Por eso la presencia se resuelve ANTES del corte por
    # `REFERENCIAS_NO_VALIDADAS`; al revés, un FEC sin referencia pasaría.
    def validate_references
      references = document['InformacionReferencia'] || []
      return [referencia_requerida] if references.empty? && REFERENCIAS_REQUERIDAS.include?(doc_type)
      return [] if REFERENCIAS_NO_VALIDADAS.include?(doc_type)

      references.flat_map { |reference| Validations::ReferenceValidator.new(reference).call }
    end

    def referencia_requerida
      DocumentValidationError.new(
        message: "#{DocType.label(doc_type)} debe indicar el documento al que se refiere " \
                 'en la información de referencia.',
        field: 'InformacionReferencia'
      )
    end

    def lineas_requeridas
      DocumentValidationError.new(
        message: "#{DocType.label(doc_type)} debe llevar al menos una línea de detalle.",
        field: 'DetalleServicio'
      )
    end
  end
end

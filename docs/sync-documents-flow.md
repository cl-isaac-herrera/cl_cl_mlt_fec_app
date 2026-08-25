# Componentes
- FE Service
- Queue Database
- SAP Database
- API Hacienda

## Flujo
1. Post Transact por DB SAP inserta en Queue (y en estado "pending") documentos nuevos y documentos actualizados (no se actualiza un registro existente del documento)
2. FE Service consulta documentos en cola en estado "pending"
3. FE Service consulta detalles en SAP de documentos registrados en Queue
4. FE Service envia documentos al Ministerio de Hacienda
5. Actualiza estado del documento en Queue y a en SAP
	- Si di� error (XSD, validaciones, HTTP, etc) o rechazo de hacienda actualiza en Queue el detalle tambien
	- En SAP se actualiza la numeracion tambien (Clave y Numero consecutivo).

## Notas
1. La razon de que el Post Transact siempre inserte un nuevo registro, es para mantener historial/trazabilidad de intentos de cada documento y motivos de rechazo o error.
2. Si documento queda aceptado o rechazado en Queue el estado es "Sent" otro tipo de error es "Error".
3. FE Service se ejecutara secuencialmente y por intervalo, es decir, suponiendo un intervalo de 30 segundos, si el servicio consulta documentos para procesar, una vez procesados 
   se vuelve a ejecutar, en caso de que no encuentre se espera 30 segundos para volver a ejecutar el servicio. (el timer sera configurable)

---

## Detalles
1. En la tabla `settings` de SQL Lite hay unas configuraciones referentes a ODBC para la conexion con la base de datos externa que es donde este servicio se va a conectar para obtener documentos pendientes.
	- Ya hay una clase/logica que implementa la conexion con ODBC y toma dichas configuraciones para hacer la conexion, solo hay que utilizarla con los parametros adecuados.
	- El procedimiento almacenado que hay que consultar es el siguiente `CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS`.
	- El schema que devuelve son estos campos: Id:int, DocEntry:int, DocType:nvarchar(2), SAPDB:nvarchar(30)
2. Cuando se consulte ese procedimiento almacenado devolver N cantidad de documentos de diferentes compañías, por lo cual hay que consultar los datos de conexion de las compañías mediante match a `companies.sap_db` con `SAPDB` y luego a `connections.id` con `companies.connection_id`. Guardarlas en memoria durante el procesmiento del job, para no consultarlas por cada documento.
3. En seeds.rb debemos definir el sl_resource para consulta de detalles de documentos
	- Para datos de cabecera se llamara qsGetDocumentHeaderInfo, sera una vista la cual tendra este nombre `CL_D_CL_MLT_FEC_SLT_DOCHEADERINFO_B1SLQuery`
	- Las propiedades que devuelve son estas:
		```
		* Clave: string | Restricciones: Ninguna
		* CodigoActividadReceptor: string | Restricciones: Ninguna
		* NumeroConsecutivo: string | Restricciones: Ninguna
		* FechaEmision: string | Restricciones: Ninguna
		* CondicionVenta: string | Restricciones: Ninguna
		* CondicionVentaOtros: string | Restricciones: [MaxLength(100)]
		* PlazoCredito: int? | Restricciones: Anulable (Nullable)
		* DocEntry: int | Restricciones: Requerido (no nulo)
		* Situacion: int | Restricciones: Requerido (no nulo)
		* FechaFact: string | Restricciones: Ninguna
		* DocDate: DateTime | Restricciones: Requerido (no nulo)
		* Status: int | Restricciones: Requerido (no nulo)
		* LastTransact: DateTime | Restricciones: Requerido (no nulo)
		* ErrDetails: string | Restricciones: Ninguna
		* CompanyId: int | Restricciones: Requerido (no nulo)
		* Sucursal: int | Restricciones: Requerido (no nulo)
		* Terminal: int | Restricciones: Requerido (no nulo)
		* DocType: string | Restricciones: Ninguna
		* Consecutivo: string | Restricciones: Ninguna
		* EmsrNombre: string | Restricciones: Ninguna
		* EmsrIdeTipo: string | Restricciones: Ninguna
		* EmsrIdeNumero: string | Restricciones: Ninguna
		* EmsrNombreComercial: string | Restricciones: Ninguna
		* EmsrUbProvincia: string | Restricciones: Ninguna
		* EmsrUbCanton: string | Restricciones: Ninguna
		* EmsrUbDistrito: string | Restricciones: Ninguna
		* EmsrUbBarrio: string | Restricciones: Ninguna
		* EmsrUbOtrasSenas: string | Restricciones: Ninguna
		* EmsrTlfCodigoPais: int | Restricciones: Requerido (no nulo)
		* EmsrTlfNumTelefono: string | Restricciones: Ninguna
		* EmsrCorreoElectronico: string | Restricciones: Ninguna
		* EmsrRegistrofiscal8707: string | Restricciones: Ninguna
		* RcprNombre: string | Restricciones: Ninguna
		* RcprIdeTipo: string | Restricciones: Ninguna
		* RcprIdeNumero: string | Restricciones: Ninguna
		* RcprIdentificacionExtranjero: string | Restricciones: Ninguna
		* RcprNombreComercial: string | Restricciones: Ninguna
		* RcprUbProvincia: string | Restricciones: Ninguna
		* RcprUbCanton: string | Restricciones: Ninguna
		* RcprUbDistrito: string | Restricciones: Ninguna
		* RcprUbBarrio: string | Restricciones: Ninguna
		* RcprUbOtrasSenas: string | Restricciones: Ninguna
		* RcprOtrasSenasExtranjero: string | Restricciones: Ninguna
		* RcprTlfCodigoPais: int | Restricciones: Requerido (no nulo)
		* RcprTlfNumTelefono: string | Restricciones: Ninguna
		* RcprCorreoElectronico: string | Restricciones: Ninguna
		* RcprCorreoElectronicoCC: string | Restricciones: Ninguna
		* CodigoMoneda: string | Restricciones: Ninguna
		* TipoCambio: decimal | Restricciones: Requerido (no nulo)
		* TotalServGravados: decimal? | Restricciones: Anulable (Nullable)
		* TotalServExentos: decimal? | Restricciones: Anulable (Nullable)
		* TotalServExonerado: decimal? | Restricciones: Anulable (Nullable)
		* TotalServNoSujeto: decimal? | Restricciones: Anulable (Nullable)
		* TotalMercanciasGravadas: decimal? | Restricciones: Anulable (Nullable)
		* TotalMercanciasExentas: decimal? | Restricciones: Anulable (Nullable)
		* TotalMercExonerada: decimal? | Restricciones: Anulable (Nullable)
		* TotalMercNoSujeta: decimal? | Restricciones: Anulable (Nullable)
		* TotalGravado: decimal? | Restricciones: Anulable (Nullable)
		* TotalExento: decimal? | Restricciones: Anulable (Nullable)
		* TotalExonerado: decimal? | Restricciones: Anulable (Nullable)
		* TotalNoSujeto: decimal? | Restricciones: Anulable (Nullable)
		* TotalVenta: decimal? | Restricciones: Anulable (Nullable)
		* TotalDescuentos: decimal? | Restricciones: Anulable (Nullable)
		* TotalVentaNeta: decimal? | Restricciones: Anulable (Nullable)
		* TotalImpuesto: decimal? | Restricciones: Anulable (Nullable)
		* TotalImpAsumEmisorFabrica: decimal? | Restricciones: Anulable (Nullable)
		* TotalIVADevuelto: decimal? | Restricciones: Anulable (Nullable)
		* TotalOtrosCargos: decimal? | Restricciones: Anulable (Nullable)
		* TotalComprobante: decimal? | Restricciones: Anulable (Nullable)
		* OtroTexto: string | Restricciones: Ninguna
		* OtrosDatos: string | Restricciones: Ninguna
		* ConsecutivoId: int | Restricciones: Requerido (no nulo)
		```
4. En seeds.rb debemos definir un sl_resource para consulta de detalles de lineas de documento, es una vista (definir nombre manteniendo nomenclatura de punto anterior). Los campos que devuelve son los siguientes:
	```
	* NumeroLinea: int? | Restricciones: Anulable (Nullable)
	* Cantidad: decimal? | Restricciones: Anulable (Nullable)
	* UnidadMedida: string | Restricciones: Ninguna
	* UnidadMedidaComercial: string | Restricciones: Ninguna
	* Detalle: string | Restricciones: Ninguna
	* PrecioUnitario: decimal? | Restricciones: Anulable (Nullable)
	* MontoTotal: decimal? | Restricciones: Anulable (Nullable)
	* MontoDescuento: decimal | Restricciones: Requerido (no nulo)
	* NaturalezaDescuento: string | Restricciones: Ninguna
	* SubTotal: decimal? | Restricciones: Anulable (Nullable)
	* MontoTotalLinea: decimal? | Restricciones: Anulable (Nullable)
	* CodTipo: string | Restricciones: Ninguna
	* CodCodigo: string | Restricciones: Ninguna
	* ImpCodigo: string | Restricciones: Ninguna
	* ImpTarifa: decimal? | Restricciones: Anulable (Nullable)
	* ImpMonto: decimal? | Restricciones: Anulable (Nullable)
	* ETipoDocumento: string | Restricciones: Ninguna
	* EFechaEmision: string | Restricciones: Ninguna
	* ENumeroDocumento: string | Restricciones: Ninguna
	* ENombreInstitucion: string | Restricciones: Ninguna
	* ETarifaExonerada: decimal? | Restricciones: Anulable (Nullable)
	* EMontoExoneracion: string | Restricciones: Ninguna
	* PartidaArancelaria: string | Restricciones: Ninguna
	* Codigo: string | Restricciones: Ninguna
	* BaseImponible: decimal? | Restricciones: Anulable (Nullable)
	* ImpCodigoTarifa: string | Restricciones: Ninguna
	* ImpFactorIVA: decimal? | Restricciones: Anulable (Nullable)
	* ImpCantidadUnidadMedida: decimal? | Restricciones: Anulable (Nullable)
	* ImpPorcentaje: decimal? | Restricciones: Anulable (Nullable)
	* ImpProporcion: decimal? | Restricciones: Anulable (Nullable)
	* ImpVolumenUnidadConsumo: decimal? | Restricciones: Anulable (Nullable)
	* ImpImpuestoUnidad: decimal? | Restricciones: Anulable (Nullable)
	* ImpMontoExportacion: decimal? | Restricciones: Anulable (Nullable)
	* ImpuestoNeto: decimal? | Restricciones: Anulable (Nullable)
	* OtrosDatos: string | Restricciones: Ninguna
	* PorcentajeDescuento: decimal? | Restricciones: Anulable (Nullable)
	* TipoTransaccion: string | Restricciones: Ninguna
	* NumeroVINoSerie: string | Restricciones: Ninguna
	* IVACobradoFabrica: string | Restricciones: Ninguna
	* ImpCodigoImpuestoOTRO: string | Restricciones: Ninguna
	* ETipoDocumentoOtro: string | Restricciones: Ninguna
	* EArticulo: int? | Restricciones: Anulable (Nullable)
	* EInciso: int? | Restricciones: Anulable (Nullable)
	* ENombreInstitucionOtros: string | Restricciones: Ninguna
	* DCodigoDescuento: string | Restricciones: Ninguna
	* DCodigoDescuentoOTRO: string | Restricciones: Ninguna
	* RegistroMedicamento: string | Restricciones: Ninguna
	* FormaFarmaceutica: string | Restricciones: Ninguna
	* ImpuestoAsumidoEmisorFabrica: decimal? | Restricciones: Anulable (Nullable)
	```
5. Definir un seeds.rb de sl_resources es una vista tambien (nomenclatura anterior). Los campos que devolvera esta vista son:
	```
	* TipoDocumento: string | Restricciones: Ninguna
	* NumeroIdentidadTercero: string | Restricciones: Ninguna
	* NombreTercero: string | Restricciones: Ninguna
	* Detalle: string | Restricciones: Ninguna
	* Porcentaje: decimal? | Restricciones: Anulable (Nullable)
	* MontoCargo: decimal? | Restricciones: Anulable (Nullable)
	* TipoDocumentoOTROS: string | Restricciones: Ninguna
	* TipoIdentidadTercero: string | Restricciones: Ninguna
	```
6. Definir un seeds.rb de sl_resources (vista) para consulta de medios de pago. La consulta devolvera lo siguiente:
	```
	* TipoMedioPago: string | Restricciones: Ninguna
	* MedioPagoOtros: string | Restricciones: Ninguna
	* TotalMedioPago: decimal? | Restricciones: Anulable (Nullable)
	```
7. Definir un seeds.rb de sl_resources (vista) para consulta de informacion de referencia. La consulta devolver lo siguiente:
	```
	* InfRefTipoDoc: string | Restricciones: Ninguna
	* InfRefNumero: string | Restricciones: Valor por defecto (string.Empty)
	* InfRefFechaEmision: DateTime? | Restricciones: Anulable (Nullable)
	* InfRefCodigo: string | Restricciones: Valor por defecto (string.Empty)
	* InfRefRazon: string | Restricciones: Valor por defecto (string.Empty)
	* InfCodigoReferenciaOTRO: string | Restricciones: Ninguna
	* InfRefTipoDocRefOTRO: string | Restricciones: Ninguna
	```
8. Definir un seeds.rb de sl_resources (vista) para consulta de "Otros". La consulta devolvera lo siguiente:
	```
	* Codigo: string | Restricciones: Ninguna
	* Valor: string | Restricciones: Ninguna
	```
	- Agregar el campo `use_additional_fields:bool` en la tabla `companies` de SQL Lite
	- Validar ese campo para hacer esta consulta. Si es `true` se realiza la consulta, en caso contrario no. 
9. Solo la consulta de cabecera devolvera un registro, las demas podran devolver una lista. Por limitaciones de el uso de vistas para consultas por service layer, la consulta de cabecera tambien se devolvera en una propiedad de tipo lista, pero la lista siempre traera solo un registro. De igual forma nos vamos a dar cuenta como lo devuelve el submodulo de service layer que es el encargado de hacer las consultas.
10. Una vez obtenido toda es informacion del documento, vamos a armar un solo objeto con esa informacion, el modelo sera el siguiente:
	```
	// Document (Base / Principal)
	Document.NumeroConsecutivo = document.NumeroConsecutivo
	Document.Clave = document.Clave
	Document.ProveedorSistemas = document.ProveedorSistemas
	Document.FechaEmision = document.FechaEmision
	Document.CodigoActividadEmisor = document.CodigoActividadEmisor
	Document.CodigoActividadReceptor = document.CodigoActividadReceptor
	Document.CondicionVenta = document.CondicionVenta
	Document.CondicionVentaOtros = document.CondicionVentaOtros
	Document.PlazoCredito = document.PlazoCredito

	// Emisor
	Document.Emisor.Nombre = document.EmsrNombre
	Document.Emisor.Identificacion.Tipo = document.EmsrIdeTipo
	Document.Emisor.Identificacion.Numero = document.EmsrIdeNumero
	Document.Emisor.Registrofiscal8707 = document.EmsrRegistrofiscal8707
	Document.Emisor.NombreComercial = document.EmsrNombreComercial
	Document.Emisor.Ubicacion.Provincia = document.EmsrUbProvincia
	Document.Emisor.Ubicacion.Canton = document.EmsrUbCanton
	Document.Emisor.Ubicacion.Distrito = document.EmsrUbDistrito
	Document.Emisor.Ubicacion.Barrio = document.EmsrUbBarrio
	Document.Emisor.Ubicacion.OtrasSenas = document.EmsrUbOtrasSenas
	Document.Emisor.Telefono.CodigoPais = document.EmsrTlfCodigoPais
	Document.Emisor.Telefono.NumTelefono = document.EmsrTlfNumTelefono
	Document.Emisor.CorreoElectronico = document.EmsrCorreoElectronico

	// Receptor
	Document.Receptor.Nombre = document.RcprNombre
	Document.Receptor.Identificacion.Tipo = document.RcprIdeTipo
	Document.Receptor.Identificacion.Numero = document.RcprIdeNumero
	Document.Receptor.NombreComercial = document.RcprNombreComercial
	Document.Receptor.Ubicacion.Provincia = document.RcprUbProvincia
	Document.Receptor.Ubicacion.Canton = document.RcprUbCanton
	Document.Receptor.Ubicacion.Distrito = document.RcprUbDistrito
	Document.Receptor.Ubicacion.Barrio = document.RcprUbBarrio
	Document.Receptor.Ubicacion.OtrasSenas = document.RcprUbOtrasSenas
	Document.Receptor.Telefono.CodigoPais = document.RcprTlfCodigoPais
	Document.Receptor.Telefono.NumTelefono = document.RcprTlfNumTelefono
	Document.Receptor.CorreoElectronico = document.RcprCorreoElectronico
	Document.Receptor.OtrasSenasExtranjero = document.RcprOtrasSenasExtranjero

	// DetalleServicio (LineaDetalle)
	Document.DetalleServicio[].RegistroMedicamento = lineaDetalle.RegistroMedicamento
	Document.DetalleServicio[].FormaFarmaceutica = lineaDetalle.FormaFarmaceutica
	Document.DetalleServicio[].NumeroLinea = lineaDetalle.NumeroLinea
	Document.DetalleServicio[].CodigoCABYS = lineaDetalle.Codigo
	Document.DetalleServicio[].CodigoComercial.Tipo = lineaDetalle.CodTipo
	Document.DetalleServicio[].CodigoComercial.Codigo = lineaDetalle.CodCodigo
	Document.DetalleServicio[].Cantidad = lineaDetalle.Cantidad
	Document.DetalleServicio[].UnidadMedida = lineaDetalle.UnidadMedida
	Document.DetalleServicio[].UnidadMedidaComercial = lineaDetalle.UnidadMedidaComercial
	Document.DetalleServicio[].Detalle = lineaDetalle.Detalle
	Document.DetalleServicio[].PrecioUnitario = lineaDetalle.PrecioUnitario
	Document.DetalleServicio[].MontoTotal = lineaDetalle.MontoTotal
	Document.DetalleServicio[].Descuento.MontoDescuento = lineaDetalle.MontoDescuento
	Document.DetalleServicio[].Descuento.NaturalezaDescuento = lineaDetalle.NaturalezaDescuento
	Document.DetalleServicio[].Descuento.CodigoDescuento = lineaDetalle.DCodigoDescuento
	Document.DetalleServicio[].Descuento.CodigoDescuentoOTRO = lineaDetalle.DCodigoDescuentoOTRO
	Document.DetalleServicio[].SubTotal = lineaDetalle.SubTotal
	Document.DetalleServicio[].BaseImponible = lineaDetalle.BaseImponible
	Document.DetalleServicio[].Impuesto.Codigo = lineaDetalle.ImpCodigo
	Document.DetalleServicio[].Impuesto.CodigoTarifaIVA = lineaDetalle.ImpCodigoTarifa
	Document.DetalleServicio[].Impuesto.CodigoImpuestoOTRO = lineaDetalle.ImpCodigoImpuestoOTRO
	Document.DetalleServicio[].Impuesto.Tarifa = lineaDetalle.ImpTarifa
	Document.DetalleServicio[].Impuesto.FactorCalculoIVA = lineaDetalle.ImpFactorIVA
	Document.DetalleServicio[].Impuesto.DatosImpuestoEspecifico.ImpuestoUnidad = lineaDetalle.ImpImpuestoUnidad
	Document.DetalleServicio[].Impuesto.DatosImpuestoEspecifico.Porcentaje = lineaDetalle.ImpPorcentaje
	Document.DetalleServicio[].Impuesto.DatosImpuestoEspecifico.Proporcion = lineaDetalle.ImpProporcion
	Document.DetalleServicio[].Impuesto.DatosImpuestoEspecifico.CantidadUnidadMedida = lineaDetalle.ImpCantidadUnidadMedida
	Document.DetalleServicio[].Impuesto.DatosImpuestoEspecifico.VolumenUnidadConsumo = lineaDetalle.ImpVolumenUnidadConsumo
	Document.DetalleServicio[].Impuesto.Monto = lineaDetalle.ImpMonto
	Document.DetalleServicio[].Impuesto.Exoneracion.FechaEmisionEX = lineaDetalle.EFechaEmision
	Document.DetalleServicio[].Impuesto.Exoneracion.NombreInstitucion = lineaDetalle.ENombreInstitucion
	Document.DetalleServicio[].Impuesto.Exoneracion.TipoDocumentoEX1 = lineaDetalle.ETipoDocumento
	Document.DetalleServicio[].Impuesto.Exoneracion.TipoDocumentoOTRO = lineaDetalle.ETipoDocumentoOtro
	Document.DetalleServicio[].Impuesto.Exoneracion.NombreInstitucionOtros = lineaDetalle.ENombreInstitucionOtros
	Document.DetalleServicio[].Impuesto.Exoneracion.NumeroDocumento = lineaDetalle.ENumeroDocumento
	Document.DetalleServicio[].Impuesto.Exoneracion.MontoExoneracion = lineaDetalle.EMontoExoneracion
	Document.DetalleServicio[].Impuesto.Exoneracion.TarifaExonerada = lineaDetalle.ETarifaExonerada
	Document.DetalleServicio[].Impuesto.Exoneracion.Articulo = lineaDetalle.EArticulo
	Document.DetalleServicio[].Impuesto.Exoneracion.Inciso = lineaDetalle.EInciso

	// DetalleServicio (DetalleSurtido dentro de LineaDetalle)
	Document.DetalleServicio[].DetalleSurtido[].CodigoCABYSSurtido = surtido.CodigoCABYSSurtido
	Document.DetalleServicio[].DetalleSurtido[].CodigoComercialSurtido.TipoSurtido = surtido.CodTipoSurtido
	Document.DetalleServicio[].DetalleSurtido[].CodigoComercialSurtido.CodigoSurtido = surtido.CodCodigoSurtido
	Document.DetalleServicio[].DetalleSurtido[].CantidadSurtido = surtido.CantidadSurtido
	Document.DetalleServicio[].DetalleSurtido[].UnidadMedidaSurtido = surtido.UnidadMedidaSurtido
	Document.DetalleServicio[].DetalleSurtido[].UnidadMedidaComercialSurtido = surtido.UnidadMedidaComercialSurtido
	Document.DetalleServicio[].DetalleSurtido[].DetalleSurtido = surtido.Detalle
	Document.DetalleServicio[].DetalleSurtido[].PrecioUnitarioSurtido = surtido.PrecioUnitarioSurtido
	Document.DetalleServicio[].DetalleSurtido[].MontoTotalSurtido = surtido.MontoTotalSurtido
	Document.DetalleServicio[].DetalleSurtido[].DescuentoSurtido.MontoDescuentoSurtido = surtido.MontoDescuentoSurtido
	Document.DetalleServicio[].DetalleSurtido[].DescuentoSurtido.CodigoDescuentoSurtido = surtido.CodigoDescuentoSurtido
	Document.DetalleServicio[].DetalleSurtido[].DescuentoSurtido.DescuentoSurtidoOtros = surtido.DescuentoSurtidoOtros
	Document.DetalleServicio[].DetalleSurtido[].SubTotalSurtido = surtido.SubTotalSurtido
	Document.DetalleServicio[].DetalleSurtido[].IVACobradoFabricaSurtido = surtido.IVACobradoFabricaSurtido
	Document.DetalleServicio[].DetalleSurtido[].BaseImponibleSurtido = surtido.BaseImponibleSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.CodigoImpuestoSurtido = surtido.ImpCodigoImpuestoSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.CodigoImpuestoOTROSurtido = surtido.ImpCodigoImpuestoOTROSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.CodigoTarifaIVASurtido = surtido.ImpTarifaIVASurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.TarifaSurtido = surtido.ImpTarifaSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.DatosImpuestoEspecificoSurtido.CantidadUnidadMedidaSurtido = surtido.ImpCantidadUnidadMedidaSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.DatosImpuestoEspecificoSurtido.PorcentajeSurtido = surtido.ImpPorcentajeSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.DatosImpuestoEspecificoSurtido.ProporcionSurtido = surtido.ImpProporcionSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.DatosImpuestoEspecificoSurtido.VolumenUnidadConsumoSurtido = surtido.ImpVolumenUnidadConsumoSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.DatosImpuestoEspecificoSurtido.ImpuestoUnidadSurtido = surtido.ImpImpuestoUnidadSurtido
	Document.DetalleServicio[].DetalleSurtido[].ImpuestoSurtido.MontoImpuestoSurtido = surtido.ImpMontoSurtido

	// Propiedades finales de DetalleServicio
	Document.DetalleServicio[].MontoTotalLinea = lineaDetalle.MontoTotalLinea
	Document.DetalleServicio[].ImpuestoNeto = lineaDetalle.ImpuestoNeto
	Document.DetalleServicio[].TipoTransaccion = lineaDetalle.TipoTransaccion
	Document.DetalleServicio[].IVACobradoFabrica = lineaDetalle.IVACobradoFabrica
	Document.DetalleServicio[].NumeroVINoSerie = lineaDetalle.NumeroVINoSerie
	Document.DetalleServicio[].ImpuestoAsumidoEmisorFabrica = lineaDetalle.ImpuestoAsumidoEmisorFabrica

	// ResumenFactura
	Document.ResumenFactura.MedioPago[].TipoMedioPago = x.TipoMedioPago
	Document.ResumenFactura.MedioPago[].MedioPagoOtros = x.MedioPagoOtros
	Document.ResumenFactura.MedioPago[].TotalMedioPago = x.TotalMedioPago
	Document.ResumenFactura.CodigoTipoMoneda.CodigoMoneda = document.CodigoMoneda
	Document.ResumenFactura.CodigoTipoMoneda.TipoCambio = document.TipoCambio
	Document.ResumenFactura.TotalComprobante = document.TotalComprobante
	Document.ResumenFactura.TotalDescuentos = document.TotalDescuentos
	Document.ResumenFactura.TotalExento = document.TotalExento
	Document.ResumenFactura.TotalGravado = document.TotalGravado
	Document.ResumenFactura.TotalExonerado = document.TotalExonerado
	Document.ResumenFactura.TotalNoSujeto = document.TotalNoSujeto
	Document.ResumenFactura.TotalImpuesto = document.TotalImpuesto
	Document.ResumenFactura.TotalImpAsumEmisorFabrica = document.TotalImpAsumEmisorFabrica
	Document.ResumenFactura.TotalMercanciasExentas = document.TotalMercanciasExentas
	Document.ResumenFactura.TotalMercanciasGravadas = document.TotalMercanciasGravadas
	Document.ResumenFactura.TotalMercExonerada = document.TotalMercExonerada
	Document.ResumenFactura.TotalMercNoSujeta = document.TotalMercNoSujeta
	Document.ResumenFactura.TotalServExentos = document.TotalServExentos
	Document.ResumenFactura.TotalServGravados = document.TotalServGravados
	Document.ResumenFactura.TotalServExonerado = document.TotalServExonerado
	Document.ResumenFactura.TotalServNoSujeto = document.TotalServNoSujeto
	Document.ResumenFactura.TotalIVADevuelto = document.TotalIVADevuelto
	Document.ResumenFactura.TotalOtrosCargos = document.TotalOtrosCargos
	Document.ResumenFactura.TotalVenta = document.TotalVenta
	Document.ResumenFactura.TotalVentaNeta = document.TotalVentaNeta

	// ResumenFactura (TotalDesgloseImpuesto agrupa desde LineaDetalle / DetalleSurtido)
	Document.ResumenFactura.TotalDesgloseImpuesto[].Codigo = x.ImpCodigo // (o ds.ImpCodigoImpuestoSurtido)
	Document.ResumenFactura.TotalDesgloseImpuesto[].CodigoTarifaIVA = x.ImpCodigoTarifa // (o ds.ImpTarifaIVASurtido)
	Document.ResumenFactura.TotalDesgloseImpuesto[].TotalMontoImpuesto = x.ImpMonto // (o ds.ImpMontoSurtido * ld.Cantidad)

	// InformacionReferencia
	Document.InformacionReferencia[].TipoDocIR = x.InfRefTipoDoc
	Document.InformacionReferencia[].TipoDocRefOTRO = x.InfRefTipoDocRefOTRO
	Document.InformacionReferencia[].Numero = x.InfRefNumero
	Document.InformacionReferencia[].FechaEmisionIR = x.InfRefFechaEmision
	Document.InformacionReferencia[].Codigo = x.InfRefCodigo
	Document.InformacionReferencia[].CodigoReferenciaOTRO = x.InfCodigoReferenciaOTRO
	Document.InformacionReferencia[].Razon = x.InfRefRazon

	// Raíz de objToSend y SendDocumentHacienda
	DocType = document.DocType
	sendDocumentHacienda.fecha = document.FechaEmision
	sendDocumentHacienda.emisor.numeroIdentificacion = document.EmsrIdeNumero
	sendDocumentHacienda.emisor.tipoIdentificacion = document.EmsrIdeTipo
	sendDocumentHacienda.receptor.numeroIdentificacion = document.RcprIdeNumero
	sendDocumentHacienda.receptor.tipoIdentificacion = document.RcprIdeTipo

	// Otros
	Document.Otros[].Codigo = "Observaciones" // (Literal si existe)
	Document.Otros[].Texto = document.OtroTexto
	Document.Otros[].Codigo = x.Codigo
	Document.Otros[].Texto = x.Valor

	// OtrosCargos
	Document.OtrosCargos[].TipoDocumentoOC = x.TipoDocumento
	Document.OtrosCargos[].NombreTercero = x.NombreTercero
	Document.OtrosCargos[].Detalle = x.Detalle
	Document.OtrosCargos[].PorcentajeOC = x.Porcentaje
	Document.OtrosCargos[].MontoCargo = x.MontoCargo
	Document.OtrosCargos[].TipoDocumentoOTROS = x.TipoDocumentoOTROS
	Document.OtrosCargos[].IdentificacionTercero.Tipo = x.TipoIdentidadTercero
	Document.OtrosCargos[].IdentificacionTercero.Numero = x.NumeroIdentidadTercero

	```
	- Este objeto unificado es solo para factura electornica.
11. Los tipos de documentos son los siguientes:
	```
	public class DocTypesString
	{
		public const string FE = "01"; // Factura Electrónica
		public const string ND = "02"; // Nota de Crédito
		public const string NC = "03"; // Nota de Débito
		public const string TE = "04"; // Tiquete Electrónico
		public const string AT = "05";//Aceptacion (AT=Aceptacion total)
		public const string AP = "06";//Aceptacion parcial
		public const string RC = "07";//Rechazo
		public const string FEC = "08"; // Factura Electrónica Compra
		public const string FEE = "09"; // Factura Electrónica Exportación
		public const string REP = "10"; // Recibo Electrónico de Pago
	}
	```
	- Definirlos en una variable a nivel de global para que puedan utilizar en varios componentes de la aplicación.
12. Hasta aca esta primera parte, cuando completes esto continuaremos con lo que falta.

## Aclaraciones
- Las consultas iniciales son las mismas para todos los tipos de documentos, lo unico que cambia por tipo de documento es al generar el objeto unificado o el que se envia al Ministerio de Hacienda.
-----------------------------------FACTURA ELECTRONICA V2----------------------------------------------
IF @transaction_type in ('A') AND @object_type IN ('13', '14', '18', '24')
BEGIN
	BEGIN TRY
		DECLARE @DATABASE_CODE NVARCHAR(30) = DB_NAME();
		DECLARE @DOC_TYPE NVARCHAR(2) = (SELECT dbo.CL_D_CL_MLT_FEC_SLT_FEDOCUMENTTYPE(@object_type, @list_of_cols_val_tab_del))

		IF @DOC_TYPE <> N'00'
		BEGIN
			EXEC [CL_CL_MLT_FEC_V2_TST].dbo.CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE 
				@SAPDB = @DATABASE_CODE, 
				@DocType = @DOC_TYPE, 
				@DocEntry = @list_of_cols_val_tab_del;
		END
	END TRY
	BEGIN CATCH
		-- Captura el código de error genérico de SQL Server o asigna un código personalizado
		SET @error = ERROR_NUMBER();
			
		-- Captura el mensaje detallado de la excepción
		SET @error_message = N'Error en Factura Electrónica V2: ' + ERROR_MESSAGE();
	END CATCH
END
-----------------------------------FIN FACTURA ELECTRONICA V2------------------------------------------
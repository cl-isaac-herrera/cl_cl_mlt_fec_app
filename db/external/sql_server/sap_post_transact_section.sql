-----------------------------------FACTURA ELECTRONICA V2----------------------------------------------
IF @transaction_type in ('A') AND @object_type IN ('13', '14', '18', '24')
BEGIN
	DECLARE @DATABASE_CODE NVARCHAR(30) = DB_NAME();

	BEGIN TRY
		IF @object_type = '13'
		BEGIN
			DECLARE @DOC_TYPE NVARCHAR(2) = (SELECT 
				CASE 
					WHEN Series = '72' THEN N'01' --Factura normal
					WHEN Series = '75' THEN N'02' --Nota débito
					WHEN Series = '77' THEN N'09' --Factura exportación
					WHEN Series = '73' THEN N'04' --Tiquete electrónico
					ELSE N'00'
				END
			FROM OINV WHERE DocEntry = @list_of_cols_val_tab_del);


			IF @DOC_TYPE <> N'00'
			BEGIN
				EXEC [CL_CL_MLT_FEC_V2_TST].dbo.CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE 
					@SAPDB = @DATABASE_CODE, 
					@DocType = @DOC_TYPE, 
					@DocEntry = @list_of_cols_val_tab_del;
			END

		END
		ELSE IF @object_type = '14' AND EXISTS (SELECT 1 FROM ORIN WHERE Series = '74' AND DocEntry = @list_of_cols_val_tab_del)
		BEGIN
			EXEC [CL_CL_MLT_FEC_V2_TST].dbo.CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE 
				@SAPDB = @DATABASE_CODE, 
				@DocType = N'03', 
				@DocEntry = @list_of_cols_val_tab_del;
		END
		ELSE IF @object_type = '18' AND EXISTS (SELECT 1 FROM OPCH WHERE Series = '76' AND DocEntry = @list_of_cols_val_tab_del)
		BEGIN
			EXEC [CL_CL_MLT_FEC_V2_TST].dbo.CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE 
				@SAPDB = @DATABASE_CODE, 
				@DocType = N'08', 
				@DocEntry = @list_of_cols_val_tab_del;
		END
		ELSE IF @object_type = '24' AND EXISTS (SELECT TOP(1) 1 
			FROM ORCT payment 
			LEFT JOIN RCT2 paymentLine ON payment.DocEntry = paymentLine.DocNum 
			LEFT JOIN OINV invoice ON paymentLine.DocEntry = invoice.DocEntry 
			WHERE payment.Series = '76' 
				AND payment.DocEntry = @list_of_cols_val_tab_del 
				AND invoice.U_CondicionVenta IN ('08', '10'))
		BEGIN
			EXEC [CL_CL_MLT_FEC_V2_TST].dbo.CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE 
				@SAPDB = @DATABASE_CODE, 
				@DocType = N'10', 
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
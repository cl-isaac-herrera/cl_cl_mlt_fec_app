CREATE FUNCTION dbo.CL_D_CL_MLT_FEC_SLT_FEDOCUMENTTYPE
(
	@SAPObjectType NVARCHAR(30),
	@DocEntry INT
)
RETURNS NVARCHAR(2)
AS
BEGIN
	DECLARE @docType NVARCHAR(2);

	IF @SAPObjectType = '13'
	BEGIN
		SET @docType = (SELECT 
			CASE 
				WHEN Series = '72' THEN N'01' --Factura normal
				WHEN Series = '75' THEN N'02' --Nota débito
				WHEN Series = '77' THEN N'09' --Factura exportación
				WHEN Series = '73' THEN N'04' --Tiquete electrónico
				ELSE N'00'
			END
		FROM OINV WHERE DocEntry = @DocEntry);
	END
	ELSE IF @SAPObjectType = '14' AND EXISTS (SELECT 1 FROM ORIN WHERE Series = '74' AND DocEntry = @DocEntry)
	BEGIN
		SET @docType = N'03';
	END
	ELSE IF @SAPObjectType = '18' AND EXISTS (SELECT 1 FROM OPCH WHERE Series = '76' AND DocEntry = @DocEntry)
	BEGIN
		SET @docType = N'08';
	END
	ELSE IF @SAPObjectType = '24' AND EXISTS (SELECT TOP(1) 1 
		FROM ORCT payment 
		LEFT JOIN RCT2 paymentLine ON payment.DocEntry = paymentLine.DocNum 
		LEFT JOIN OINV invoice ON paymentLine.DocEntry = invoice.DocEntry 
		WHERE payment.Series = '76' 
			AND payment.DocEntry = @DocEntry 
			AND invoice.U_CondicionVenta IN ('08', '10'))
	BEGIN
		SET @docType = N'10';
	END
	ELSE
	BEGIN
		SET @docType = N'00';
	END

	RETURN @docType;
END
GO
-- 1. Tabla Catálogo de Estados (PK Tinyint Manual)
CREATE TABLE dbo.StatusCodes (
    Code TINYINT NOT NULL,
    [Name] VARCHAR(20) NOT NULL,
    [Description] VARCHAR(255) NOT NULL,
    CONSTRAINT PK_StatusCodes PRIMARY KEY CLUSTERED (Code)
);

-- Inserción de Estados
INSERT INTO StatusCodes (Code, [Name], [Description]) VALUES
(0, 'Pending',    'Documento registrado por SAP, listo para ser procesado.'),
(1, 'OnHold',     'En espera por conflicto de concurrencia (un intento anterior del mismo documento está en Processing).'),
(2, 'Processing', 'Documento en proceso activo de consulta, validación o envío a Hacienda.'),
(3, 'Sent',       'Documento procesado y enviado a Hacienda exitosamente.'),
(4, 'Error',      'Fallo de validación o error técnico.'),
(5, 'Cancelled',  'Documento descartado u omitido porque un intento previo ya finalizó con éxito.');

-- 2. Tabla Principal de Cola de Documentos
CREATE TABLE dbo.DocumentsQueue (
    Id BIGINT IDENTITY(1,1) NOT NULL,
    DocEntry INT NOT NULL,
    DocType NVARCHAR(2) NOT NULL,
    SAPDB NVARCHAR(30) NOT NULL,
    StatusCode TINYINT NOT NULL DEFAULT 0,
    Details NVARCHAR(MAX) NULL,
    CreatedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedAt DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
    
    CONSTRAINT PK_DocumentsQueue PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_DocumentsQueue_StatusCodes FOREIGN KEY (StatusCode) REFERENCES StatusCodes (Code)
);

-- 3. Índices de Rendimiento

-- Optimiza la lectura de documentos pendientes/encolados por el FE Service
CREATE NONCLUSTERED INDEX IX_DocumentsQueue_Polling
ON DocumentsQueue (SAPDB, StatusCode, Id)
INCLUDE (DocEntry, DocType);

-- Optimiza la búsqueda de historial/trazabilidad por documento
CREATE NONCLUSTERED INDEX IX_DocumentsQueue_DocLookup
ON DocumentsQueue (SAPDB, DocType, DocEntry, CreatedAt DESC);


/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE]    Script Date: 24/8/2026 16:18:55 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE] 
	@SAPDB NVARCHAR(30),
	@DocEntry INT,
	@DocType NVARCHAR(2)
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @statusCode TINYINT = 1;

	IF EXISTS (SELECT TOP(1) 1 FROM dbo.DocumentsQueue WHERE SAPDB = @SAPDB AND DocEntry = @DocEntry AND DocType = @DocType AND StatusCode = 2 ORDER BY Id DESC)
	BEGIN
		/*
			Se guarda en estado OnHold debido a que no sabemos si el documento duplicado que esta en estado Processing se procesara correctamente, por lo cual
			no podemos dejarlo en "Pending" provocando que otro proceso lo tome y lo procese duplicado.
		*/
		
		INSERT dbo.DocumentsQueue (DocEntry, DocType, SAPDB, StatusCode, CreatedAt, UpdatedAt)
		VALUES (@DocEntry, @DocType, @SAPDB, 1, GETDATE(), GETDATE());
	END
	ELSE IF NOT EXISTS (SELECT TOP(1) 1 FROM dbo.DocumentsQueue WHERE SAPDB = @SAPDB AND DocEntry = @DocEntry AND DocType = @DocType AND StatusCode NOT IN (0,3) ORDER BY Id DESC)
	BEGIN
		INSERT dbo.DocumentsQueue (DocEntry, DocType, SAPDB, StatusCode, CreatedAt, UpdatedAt)
		VALUES (@DocEntry, @DocType, @SAPDB, 0, GETDATE(), GETDATE());
	END
    
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS]    Script Date: 24/8/2026 16:18:55 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    UPDATE dbo.DocumentsQueue SET
		StatusCode = 2,
		UpdatedAt = GETDATE()
	OUTPUT
		inserted.Id,
		inserted.DocEntry,
		inserted.DocType,
		inserted.SAPDB
	WHERE StatusCode = 0 
		OR (StatusCode = 2 AND UpdatedAt <= DATEADD(MINUTE, -10, GETDATE()));
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_UPT_DOCUMENT]    Script Date: 24/8/2026 16:18:55 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_UPT_DOCUMENT]
	@Id INT,
	@DocEntry INT,
	@DocType NVARCHAR(2),
	@SAPDB NVARCHAR(30),
	@Details NVARCHAR(MAX),
	@StatusCode TINYINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	UPDATE dbo.DocumentsQueue SET
		StatusCode = @StatusCode,
		Details = @Details,
		UpdatedAt = GETDATE()
	WHERE Id = @Id;

	IF @StatusCode = 3
	BEGIN
		UPDATE dbo.DocumentsQueue SET
			StatusCode = 5,
			Details = 'Este documento ya fué procesado exitosamente.',
			UpdatedAt = GETDATE()
		WHERE SAPDB = @SAPDB AND DocEntry = @DocEntry AND DocType = @DocType AND StatusCode = 1;
	END
	ELSE IF @StatusCode = 4
	BEGIN
		UPDATE dbo.DocumentsQueue SET
			StatusCode = 0,
			Details = NULL,
			UpdatedAt = GETDATE()
		WHERE SAPDB = @SAPDB AND DocEntry = @DocEntry AND DocType = @DocType AND StatusCode = 1;
	END
END
GO

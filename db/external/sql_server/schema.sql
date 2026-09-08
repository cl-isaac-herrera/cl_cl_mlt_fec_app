/****** Object:  Table [dbo].[DocTypes]    Script Date: 6/9/2026 13:32:31 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DocTypes](
	[Code] [nvarchar](2) NOT NULL,
	[Name] [varchar](10) NOT NULL,
	[Description] [varchar](255) NOT NULL,
 CONSTRAINT [PK_DocTypes] PRIMARY KEY CLUSTERED 
(
	[Code] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DocumentAttemptDetails]    Script Date: 6/9/2026 13:32:32 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DocumentAttemptDetails](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[DocumentQueueId] [bigint] NOT NULL,
	[StatusCode] [tinyint] NOT NULL,
	[Details] [nvarchar](max) NULL,
	[CreatedAt] [datetime2](3) NOT NULL,
 CONSTRAINT [PK_DocumentAttemptDetails] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DocumentsQueue]    Script Date: 6/9/2026 13:32:32 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DocumentsQueue](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[DocEntry] [int] NOT NULL,
	[DocType] [nvarchar](2) NOT NULL,
	[SAPDB] [nvarchar](30) NOT NULL,
	[StatusCode] [tinyint] NOT NULL,
	[CreatedAt] [datetime2](3) NOT NULL,
	[UpdatedAt] [datetime2](3) NOT NULL,
	[Attempts] [tinyint] NOT NULL,
 CONSTRAINT [PK_DocumentsQueue] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[StatusCodes]    Script Date: 6/9/2026 13:32:32 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[StatusCodes](
	[Code] [tinyint] NOT NULL,
	[Name] [varchar](20) NOT NULL,
	[Description] [varchar](255) NOT NULL,
 CONSTRAINT [PK_StatusCodes] PRIMARY KEY CLUSTERED 
(
	[Code] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'01', N'FE', N'Factura electrónica')
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'02', N'ND', N'Nota de débito electrónica')
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'03', N'NC', N'Nota de crédito electrónica')
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'04', N'TE', N'Tiquete electrónico')
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'08', N'FEC', N'Factura electrónica de compra')
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'09', N'FEE', N'Factura electrónica de exportación')
GO
INSERT [dbo].[DocTypes] ([Code], [Name], [Description]) VALUES (N'10', N'REP', N'Recibo electrónico de pago')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (0, N'Pending', N'Documento registrado por SAP, listo para ser procesado.')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (2, N'Processing', N'Documento en proceso activo de consulta, validación o envío a Hacienda.')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (3, N'Sent', N'Documento procesado y enviado a Hacienda exitosamente.')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (4, N'Error', N'Fallo de validación o error técnico.')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (6, N'Accepted', N'Hacienda aceptó el comprobante.')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (7, N'Rejected', N'Hacienda rechazó el comprobante.')
GO
INSERT [dbo].[StatusCodes] ([Code], [Name], [Description]) VALUES (8, N'Reprocess', N'Reprocesamiento solicitado por el usuario sobre un documento rechazado.')
GO
ALTER TABLE [dbo].[DocumentAttemptDetails] ADD  DEFAULT ((0)) FOR [StatusCode]
GO
ALTER TABLE [dbo].[DocumentAttemptDetails] ADD  DEFAULT (sysdatetime()) FOR [CreatedAt]
GO
ALTER TABLE [dbo].[DocumentsQueue] ADD  DEFAULT ((0)) FOR [StatusCode]
GO
ALTER TABLE [dbo].[DocumentsQueue] ADD  DEFAULT (sysdatetime()) FOR [CreatedAt]
GO
ALTER TABLE [dbo].[DocumentsQueue] ADD  DEFAULT (sysdatetime()) FOR [UpdatedAt]
GO
ALTER TABLE [dbo].[DocumentsQueue] ADD  CONSTRAINT [DF_DocumentsQueue_Attempts]  DEFAULT ((0)) FOR [Attempts]
GO
ALTER TABLE [dbo].[DocumentAttemptDetails]  WITH CHECK ADD  CONSTRAINT [FK_DocumentAttemptDetails_DocumentsQueue] FOREIGN KEY([DocumentQueueId])
REFERENCES [dbo].[DocumentsQueue] ([Id])
GO
ALTER TABLE [dbo].[DocumentAttemptDetails] CHECK CONSTRAINT [FK_DocumentAttemptDetails_DocumentsQueue]
GO
ALTER TABLE [dbo].[DocumentsQueue]  WITH CHECK ADD  CONSTRAINT [FK_DocumentsQueue_DocTypes] FOREIGN KEY([DocType])
REFERENCES [dbo].[DocTypes] ([Code])
GO
ALTER TABLE [dbo].[DocumentsQueue] CHECK CONSTRAINT [FK_DocumentsQueue_DocTypes]
GO
ALTER TABLE [dbo].[DocumentsQueue]  WITH CHECK ADD  CONSTRAINT [FK_DocumentsQueue_StatusCodes] FOREIGN KEY([StatusCode])
REFERENCES [dbo].[StatusCodes] ([Code])
GO
ALTER TABLE [dbo].[DocumentsQueue] CHECK CONSTRAINT [FK_DocumentsQueue_StatusCodes]
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE]    Script Date: 6/9/2026 13:32:32 ******/
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

	IF NOT EXISTS (SELECT 1 FROM dbo.DocumentsQueue WHERE SAPDB = @SAPDB AND DocEntry = @DocEntry AND DocType = @DocType)
	BEGIN
		INSERT dbo.DocumentsQueue (DocEntry, DocType, SAPDB, StatusCode, CreatedAt, UpdatedAt)
		VALUES (@DocEntry, @DocType, @SAPDB, 0, GETDATE(), GETDATE());
	END
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGCHECKDOCUMENTS]    Script Date: 6/9/2026 13:32:32 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGCHECKDOCUMENTS]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	SELECT 
		Id,
		DocEntry,
		DocType,
		SAPDB
	FROM dbo.DocumentsQueue
	WHERE StatusCode = 3 
	AND UpdatedAt <= DATEADD(SECOND, 5, GETDATE());
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS]    Script Date: 6/9/2026 13:32:32 ******/
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
		OR (StatusCode = 2 AND UpdatedAt <= DATEADD(MINUTE, -10, GETDATE()))
		OR (StatusCode = 4 AND DATEDIFF(MINUTE, UpdatedAt, GETDATE()) >= POWER(2, Attempts))
		OR StatusCode = 8
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_UPT_DOCUMENT]    Script Date: 6/9/2026 13:32:32 ******/
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
		UpdatedAt = GETDATE(),
		Attempts = Attempts + 1
	WHERE Id = @Id;

	INSERT INTO dbo.DocumentAttemptDetails (DocumentQueueId, CreatedAt, Details, StatusCode)
	VALUES (@Id, GETDATE(), @Details, @StatusCode);
END
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_SLT_DOCUMENTATTEMPS]
	@SAPDB NVARCHAR(30),
	@DocEntry INT,
	@DocType NVARCHAR(2)
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	SELECT
		docAttemps.CreatedAt,
		docAttemps.Details,
		docAttemps.StatusCode
	FROM dbo.DocumentsQueue doc
	JOIN dbo.DocumentAttemptDetails docAttemps ON doc.Id = docAttemps.DocumentQueueId
	WHERE doc.SAPDB = @SAPDB
	AND doc.DocEntry = @DocEntry
	AND doc.DocType = @DocType
	ORDER BY docAttemps.CreatedAt DESC;
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_UPT_REPROCESSDOCUMENT] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- Reencola un documento Rechazado para que `CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS`
-- lo vuelva a tomar. La validación vive ACÁ, no en Rails: solo se reencola si la
-- fila sigue en StatusCode = 7 (Rejected) en el momento del UPDATE — evita la
-- carrera de reprocesar dos veces el mismo documento desde dos pestañas, y evita
-- que un documento que ya cambió de estado (lo tomó otra corrida, o Hacienda ya
-- contestó distinto) se reencole igual.
--
-- @Details llega ya armado desde Rails ("Reprocesamiento solicitado por <usuario>")
-- y se guarda tal cual en DocumentAttemptDetails, igual que cualquier otro intento.
--
-- Devuelve el Id de la fila reencolada cuando sí aplicó, o ningún registro cuando
-- el documento no existe en la cola o no estaba Rechazado — así el llamador
-- distingue "se reencoló" de "no había nada que reencolar" sin adivinar.
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_UPT_REPROCESSDOCUMENT]
	@DocEntry INT,
	@SAPDB NVARCHAR(30),
	@DocType NVARCHAR(2),
	@Details NVARCHAR(MAX)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @Reprocessed TABLE (Id BIGINT);

	UPDATE dbo.DocumentsQueue SET
		StatusCode = 8,
		UpdatedAt = GETDATE()
	OUTPUT inserted.Id INTO @Reprocessed
	WHERE DocEntry = @DocEntry
		AND SAPDB = @SAPDB
		AND DocType = @DocType
		AND StatusCode = 7;

	IF EXISTS (SELECT 1 FROM @Reprocessed)
	BEGIN
		INSERT INTO dbo.DocumentAttemptDetails (DocumentQueueId, CreatedAt, Details, StatusCode)
		SELECT Id, GETDATE(), @Details, 8 FROM @Reprocessed;
	END

	SELECT Id FROM @Reprocessed;
END
GO

/****** Object:  Table [dbo].[OutgoingMailsQueue] ******/
-- Cola de correos de recepción electrónica pendientes de envío
-- (`Documents::MailQueue` / `SendElectronicReceiptJob`). Analogía de
-- `DocumentsQueue` para el correo, pero deliberadamente más chica: sin tabla
-- de historial de intentos (`DocumentAttemptDetails`) — el detalle de cada
-- intento vive en la UDT de SAP (`U_Details`, `@CL_FEC_MAILSQUEUE`), no acá.
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[OutgoingMailsQueue](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[DocEntry] [int] NOT NULL,
	[DocType] [nvarchar](2) NOT NULL,
	[SAPDB] [nvarchar](30) NOT NULL,
	[Status] [tinyint] NOT NULL,
	[Attempts] [tinyint] NOT NULL,
	[CreatedAt] [datetime2](3) NOT NULL,
	[UpdatedAt] [datetime2](3) NOT NULL,
 CONSTRAINT [PK_OutgoingMailsQueue] PRIMARY KEY CLUSTERED
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
ALTER TABLE [dbo].[OutgoingMailsQueue] ADD  CONSTRAINT [DF_OutgoingMailsQueue_Status] DEFAULT ((1)) FOR [Status]
GO
ALTER TABLE [dbo].[OutgoingMailsQueue] ADD  CONSTRAINT [DF_OutgoingMailsQueue_Attempts] DEFAULT ((0)) FOR [Attempts]
GO
ALTER TABLE [dbo].[OutgoingMailsQueue] ADD  CONSTRAINT [DF_OutgoingMailsQueue_CreatedAt] DEFAULT (sysdatetime()) FOR [CreatedAt]
GO
ALTER TABLE [dbo].[OutgoingMailsQueue] ADD  CONSTRAINT [DF_OutgoingMailsQueue_UpdatedAt] DEFAULT (sysdatetime()) FOR [UpdatedAt]
GO
-- Catálogo (1 Pendiente, 2 Enviando, 3 Error, 4 Enviado, 5 Omitido) — el mismo
-- que `U_Status` de la UDT (`config/sap_schemas/outgoing_mails_udt.json`).
-- ⚠️ Una instalación YA viva necesita un ALTER manual para pasar de (1,2,3,4)
-- a (1,2,3,4,5) — este script es la referencia para una base nueva, no se
-- aplica solo (ver `TODOS.md` → Emisión de documentos).
ALTER TABLE [dbo].[OutgoingMailsQueue] WITH CHECK ADD CONSTRAINT [CK_OutgoingMailsQueue_Status] CHECK ([Status] IN (1,2,3,4,5))
GO
ALTER TABLE [dbo].[OutgoingMailsQueue] CHECK CONSTRAINT [CK_OutgoingMailsQueue_Status]
GO
ALTER TABLE [dbo].[OutgoingMailsQueue]  WITH CHECK ADD  CONSTRAINT [FK_OutgoingMailsQueue_DocTypes] FOREIGN KEY([DocType])
REFERENCES [dbo].[DocTypes] ([Code])
GO
ALTER TABLE [dbo].[OutgoingMailsQueue] CHECK CONSTRAINT [FK_OutgoingMailsQueue_DocTypes]
GO
-- Optimiza la lectura de correos pendientes por `CL_D_CL_MLT_FEC_SLT_PENDINGMAILS`.
CREATE NONCLUSTERED INDEX [IX_OutgoingMailsQueue_Polling] ON [dbo].[OutgoingMailsQueue]
(
	[SAPDB] ASC,
	[Status] ASC,
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
-- Optimiza el dedupe de `CL_D_CL_MLT_FEC_CRT_MAILTOQUEUE` (¿ya hay una fila
-- sin terminar para este documento?).
CREATE NONCLUSTERED INDEX [IX_OutgoingMailsQueue_DocLookup] ON [dbo].[OutgoingMailsQueue]
(
	[SAPDB] ASC,
	[DocType] ASC,
	[DocEntry] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_CRT_MAILTOQUEUE] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- Encola el envío del correo de recepción, DESPUÉS de registrar la fila en la
-- UDT (`Sap::MailQueue#create`, ver `CheckSentDocumentsJob#queue_receipt_mail`).
-- No duplica mientras exista una fila sin terminar (Status <> 4) para el mismo
-- documento — un documento solo se resuelve una vez, pero la validación queda
-- acá igual que `CL_D_CL_MLT_FEC_CRT_DOCUMENTTOQUEUE` se protege por su cuenta.
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_CRT_MAILTOQUEUE]
	@SAPDB NVARCHAR(30),
	@DocEntry INT,
	@DocType NVARCHAR(2)
AS
BEGIN
	SET NOCOUNT ON;

	IF NOT EXISTS (
		SELECT 1 FROM dbo.OutgoingMailsQueue
		WHERE SAPDB = @SAPDB AND DocEntry = @DocEntry AND DocType = @DocType AND Status <> 4
	)
	BEGIN
		INSERT dbo.OutgoingMailsQueue (DocEntry, DocType, SAPDB, Status, Attempts, CreatedAt, UpdatedAt)
		VALUES (@DocEntry, @DocType, @SAPDB, 1, 0, GETDATE(), GETDATE());
	END
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGMAILS] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- Reclama los correos pendientes (1), los que quedaron colgados en Enviando
-- (2) por más de diez minutos, o los que fallaron (3) y ya cumplieron su
-- backoff exponencial — MISMO criterio que
-- `CL_D_CL_MLT_FEC_SLT_PENDINGDOCUMENTS`.
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_SLT_PENDINGMAILS]
AS
BEGIN
	SET NOCOUNT ON;

	UPDATE dbo.OutgoingMailsQueue SET
		Status = 2,
		UpdatedAt = GETDATE()
	OUTPUT
		inserted.Id,
		inserted.DocEntry,
		inserted.DocType,
		inserted.SAPDB
	WHERE Status = 1
		OR (Status = 2 AND UpdatedAt <= DATEADD(MINUTE, -10, GETDATE()))
		OR (Status = 3 AND DATEDIFF(MINUTE, UpdatedAt, GETDATE()) >= POWER(2, Attempts))
END
GO
/****** Object:  StoredProcedure [dbo].[CL_D_CL_MLT_FEC_UPT_MAIL] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- Actualiza el desenlace de un intento de envío: estado, intentos y fecha del
-- último intento. Sin historial de intentos (a diferencia de DocumentsQueue):
-- el detalle de cada intento vive en la UDT (U_Details), no acá.
CREATE PROCEDURE [dbo].[CL_D_CL_MLT_FEC_UPT_MAIL]
	@Id BIGINT,
	@StatusCode TINYINT
AS
BEGIN
	SET NOCOUNT ON;

	UPDATE dbo.OutgoingMailsQueue SET
		Status = @StatusCode,
		Attempts = Attempts + 1,
		UpdatedAt = GETDATE()
	WHERE Id = @Id;
END
GO
/* =====================================================================
   08_respaldo_y_restauracion.sql  -  E5. Respaldo y recuperacion (Unidad III)
   Ejecutar BLOQUE POR BLOQUE en la MISMA ventana de SSMS (la hora marcada se
   guarda en la tabla temporal global ##Marca, que vive mientras la sesion
   este abierta). La cuenta del servicio de SQL Server debe poder escribir
   en C:\Backups\BusRD\. Requiere 02_sp_VenderBoleto.sql.
   CONFIGURACION: @ViajeID = viaje asignado (debe estar 'Programado' para vender).
   ===================================================================== */

/* ---------------------------------------------------------------------
   0. Modelo de recuperacion FULL
   Por que: con SIMPLE el log se trunca solo en cada checkpoint y NO se
   pueden hacer backups de log ni restaurar a un punto en el tiempo (STOPAT);
   solo se podria volver al ultimo full/diferencial, perdiendo todas las
   ventas posteriores. En un sistema que vende boletos todo el dia, eso es
   inaceptable. FULL conserva el log hasta que se respalde.
   --------------------------------------------------------------------- */
USE master;
GO
EXEC master.sys.xp_create_subdir N'C:\Backups\BusRD\';
ALTER DATABASE BusRD SET RECOVERY FULL;
SELECT name, recovery_model_desc FROM sys.databases WHERE name = 'BusRD';
GO

-- Tabla de apoyo para identificar los boletos vendidos durante la prueba
USE BusRD;
GO
IF OBJECT_ID('dbo.Demo_Respaldo') IS NULL
    CREATE TABLE dbo.Demo_Respaldo(BoletoID INT PRIMARY KEY, Fase VARCHAR(20) NOT NULL);
GO

/* ---------------------------------------------------------------------
   1. BACKUP FULL (inicia la cadena de log)
   --------------------------------------------------------------------- */
BACKUP DATABASE BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_full.bak'
WITH INIT, CHECKSUM, STATS = 10, NAME = 'BusRD Full';
GO

/* ---------------------------------------------------------------------
   2. Vender 5 boletos
   --------------------------------------------------------------------- */
USE BusRD;
DECLARE @ViajeID INT = 16000;                        -- <<< viaje asignado
DECLARE @i INT = 1, @A INT, @B INT;
WHILE @i <= 5
BEGIN
    SELECT TOP 1 @A = s.NumeroAsiento
    FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.ViajeID = @ViajeID
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.ViajeID = v.ViajeID
                      AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
    ORDER BY s.NumeroAsiento;

    EXEC dbo.sp_VenderBoleto @ViajeID = @ViajeID, @NumeroAsiento = @A, @ClienteID = 100 + @i,
         @Canal = 'Taquilla', @Metodo = 'Efectivo', @BoletoID = @B OUTPUT;
    INSERT dbo.Demo_Respaldo(BoletoID, Fase) VALUES (@B, 'POST_FULL');
    SET @i += 1;
END
SELECT * FROM dbo.Demo_Respaldo;
GO

/* ---------------------------------------------------------------------
   3. BACKUP DIFERENCIAL
   --------------------------------------------------------------------- */
BACKUP DATABASE BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_diff.bak'
WITH DIFFERENTIAL, INIT, CHECKSUM, STATS = 10, NAME = 'BusRD Diferencial';
GO

/* ---------------------------------------------------------------------
   4. Vender 3 boletos
   --------------------------------------------------------------------- */
USE BusRD;
DECLARE @ViajeID INT = 16000;                        -- <<< viaje asignado
DECLARE @i INT = 1, @A INT, @B INT;
WHILE @i <= 3
BEGIN
    SELECT TOP 1 @A = s.NumeroAsiento
    FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
    WHERE v.ViajeID = @ViajeID
      AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.ViajeID = v.ViajeID
                      AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
    ORDER BY s.NumeroAsiento;

    EXEC dbo.sp_VenderBoleto @ViajeID = @ViajeID, @NumeroAsiento = @A, @ClienteID = 200 + @i,
         @Canal = 'Web', @Metodo = 'Tarjeta', @BoletoID = @B OUTPUT;
    INSERT dbo.Demo_Respaldo(BoletoID, Fase) VALUES (@B, 'POST_DIFF');
    SET @i += 1;
END
SELECT Fase, COUNT(*) AS Boletos FROM dbo.Demo_Respaldo GROUP BY Fase;   -- 5 y 3
GO

/* ---------------------------------------------------------------------
   5. BACKUP de LOG
   --------------------------------------------------------------------- */
BACKUP LOG BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_log1.trn'
WITH INIT, CHECKSUM, STATS = 10, NAME = 'BusRD Log 1';
GO

/* ---------------------------------------------------------------------
   6. ANOTAR LA HORA EXACTA (justo antes del "error")
   Anotar en el informe el valor de HoraAntesDelDelete.
   --------------------------------------------------------------------- */
USE BusRD;
IF OBJECT_ID('tempdb..##Marca') IS NOT NULL DROP TABLE ##Marca;
DECLARE @ViajeID INT = 16000;                        -- <<< viaje asignado
SELECT GETDATE() AS HoraAntesDelDelete,
       (SELECT COUNT(*) FROM dbo.Boletos WHERE ViajeID = @ViajeID) AS BoletosViajeAntes
INTO ##Marca;
SELECT * FROM ##Marca;
WAITFOR DELAY '00:00:03';     -- margen para que el DELETE quede claramente despues
GO

/* ---------------------------------------------------------------------
   7. SIMULAR EL ERROR: borrar todos los boletos del viaje asignado
   Los pagos se borran primero porque FK_Pagos_Boletos impide borrar boletos con pagos.
   --------------------------------------------------------------------- */
USE BusRD;
DECLARE @ViajeID INT = 16000;                        -- <<< viaje asignado
BEGIN TRANSACTION;
    DELETE p FROM dbo.Pagos p JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID WHERE b.ViajeID = @ViajeID;
    DELETE FROM dbo.Boletos WHERE ViajeID = @ViajeID;
COMMIT TRANSACTION;
SELECT COUNT(*) AS BoletosViajeDespuesDelDelete FROM dbo.Boletos WHERE ViajeID = @ViajeID;   -- 0
GO

/* ---------------------------------------------------------------------
   8. BACKUP de LOG de cola (tail-log): captura el DELETE y todo lo anterior.
   En un desastre real con la BD danada se usaria WITH NO_TRUNCATE / NORECOVERY;
   aqui la BD sigue sana y la restauracion va a una base NUEVA, por eso es un
   backup de log normal.
   --------------------------------------------------------------------- */
BACKUP LOG BusRD
TO DISK = N'C:\Backups\BusRD\BusRD_log_cola.trn'
WITH INIT, CHECKSUM, STATS = 10, NAME = 'BusRD Log Cola';
GO

/* ---------------------------------------------------------------------
   9. RESTAURAR en BusRD_Recuperada hasta un momento ANTES del DELETE
   Cadena: FULL (NORECOVERY) -> DIFF (NORECOVERY) -> LOG1 (NORECOVERY)
           -> LOG COLA con STOPAT (RECOVERY)
   Si ##Marca no existe (otra sesion), poner la hora a mano en @StopAt.
   --------------------------------------------------------------------- */
USE master;
GO
IF DB_ID('BusRD_Recuperada') IS NOT NULL
BEGIN
    ALTER DATABASE BusRD_Recuperada SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BusRD_Recuperada;
END
GO

-- (opcional) ver nombres logicos de archivos: deben ser BusRD y BusRD_log
RESTORE FILELISTONLY FROM DISK = N'C:\Backups\BusRD\BusRD_full.bak';
GO

DECLARE @StopAt DATETIME = (SELECT HoraAntesDelDelete FROM ##Marca);
-- SET @StopAt = '2026-10-28T15:30:00';              -- <<< alternativa manual
SELECT @StopAt AS RestaurandoHasta;

DECLARE @data NVARCHAR(260) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(260));
DECLARE @log  NVARCHAR(260) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS NVARCHAR(260));
DECLARE @sql  NVARCHAR(MAX) =
    N'RESTORE DATABASE BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_full.bak'' ' +
    N'WITH MOVE N''BusRD'' TO N''' + @data + N'BusRD_Recuperada.mdf'', ' +
    N'MOVE N''BusRD_log'' TO N''' + @log + N'BusRD_Recuperada_log.ldf'', NORECOVERY, REPLACE, STATS = 10;';
EXEC (@sql);

RESTORE DATABASE BusRD_Recuperada FROM DISK = N'C:\Backups\BusRD\BusRD_diff.bak'
    WITH NORECOVERY, STATS = 10;

RESTORE LOG BusRD_Recuperada FROM DISK = N'C:\Backups\BusRD\BusRD_log1.trn'
    WITH NORECOVERY, STATS = 10;

RESTORE LOG BusRD_Recuperada FROM DISK = N'C:\Backups\BusRD\BusRD_log_cola.trn'
    WITH STOPAT = @StopAt, RECOVERY, STATS = 10;
GO

/* ---------------------------------------------------------------------
   10. VERIFICACION
   --------------------------------------------------------------------- */
SELECT name, state_desc FROM sys.databases WHERE name IN ('BusRD','BusRD_Recuperada');

-- 10.1 Los 8 boletos vendidos existen en la base recuperada (esperado: 8)
SELECT COUNT(*) AS BoletosDemoEncontrados
FROM BusRD_Recuperada.dbo.Demo_Respaldo d
JOIN BusRD_Recuperada.dbo.Boletos b ON b.BoletoID = d.BoletoID;

-- 10.2 Los boletos borrados se recuperaron: mismo conteo que antes del DELETE
SELECT m.BoletosViajeAntes AS ConteoAntesDelDelete,
       (SELECT COUNT(*) FROM BusRD_Recuperada.dbo.Boletos WHERE ViajeID = 16000) AS EnRecuperada,   -- <<< viaje asignado
       (SELECT COUNT(*) FROM BusRD.dbo.Boletos            WHERE ViajeID = 16000) AS EnOriginalHoy   -- 0
FROM ##Marca m;
GO

/* ---------------------------------------------------------------------
   11. POLITICA DE RESPALDOS PROPUESTA (copiar al informe)
   | Tipo        | Frecuencia                    | Retencion          | Justificacion |
   | FULL        | Semanal (domingo 02:00)       | 4 semanas (+1 mensual 12 meses) | Base de la cadena de restauracion; baja actividad de ventas |
   | DIFERENCIAL | Diario (lun-sab 02:00)        | 2 semanas          | Acorta la restauracion: solo FULL + 1 diferencial + logs |
   | LOG         | Cada 15 min (cada 5 en feriados/temporada alta) | 14 dias | RPO <= 15 min; permite STOPAT antes de un error humano |
   Complementos: copiar los .bak/.trn fuera del servidor (otro equipo o nube);
   BACKUP ... WITH CHECKSUM + RESTORE VERIFYONLY; prueba de restauracion mensual;
   cifrado de los respaldos; alerta si falla un job. Metas: RPO 15 min, RTO ~1 h.
   --------------------------------------------------------------------- */
